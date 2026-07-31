// ProgressiveReader.swift - decoding what has arrived so far
//
// The other way round from the sequential reader, and the difference is who is in charge.  A
// sequential read asks for bytes when it wants them and blocks until it has them; a progressive read
// is handed whatever has arrived and decodes as much as that allows, which is what a client reading
// from a network has to do — it cannot promise to produce a scanline's worth of bytes on demand.
//
// So this cannot be a function that decodes an image.  It is a state machine that can stop between any
// two bytes and pick up where it left off, and the states are the file's own structure: the signature,
// a chunk's header, a chunk's contents, and the end.
//
// The image data is the one thing not gathered whole before it is used.  Every other chunk is small
// and is accumulated so the ordinary parsers can be handed a complete payload; the image data can be
// the whole file, so it is fed to the decompressor as it arrives and rows are handed to the client as
// they finish.

/// One image being decoded from whatever has arrived.
final class ProgressiveReader {
    /// Where the machine is in the file.
    enum State {
        /// Reading the eight bytes that begin a file.
        case signature
        /// Reading a chunk's length and type.
        case chunkHeader
        /// Reading a chunk's contents, which are being gathered whole.
        case chunkData(ChunkName, length: Int)
        /// Reading the image data, which is fed onward as it arrives.
        case imageData(remaining: Int)
        /// Reading the four bytes that follow a chunk's contents.
        case checksum(ChunkName)
        /// Past the end of the image, where anything left is skipped.
        case finished
    }

    private(set) var state: State = .signature

    /// Bytes of the current unit that have arrived, when it is one being gathered whole.
    private(set) var gathered = 0

    /// Whether the image data has already been said to have stopped without finishing.
    private var saidTruncatedImageData = false

    /// Whether the file has already been said to hold more image data than the image needs.
    ///
    /// Only the first such remark is worded that way; the rest are worded differently, so this says
    /// which of the two to use rather than whether to speak at all.
    private var saidExtraImageData = false

    /// Whether the client asked to be left alone until it asks again.
    ///
    /// A client that pauses inside a callback means the call that delivered it to stop and return, so
    /// that the client can do something else before handing over the rest of what it has.
    var isPaused = false

    /// How many bytes the client asked to have skipped without being looked at.
    ///
    /// For a chunk a client has no interest in: rather than pushing its bytes through, the client can
    /// say it has thrown them away, and the machine counts them off.
    private(set) var skipping = 0

    /// The rows this image has produced, which the row callback is told.
    private(set) var rowIndex = 0
    private(set) var pass = 0

    /// Whether the header has been announced to the client.
    private var announcedInfo = false

    /// The running checksum of the chunk being read.
    private var crc = Crc32()

    /// The name and length of the chunk whose checksum is being read.
    private var checksumExpected: UInt32 = 0

    /// Whether the last step moved the machine on, even if it read nothing.
    private var progressed = false

    /// Where the machine is, and moving it.
    private func enter(_ state: State) {
        self.state = state
        self.progressed = true
    }

    // -- pushing bytes in ----------------------------------------------------

    /// Consumes as much of `bytes` as the machine can, and reports how much that was.
    ///
    /// A short answer means the client paused; the rest is the client's to hand over again.
    func process(
        _ bytes: UnsafeBufferPointer<UInt8>,
        context: PngContext,
        info: InfoStore?
    ) throws -> Int {
        var offset = 0

        self.isPaused = false

        while offset < bytes.count, !self.isPaused {
            if self.skipping > 0 {
                let taken = min(self.skipping, bytes.count - offset)

                self.skipping -= taken
                offset += taken
                continue
            }

            self.progressed = false

            let consumed = try self.step(
                UnsafeBufferPointer(
                    rebasing: bytes[offset...]
                ),
                context: context,
                info: info
            )

            offset += consumed

            // Taking nothing is not the same as being stuck.  A chunk with no contents completes
            // without a byte being read, and the end marker is exactly that — a machine that treated
            // an empty step as the end of what it could do would stop just before finishing.
            guard consumed > 0 || self.progressed else { break }
        }

        return offset
    }

    /// Takes one step, consuming as much as this state can use.
    private func step(
        _ bytes: UnsafeBufferPointer<UInt8>,
        context: PngContext,
        info: InfoStore?
    ) throws -> Int {
        switch self.state {
        case .signature:
            return try self.readSignature(bytes, context: context)

        case .chunkHeader:
            return try self.readChunkHeader(bytes, context: context, info: info)

        case let .chunkData(name, length):
            return try self.readChunkData(bytes, name: name, length: length,
                                          context: context, info: info)

        case let .imageData(remaining):
            return try self.readImageData(bytes, remaining: remaining,
                                          context: context, info: info)

        case let .checksum(name):
            return try self.readChecksum(bytes, name: name, context: context, info: info)

        case .finished:
            return bytes.count
        }
    }

    // -- the states ----------------------------------------------------------

    private func readSignature(
        _ bytes: UnsafeBufferPointer<UInt8>,
        context: PngContext
    ) throws -> Int {
        // What the client said it had already read and checked itself.
        let consumed = context.signatureBytesConsumed
        let expected = 8 - consumed
        let taken = min(expected - self.gathered, bytes.count)

        try context.reserve(\.scratch, 8)

        for index in 0 ..< taken {
            context.scratch.bytes[self.gathered + index] = bytes[index]
        }

        // Compared as it arrives rather than once it is all here, which is what the reference does and
        // what makes its two messages reachable.  A client pushing seven bytes and a client pushing
        // eight are told different things about the same file: the first is told the file looks like a
        // PNG that something translated, the second that it is not a PNG at all — because the second
        // had the whole of the first four bytes to judge by and the first did not.
        if Self.signatureMismatch(context, from: self.gathered, count: taken) {
            // Which of the two things to say turns on whether the bytes *before* the last four of this
            // push were also wrong.  A push too short to have four bytes to spare cannot answer that,
            // and the reference treats an unanswerable comparison as a mismatch — so a client pushing
            // a byte at a time is told the file is not a PNG, and one pushing seven is told it looks
            // like a PNG something translated.
            let leading = taken - 4
            let leadingIsWrong = leading < 1
                || Self.signatureMismatch(context, from: self.gathered, count: min(leading, 8))

            if self.gathered < 4, leadingIsWrong {
                throw Diagnostic("Not a PNG file")
            }

            throw Diagnostic("PNG file corrupted by ASCII conversion")
        }

        self.gathered += taken

        guard self.gathered == expected else { return taken }

        self.gathered = 0
        self.enter(.chunkHeader)

        return taken
    }

    /// Whether any of a run of signature bytes is wrong.
    private static func signatureMismatch(
        _ context: PngContext,
        from start: Int,
        count: Int
    ) -> Bool {
        guard count > 0 else { return false }

        let signature = ChunkWriter.signature
        let whole = [signature.0, signature.1, signature.2, signature.3,
                     signature.4, signature.5, signature.6, signature.7]

        for index in start ..< start + count
        where context.scratch.bytes[index] != whole[index + context.signatureBytesConsumed] {
            return true
        }

        return false
    }

    private func readChunkHeader(
        _ bytes: UnsafeBufferPointer<UInt8>,
        context: PngContext,
        info: InfoStore?
    ) throws -> Int {
        let taken = min(8 - self.gathered, bytes.count)

        try context.reserve(\.scratch, 8)

        for index in 0 ..< taken {
            context.scratch.bytes[self.gathered + index] = bytes[index]
        }

        self.gathered += taken

        guard self.gathered == 8 else { return taken }

        self.gathered = 0

        let header = context.scratch.bytes
        let length = Int(header[0]) << 24 | Int(header[1]) << 16
            | Int(header[2]) << 8 | Int(header[3])
        let name = ChunkName(header[4], header[5], header[6], header[7])

        guard length <= 0x7FFF_FFFF else {
            throw Diagnostic("chunk data is too large")
        }

        self.crc.reset()
        self.crc.update(header[4])
        self.crc.update(header[5])
        self.crc.update(header[6])
        self.crc.update(header[7])

        if name == .idat {
            try self.beginImageData(context: context, info: info)
            self.enter(.imageData(remaining: length))
        } else {
            // The first chunk that is not image data is where the image data ended, and both of
            // these are questions about the whole of it.  They cannot be asked as each image data
            // chunk runs out: a file may divide its stream across as many as it likes, and every one
            // but the last leaves the stream rightly unfinished with its closing marks still to come.
            self.noteUnfinishedImageData(context: context)
            try self.noteImageDataEnded(context: context)

            try context.reserve(\.scratch, max(length, 8))
            self.enter(.chunkData(name, length: length))
        }

        return taken
    }

    private func readChunkData(
        _ bytes: UnsafeBufferPointer<UInt8>,
        name: ChunkName,
        length: Int,
        context: PngContext,
        info: InfoStore?
    ) throws -> Int {
        let taken = min(length - self.gathered, bytes.count)

        for index in 0 ..< taken {
            context.scratch.bytes[self.gathered + index] = bytes[index]
        }

        self.crc.update(UnsafeBufferPointer(start: bytes.baseAddress, count: taken))
        self.gathered += taken

        guard self.gathered == length else { return taken }

        self.gathered = 0
        self.lastPayloadLength = length
        self.enter(.checksum(name))

        return taken
    }

    private func readImageData(
        _ bytes: UnsafeBufferPointer<UInt8>,
        remaining: Int,
        context: PngContext,
        info: InfoStore?
    ) throws -> Int {
        let taken = min(remaining, bytes.count)

        self.crc.update(UnsafeBufferPointer(start: bytes.baseAddress, count: taken))

        try self.decompress(
            UnsafeBufferPointer(start: bytes.baseAddress, count: taken),
            context: context,
            info: info
        )

        let left = remaining - taken

        self.enter(left > 0 ? .imageData(remaining: left) : .checksum(.idat))

        return taken
    }

    private func readChecksum(
        _ bytes: UnsafeBufferPointer<UInt8>,
        name: ChunkName,
        context: PngContext,
        info: InfoStore?
    ) throws -> Int {
        let taken = min(4 - self.gathered, bytes.count)

        try context.reserve(\.scratch, max(4, context.scratch.count))

        // The checksum is staged separately from the payload, which is still in the scratch buffer:
        // the chunk cannot be parsed until its checksum has been seen.
        for index in 0 ..< taken {
            self.checksumExpected = self.checksumExpected << 8 | UInt32(bytes[index])
        }

        self.gathered += taken

        guard self.gathered == 4 else { return taken }

        self.gathered = 0

        let expected = self.checksumExpected
        self.checksumExpected = 0

        if expected != self.crc.checksum {
            // Fatal for a chunk the file cannot be read without, and a warning for one it can: an
            // ancillary chunk with a bad checksum is a chunk to drop, and a critical one is a file
            // to give up on.
            guard name.isAncillary else {
                throw Diagnostic("CRC error", chunk: name)
            }

            context.host.warn(Diagnostic("CRC error", severity: .warning, chunk: name))
        }

        try self.completeChunk(name, context: context, info: info)

        return taken
    }

    // -- what a completed chunk means ----------------------------------------

    private func completeChunk(
        _ name: ChunkName,
        context: PngContext,
        info: InfoStore?
    ) throws {
        switch name {
        case .ihdr:
            guard let info, let length = self.lastPayloadLength else { return }

            let fields = try Header.Fields(
                parsing: UnsafeBufferPointer(
                    start: context.scratch.bytes.baseAddress,
                    count: length
                )
            )

            let problems = fields.problems

            if !problems.isEmpty {
                // The one place the reference's two readers differ about a fault: reading a file in
                // one go it names a bad filter method twice, having checked the field twice on the
                // way through, and reading it in pieces it names it once.
                problems.report(to: context.host, repeatingFilterMethod: false)
                throw Diagnostic("Invalid IHDR data")
            }

            info.header = Header(fields)
            context.adoptProgressiveHeader(Header(fields), info: info)

            self.enter(.chunkHeader)

        case .idat:
            // More image data may follow; the machine finds out from the next header.
            self.enter(.chunkHeader)

        case .iend:
            // The end marker before any image data: the file is structurally complete and describes no
            // image, which is reported against the marker rather than as a missing chunk.
            guard self.announcedInfo else {
                throw Diagnostic("out of place", chunk: .iend)
            }

            try self.finishImageData(context: context, info: info)
            self.enter(.finished)

        default:
            if let info, let length = self.lastPayloadLength {
                try context.reader.parseOptional(
                    name,
                    payload: UnsafeBufferPointer(
                        start: context.scratch.bytes.baseAddress,
                        count: length
                    ),
                    info: info,
                    host: context.host
                )
            }

            self.enter(.chunkHeader)
        }
    }

    /// How long the payload just gathered was.
    ///
    /// Kept because the state has already moved on by the time the chunk is parsed: the checksum comes
    /// between the contents and the point where they can be trusted.
    private var lastPayloadLength: Int?

    /// Counts off the rest of the chunk being read, for a client that dropped it.
    ///
    /// Returns how many bytes that is, which is what the client is told it need not send.
    func skipRest() -> Int {
        switch self.state {
        case let .chunkData(_, length):
            let left = length - self.gathered

            self.skipping = left + 4
            self.gathered = 0
            self.enter(.chunkHeader)

            return left

        case let .imageData(remaining):
            self.skipping = remaining + 4
            self.enter(.chunkHeader)

            return remaining

        default:
            return 0
        }
    }

    // -- the image data ------------------------------------------------------

    /// Prepares for the first image data chunk, and tells the client what it is about to receive.
    ///
    /// The moment the header is complete as far as the client is concerned: every chunk before the
    /// image data has been seen, so this is when its callback can read them.
    private func beginImageData(context: PngContext, info: InfoStore?) throws {
        guard !self.announcedInfo else { return }

        self.announcedInfo = true

        guard let header = context.header else {
            throw Diagnostic("Missing IHDR before IDAT")
        }

        // The client may ask for transforms from inside this callback, so the pipeline is resolved
        // after it returns rather than before.
        context.host.progressiveInfo()

        if context.transforms == nil {
            try context.resolveTransforms()
        }

        let widest = header.isInterlaced
            ? Adam7.widestRowBytes(header: header)
            : header.rowBytes

        var largest = widest

        if let program = context.transforms {
            for pass in 0 ..< (header.isInterlaced ? Adam7.passCount : 1) {
                let start = header.isInterlaced
                    ? RowInfo(header, pass: pass)
                    : RowInfo(header)

                largest = max(
                    largest,
                    program.maximumRowBytes(from: start, hasTransparency: context.hasTransparency)
                )
            }
        }

        try context.reserve(\.rowBuffer, largest + 1)
        try context.reserve(\.previousRow, widest)
        context.previousRow.bytes.baseAddress!.update(repeating: 0, count: widest)

        context.inflater = try InflateStream()

        self.pass = header.isInterlaced ? 0 : 0
        self.rowIndex = 0

        self.skipEmptyPasses(header: header)
    }

    /// Feeds compressed bytes onward, handing the client every row they complete.
    private func decompress(
        _ bytes: UnsafeBufferPointer<UInt8>,
        context: PngContext,
        info: InfoStore?
    ) throws {
        guard let header = context.header, let inflater = context.inflater else { return }

        // Nothing more can be decompressed, but the chunk is still delivering — and what it delivers
        // is still remarked on, because from the client's side data is arriving at an image that
        // stopped.
        if self.imageDataFailed {
            self.noteExtraImageData(bytes, context: context, inflater: inflater)
            return
        }

        // The buffer is not copied, so it has to stay valid while the decompressor is working through
        // it — which it does, because this returns before the caller's buffer goes anywhere.
        inflater.setInput(UnsafeMutableBufferPointer(mutating: bytes))

        while !inflater.needsInput, !inflater.isFinished, !self.isPaused {
            guard self.pass < Adam7.passCount else { break }

            let stored = self.storedRowBytes(header: header)

            guard stored > 0 else { break }

            let wanted = stored + 1 - self.gatheredRow
            let made: Int

            do {
                made = try inflater.inflate(
                    into: context.rowBuffer.bytes.baseAddress! + self.gatheredRow,
                    count: wanted
                )
            } catch is Diagnostic {
                // A stream that cannot be decompressed stops the image without stopping the file: the
                // client is told, no more rows are produced, and the walk carries on to the end.  That
                // is what the reference does here and it is not what it does reading in one go, where
                // the same fault is fatal — a client pushing bytes has nowhere to put an exception.
                //
                // What the decompressor said is not passed on.  The reference says the same sentence
                // about every way a stream can fail — a block type that does not exist, a byte
                // changed in the middle, a header that was never a compressed stream at all — and it
                // names a check that none of those reached.  Reproduced rather than corrected,
                // including the chunk name appearing twice, because this is the text a client
                // matches on.
                //
                // The state is settled before the report, which runs the client's handler and is
                // entitled not to come back.  Nothing more will be produced, and whatever else the
                // chunk still has to deliver is data arriving at an image that is over.
                self.imageDataFailed = true
                self.pass = Adam7.passCount
                self.saidExtraImageData = true

                context.host.warn(
                    Diagnostic(
                        "IDAT: ADLER32 checksum mismatch",
                        severity: .warning,
                        chunk: .idat
                    )
                )
                return
            }

            self.gatheredRow += made

            guard self.gatheredRow == stored + 1 else {
                if made == 0 { break }
                continue
            }

            self.gatheredRow = 0

            try self.deliverRow(stored: stored, header: header, context: context)
        }

        self.noteExtraImageData(bytes, context: context, inflater: inflater)
    }

    /// Stops the decode where the file ran out part way through the image.
    ///
    /// Rows still owed and a stream that never finished: that is a file which cannot be read rather
    /// than one that reads oddly, so it ends here.
    ///
    /// Not the same as a stream that finished early.  One that ends properly having produced too few
    /// rows is a complete stream describing less than the header promised — every row it did carry
    /// is delivered and the client is left to notice the shortfall, which is what both libraries do.
    private func noteImageDataEnded(context: PngContext) throws {
        guard self.announcedInfo, !self.imageDataFailed, self.pass < Adam7.passCount,
              let inflater = context.inflater, !inflater.isFinished else {
            return
        }

        throw Diagnostic("Not enough compressed data")
    }

    /// Says that the image data stopped without saying it was over.
    ///
    /// Which is not the same as saying it was short: every row may have arrived and this still
    /// stands, because what is missing is the mark at the end saying the stream finished and arrived
    /// intact.  A file whose rows are all present and whose closing mark is wrong is exactly that.
    ///
    /// Answered only once the rows are all in.  A stream still owing rows has not stopped short of
    /// its closing marks — it has stopped short of the image, which is a different complaint and is
    /// made elsewhere.
    private func noteUnfinishedImageData(context: PngContext) {
        guard !self.saidTruncatedImageData, !self.imageDataFailed,
              self.pass >= Adam7.passCount,
              let inflater = context.inflater, !inflater.isFinished else {
            return
        }

        self.saidTruncatedImageData = true
        context.host.warn("Truncated compressed data in IDAT")
    }

    /// Says that image data has arrived which the image has no use for.
    ///
    /// Twice over, in two different forms, which is the reference's and worth reproducing exactly
    /// because a client sees both: the first says that the file holds more than the image needs, and
    /// every push after it that still carries any says so again in its own words.  Which means what a
    /// client is told depends on how the bytes happened to be divided — a whole file handed over at
    /// once produces one remark, and the same file pushed a byte at a time produces several.
    private func noteExtraImageData(
        _ bytes: UnsafeBufferPointer<UInt8>,
        context: PngContext,
        inflater: InflateStream
    ) {
        guard self.pass >= Adam7.passCount else { return }

        // Every well-formed stream has a tail the last row did not need — the marks that say the
        // stream ended and arrived intact.  Those are consumed here rather than counted as spare,
        // which is the whole difficulty: what is left after them is the file having more to say than
        // the image had room for.
        //
        // Drained on every push and not merely the first, because a stream is only ever finished by
        // being read to its end: leaving the tail sitting there would make a file with a few spare
        // scanlines look like one that stopped in the middle.
        var produced = false

        while !inflater.needsInput, !inflater.isFinished {
            let made = (try? inflater.inflate(
                into: context.rowBuffer.bytes.baseAddress!,
                count: context.rowBuffer.count
            )) ?? 0

            if made == 0 { break }
            produced = true
        }

        // Already said once, so anything further that arrives is remarked on as it arrives, without
        // asking what it decompresses to: it is image data reaching an image that is over.
        if self.saidExtraImageData {
            guard !bytes.isEmpty else { return }
            context.host.warn("Extra compression data in IDAT")
            return
        }

        guard produced || !inflater.needsInput else { return }

        // Set before the report, which runs the client's handler and may not come back.
        self.saidExtraImageData = true
        context.host.warn("Extra compressed data in IDAT")
    }

    /// How many bytes the row being gathered occupies in the stream.
    private func storedRowBytes(header: Header) -> Int {
        header.isInterlaced
            ? Adam7.rowBytes(ofPass: self.pass, header: header)
            : header.rowBytes
    }

    /// Reconstructs one row, transforms it, and hands it to the client.
    private func deliverRow(stored: Int, header: Header, context: PngContext) throws {
        let raw = context.rowBuffer.bytes

        guard let filter = Filter(rawValue: raw[0]) else {
            throw Diagnostic("bad adaptive filter value")
        }

        let row = UnsafeMutableBufferPointer(start: raw.baseAddress! + 1, count: stored)

        Defilter.apply(
            filter,
            to: row,
            previous: UnsafeBufferPointer(
                start: context.previousRow.bytes.baseAddress,
                count: stored
            ),
            stride: header.filterStride
        )

        context.previousRow.bytes.baseAddress!.update(from: row.baseAddress!, count: stored)

        var shape = header.isInterlaced
            ? RowInfo(header, pass: self.pass)
            : RowInfo(header)

        if let program = context.transforms, !program.isEmpty {
            let whole = UnsafeMutableBufferPointer(
                start: context.rowBuffer.bytes.baseAddress! + 1,
                count: context.rowBuffer.count - 1
            )

            _ = program.apply(to: whole, info: &shape, inputs: context.transformInputs)
        }

        self.maskTrailingBits(of: shape, in: row)

        // An image that is not interlaced is one row per row, and the number is the row's own.
        guard header.isInterlaced, context.spreadsInterlacedRows else {
            let delivered = self.rowIndex
            let deliveredPass = self.pass

            self.advanceRow(header: header, context: context)

            context.host.progressiveRow(
                row.baseAddress,
                row: UInt32(delivered),
                pass: Int32(deliveredPass)
            )

            return
        }

        // Interlaced, with the library placing the rows.  A pass row is not one image row: it is the
        // top of a block of them, and the client is handed it once for every image row that block
        // covers.  That is the reference's arrangement and it is what makes a partly-decoded image
        // look like a coarse version of the whole rather than like a few scattered lines.
        //
        // Rows the block does not reach are reported too, with nothing attached, so that a client
        // sweeping its own rows in step never has to work out which ones it will hear about.
        let base = Adam7.imageRow(ofPass: self.pass, passRow: self.rowIndex)
        let covers = min(base + Adam7.blockHeight[self.pass], header.height)

        while self.reportedRow < base {
            self.report(nil, context: context)
        }

        while self.reportedRow < covers {
            self.report(row.baseAddress, context: context)
        }

        self.advanceRow(header: header, context: context)
    }

    /// Hands the client one row of the sweep and steps the counter.
    ///
    /// The counter moves first because the client may pause from inside this: a paused push is resumed
    /// by handing the same bytes over again, and a row reported twice would be worse than one reported
    /// late.
    private func report(_ row: UnsafeMutablePointer<UInt8>?, context: PngContext) {
        let number = self.reportedRow
        let pass = self.pass

        self.reportedRow += 1
        self.deliveredPass = pass

        context.host.progressiveRow(row, row: UInt32(number), pass: Int32(pass))
    }

    private func advanceRow(header: Header, context: PngContext) {
        self.rowIndex += 1

        guard header.isInterlaced else {
            if self.rowIndex >= header.height { self.pass = Adam7.passCount }
            return
        }

        guard self.rowIndex >= Adam7.height(ofPass: self.pass, imageHeight: header.height) else {
            return
        }

        self.finishPass(header: header, context: context)
    }

    /// Ends the current pass and starts the next one that has anything in it.
    ///
    /// A pass owes the client a report for every row of the image, so the rows this one never reached
    /// are reported before it is left — and a pass that has rows in it nowhere near the image's own
    /// height owes the whole sweep, which is why this repeats.
    private func finishPass(header: Header, context: PngContext) {
        guard header.isInterlaced, context.spreadsInterlacedRows else {
            self.rowIndex = 0
            self.pass += 1
            return
        }

        repeat {
            while self.reportedRow < header.height {
                self.report(nil, context: context)
            }

            self.reportedRow = 0
            self.rowIndex = 0
            self.pass += 1
            self.skipEmptyPasses(header: header)

            // Each pass differences against itself alone, so the row above its first is blank.
            if self.pass < Adam7.passCount {
                context.previousRow.bytes.baseAddress?
                    .update(repeating: 0, count: context.previousRow.count)
            }
        } while self.pass < Adam7.passCount
            && Adam7.height(ofPass: self.pass, imageHeight: header.height) == 0
    }

    /// Passes with no pixels in them are stepped over rather than waited for.
    ///
    /// A pass with columns but no rows is not empty in this sense: the client is told about it, one
    /// row at a time with nothing attached, and only a pass that is too narrow to hold anything is
    /// passed over in silence.
    private func skipEmptyPasses(header: Header) {
        guard header.isInterlaced else { return }

        while self.pass < Adam7.passCount,
              Adam7.width(ofPass: self.pass, imageWidth: header.width) == 0 {
            self.pass += 1
        }
    }

    /// Tells the client the image is complete.
    private func finishImageData(context: PngContext, info: InfoStore?) throws {
        context.inflater?.release()
        context.inflater = nil

        context.host.progressiveEnd()
    }

    /// How much of the current row has arrived.
    private var gatheredRow = 0

    /// How many bytes of the previous row need clearing before the next pass.
    private var previousRowNeedsClearing = 0

    /// Which image row of the current pass's sweep comes next.
    private var reportedRow = 0

    /// The pass the last reported row belonged to, which is what a client combining it needs.
    private(set) var deliveredPass = 0

    /// Whether the current pass has run out of rows and owes the client the rest of its sweep.
    private var passIsEnding = false

    /// Whether the image data could not be decompressed, so no more rows will come.
    private var imageDataFailed = false

    /// Clears the bits past the end of a row, as the sequential reader does.
    private func maskTrailingBits(
        of shape: RowInfo,
        in row: UnsafeMutableBufferPointer<UInt8>
    ) {
        guard shape.rowBytes > 0, shape.rowBytes <= row.count else { return }

        let used = (shape.width * shape.pixelDepth) % 8

        guard used != 0 else { return }

        row[shape.rowBytes - 1] &= UInt8(truncatingIfNeeded: 0xFF << (8 - used))
    }
}
