// Inflate.swift - decompressing a zlib stream without a C library underneath
//
// Shaped the same as the caller on the other side of this module: compressed bytes go in
// whenever there are some, decompressed bytes come out into whatever buffer and however many
// at a time the caller asks for, and nothing here assumes those line up with each other or with
// a DEFLATE block boundary. That means every point in the format where more input might not be
// there yet — mid Huffman symbol, mid extra-bits field, mid a match copy that filled the
// caller's buffer before it filled the match — has to be resumable, and the state below is
// exactly the set of fields that survive across such a pause.
//
// The algorithm is RFC 1951 (DEFLATE) wrapped in RFC 1950 (zlib): a two-byte header, a sequence
// of blocks each either stored literally, Huffman-coded against the format's fixed table, or
// Huffman-coded against a table the block carries with it, and a four-byte Adler-32 trailer.
public final class Inflate {
    private enum State {
        case zlibHeader
        case blockHeader
        case storedLength
        case storedCopy
        case dynamicCounts
        case dynamicCodeLengthLengths
        case dynamicLengths
        case dynamicLengthExtra
        case blockData
        case matchExtraLength
        case matchDistanceSymbol
        case matchExtraDistance
        case matchCopy
        case trailer
        case done
    }

    private var state: State = .zlibHeader
    private var reader = BitReader()

    /// The last 32 KiB produced, which is as far back a match is ever asked to reach. Circular:
    /// `windowPosition` is where the next byte goes, wrapping at the end.
    private var window = [UInt8](repeating: 0, count: DeflateTables.windowSize)
    private var windowPosition = 0
    private var totalProduced = 0

    private var checksum = Adler32()

    /// Whether the current block is the stream's last, read from its header and acted on once
    /// its end-of-block symbol is reached.
    private var isFinalBlock = false

    // -- dynamic block header ------------------------------------------------

    private var literalCount = 0
    private var distanceCount = 0
    private var codeLengthCodeCount = 0
    private var codeLengthLengths = [UInt8](repeating: 0, count: 19)
    private var codeLengthTable: HuffmanTable?

    /// The combined literal/length and distance code lengths a dynamic block declares, decoded
    /// in one pass because the format's repeat codes can copy across the boundary between them.
    private var combinedLengths: [UInt8] = []
    private var combinedLengthsIndex = 0
    private var previousCodeLength: UInt8 = 0

    private var literalTable: HuffmanTable?
    private var distanceTable: HuffmanTable?
    private var symbolPartial = HuffmanTable.Partial()

    // -- stored block ---------------------------------------------------------

    private var storedRemaining = 0

    // -- one literal/length/distance symbol being resolved ---------------------

    private var pendingSymbol: UInt16 = 0
    private var matchLength = 0
    private var matchDistance = 0

    /// Whether the stream has delivered its end marker.
    public private(set) var isFinished = false

    public init() {}

    public var needsInput: Bool {
        self.reader.needsInput
    }

    public func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.reader.setInput(bytes)
    }

    // -- emitting produced bytes ------------------------------------------------

    /// Where the caller's buffer has been filled to; reset at the start of every call and
    /// advanced by `emit` as bytes are produced.
    private var destination: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>(
        bitPattern: 1
    )!
    private var destinationCapacity = 0
    private var destinationCount = 0

    private var destinationFull: Bool {
        self.destinationCount >= self.destinationCapacity
    }

    /// Writes one produced byte to both the caller's buffer and this stream's own window, which
    /// is the only history a later match can read back through — the caller's buffers are not
    /// assumed to stay valid or stay adjacent to each other.
    private func emit(_ byte: UInt8) {
        self.destination[self.destinationCount] = byte
        self.destinationCount += 1

        self.window[self.windowPosition] = byte
        self.windowPosition = (self.windowPosition + 1) % DeflateTables.windowSize
        self.totalProduced += 1

        self.checksum.update(byte)
    }

    /// Decompresses into `destination`, returning how many bytes were produced.
    ///
    /// A result smaller than `count` means the stream needs more input, has filled the window
    /// past what fit here, or has ended — the caller distinguishes those with ``needsInput`` and
    /// ``isFinished``, exactly as it would with the system decompressor this stands in for.
    public func inflate(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int
    ) throws(DeflateError) -> Int {
        guard count > 0 else { return 0 }

        self.destination = destination
        self.destinationCapacity = count
        self.destinationCount = 0

        while !self.destinationFull, self.state != .done {
            guard try self.step() else { break }
        }

        return self.destinationCount
    }

    /// Advances the state machine by as much as it can with what is currently buffered.
    ///
    /// Returns false when nothing more can happen right now — either the input has run out or
    /// the destination has — so the caller's loop above knows to stop rather than spin.
    private func step() throws(DeflateError) -> Bool {
        switch self.state {
        case .zlibHeader:
            // Read as one field: two separate reads would each be atomic on their own, but
            // input running out between them would leave the first byte consumed with nothing
            // to show for it, and no way to tell on retry that it already happened.
            guard let raw = self.reader.bits(16) else { return false }

            let cmf = raw & 0xFF
            let flg = (raw >> 8) & 0xFF

            guard (cmf * 256 + flg) % 31 == 0 else {
                throw DeflateError("bad zlib header")
            }

            guard cmf & 0x0F == 8 else {
                throw DeflateError("unsupported compression method")
            }

            guard (flg >> 5) & 1 == 0 else {
                throw DeflateError("zlib preset dictionaries are not supported")
            }

            self.state = .blockHeader
            return true

        case .blockHeader:
            // One field again, for the same reason as the zlib header: BFINAL consumed with
            // BTYPE then unavailable would have nowhere to be remembered.
            guard let raw = self.reader.bits(3) else { return false }

            let final = raw & 1
            let type = (raw >> 1) & 0b11

            self.isFinalBlock = final == 1

            switch type {
            case 0:
                self.reader.alignToByte()
                self.state = .storedLength

            case 1:
                self.literalTable = try HuffmanTable(lengths: DeflateTables.fixedLiteralLengths)
                self.distanceTable = try HuffmanTable(lengths: DeflateTables.fixedDistanceLengths)
                self.symbolPartial = HuffmanTable.Partial()
                self.state = .blockData

            case 2:
                self.state = .dynamicCounts

            default:
                throw DeflateError("reserved block type")
            }

            return true

        case .storedLength:
            guard let raw = self.reader.bits(32) else { return false }

            let length = Int(raw & 0xFFFF)
            let complement = Int((raw >> 16) & 0xFFFF)

            guard length == (complement ^ 0xFFFF) else {
                throw DeflateError("stored block length check failed")
            }

            self.storedRemaining = length
            self.state = .storedCopy
            return true

        case .storedCopy:
            while self.storedRemaining > 0, !self.destinationFull {
                guard let byte = self.reader.bits(8) else { return false }

                self.emit(UInt8(truncatingIfNeeded: byte))
                self.storedRemaining -= 1
            }

            if self.storedRemaining == 0 {
                self.state = self.isFinalBlock ? .trailer : .blockHeader
            }

            return true

        case .dynamicCounts:
            // One field, again for the same resumability reason.
            guard let raw = self.reader.bits(14) else { return false }

            let hlit = raw & 0x1F
            let hdist = (raw >> 5) & 0x1F
            let hclen = (raw >> 10) & 0xF

            self.literalCount = Int(hlit) + 257
            self.distanceCount = Int(hdist) + 1
            self.codeLengthCodeCount = Int(hclen) + 4
            self.codeLengthLengths = [UInt8](repeating: 0, count: 19)
            self.combinedLengthsIndex = 0
            self.state = .dynamicCodeLengthLengths
            return true

        case .dynamicCodeLengthLengths:
            while self.combinedLengthsIndex < self.codeLengthCodeCount {
                guard let bits = self.reader.bits(3) else { return false }

                let position = DeflateTables.codeLengthOrder[self.combinedLengthsIndex]
                self.codeLengthLengths[position] = UInt8(bits)
                self.combinedLengthsIndex += 1
            }

            self.codeLengthTable = try HuffmanTable(lengths: self.codeLengthLengths)
            self.combinedLengths = [UInt8](
                repeating: 0,
                count: self.literalCount + self.distanceCount
            )
            self.combinedLengthsIndex = 0
            self.previousCodeLength = 0
            self.symbolPartial = HuffmanTable.Partial()
            self.state = .dynamicLengths
            return true

        case .dynamicLengths:
            guard let table = self.codeLengthTable else {
                throw DeflateError("internal: no code-length table")
            }

            while self.combinedLengthsIndex < self.combinedLengths.count {
                switch try table.decode(&self.reader, partial: &self.symbolPartial) {
                case .needsInput:
                    return false

                case let .symbol(symbol):
                    switch symbol {
                    case 0 ... 15:
                        self.combinedLengths[self.combinedLengthsIndex] = UInt8(symbol)
                        self.previousCodeLength = UInt8(symbol)
                        self.combinedLengthsIndex += 1

                    case 16, 17, 18:
                        // The symbol is fully decoded and `symbolPartial` already reset; what
                        // is left is its extra-bits field, which is its own resumable step so
                        // that running out of input here does not re-decode the symbol.
                        self.pendingSymbol = symbol
                        self.state = .dynamicLengthExtra
                        return true

                    default:
                        throw DeflateError("invalid code-length symbol")
                    }
                }
            }

            self.literalTable = try HuffmanTable(
                lengths: Array(self.combinedLengths[0 ..< self.literalCount])
            )
            self.distanceTable = try HuffmanTable(
                lengths: Array(self.combinedLengths[self.literalCount...])
            )
            self.symbolPartial = HuffmanTable.Partial()
            self.state = .blockData
            return true

        case .dynamicLengthExtra:
            switch self.pendingSymbol {
            case 16:
                guard let extra = self.reader.bits(2) else { return false }
                try self.repeatPreviousLength(count: 3 + Int(extra))

            case 17:
                guard let extra = self.reader.bits(3) else { return false }
                try self.fillZeroLength(count: 3 + Int(extra))

            case 18:
                guard let extra = self.reader.bits(7) else { return false }
                try self.fillZeroLength(count: 11 + Int(extra))

            default:
                throw DeflateError("internal: unexpected pending code-length symbol")
            }

            self.state = .dynamicLengths
            return true

        case .blockData:
            guard let table = self.literalTable else {
                throw DeflateError("internal: no literal table")
            }

            while !self.destinationFull {
                switch try table.decode(&self.reader, partial: &self.symbolPartial) {
                case .needsInput:
                    return false

                case let .symbol(symbol):
                    if symbol < 256 {
                        self.emit(UInt8(symbol))
                        continue
                    }

                    if symbol == DeflateTables.endOfBlock {
                        self.state = self.isFinalBlock ? .trailer : .blockHeader
                        return true
                    }

                    guard symbol <= 285 else {
                        throw DeflateError("invalid length symbol")
                    }

                    self.pendingSymbol = symbol
                    self.state = .matchExtraLength
                    return true
                }
            }

            return true

        case .matchExtraLength:
            let index = Int(self.pendingSymbol) - 257
            let extraBits = DeflateTables.lengthExtraBits[index]

            guard let extra = self.reader.bits(extraBits) else { return false }

            self.matchLength = DeflateTables.lengthBase[index] + Int(extra)
            self.state = .matchDistanceSymbol
            return true

        case .matchDistanceSymbol:
            guard let table = self.distanceTable else {
                throw DeflateError("internal: no distance table")
            }

            switch try table.decode(&self.reader, partial: &self.symbolPartial) {
            case .needsInput:
                return false

            case let .symbol(symbol):
                guard symbol <= 29 else {
                    throw DeflateError("invalid distance symbol")
                }

                self.pendingSymbol = symbol
                self.state = .matchExtraDistance
                return true
            }

        case .matchExtraDistance:
            let index = Int(self.pendingSymbol)
            let extraBits = DeflateTables.distanceExtraBits[index]

            guard let extra = self.reader.bits(extraBits) else { return false }

            self.matchDistance = DeflateTables.distanceBase[index] + Int(extra)

            guard self.matchDistance >= 1,
                  self.matchDistance <= min(DeflateTables.windowSize, self.totalProduced)
            else {
                throw DeflateError("match distance reaches before the start of the stream")
            }

            self.symbolPartial = HuffmanTable.Partial()
            self.state = .matchCopy
            return true

        case .matchCopy:
            while self.matchLength > 0, !self.destinationFull {
                let sourceIndex =
                    (self.windowPosition + DeflateTables.windowSize - self.matchDistance)
                        % DeflateTables.windowSize

                self.emit(self.window[sourceIndex])
                self.matchLength -= 1
            }

            if self.matchLength == 0 {
                self.state = .blockData
            }

            return true

        case .trailer:
            // The last block ends wherever its final code did, but the checksum after it is
            // byte-aligned (RFC 1950 §2.2), so whatever is left of the current byte is padding.
            // Aligning is idempotent, which matters because this state is re-entered whenever
            // the four checksum bytes have not all arrived yet.
            self.reader.alignToByte()

            // One field once more. The four bytes come out of the reader in stream order at
            // ascending bit positions (`raw`'s low byte is the first byte read), but the
            // checksum they spell is big-endian, so reassembling it reverses that order.
            guard let raw = self.reader.bits(32) else { return false }

            let b0 = raw & 0xFF
            let b1 = (raw >> 8) & 0xFF
            let b2 = (raw >> 16) & 0xFF
            let b3 = (raw >> 24) & 0xFF
            let stored = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3

            guard stored == self.checksum.value else {
                throw DeflateError("Adler-32 checksum mismatch")
            }

            self.state = .done
            self.isFinished = true
            return true

        case .done:
            return false
        }
    }

    /// The two repeat codes in the code-length alphabet: 16 copies the previous length again,
    /// 17 and 18 insert runs of zero — three different symbols for what is, underneath, the same
    /// "extend the array by `count` entries" operation.
    private func repeatPreviousLength(count: Int) throws(DeflateError) {
        guard self.combinedLengthsIndex > 0 else {
            throw DeflateError("repeat code with nothing to repeat")
        }

        try self.fill(self.previousCodeLength, count: count)
    }

    private func fillZeroLength(count: Int) throws(DeflateError) {
        try self.fill(0, count: count)
        self.previousCodeLength = 0
    }

    private func fill(_ value: UInt8, count: Int) throws(DeflateError) {
        guard self.combinedLengthsIndex + count <= self.combinedLengths.count else {
            throw DeflateError("code-length repeat runs past the table")
        }

        for _ in 0 ..< count {
            self.combinedLengths[self.combinedLengthsIndex] = value
            self.combinedLengthsIndex += 1
        }
    }
}
