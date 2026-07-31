// WriteTransforms.swift - what a client's rows are before they become the file's
//
// The same idea as the reading pipeline and the same fixed order, run the other way.  A client that
// holds its pixels as BGRA, or as one sample per byte at two bits of precision, says so once and hands
// over its rows as they are; this puts them into the shape the format stores.
//
// Three of these are their own inverses and are the reading kernels unchanged — reversing the colour
// channels, reversing the bytes of a sample, inverting an alpha or a grey.  The other three are not,
// and each is the reverse of a reading step: coverage moves from the front of a pixel to the back
// rather than the other way, samples are packed into a byte rather than spread out of one, and the
// shift moves up rather than down.
//
// The order below is the reference's, and where it is surprising it was measured rather than reasoned
// out.  Reversing the samples within a byte before packing them means it does nothing at all when
// packing is also asked for, because at that point the row is still a byte to a sample — which looks
// like a bug and is what the reference does.

/// The transforms applied to a row on its way into the file, in the order they run.
struct WriteTransformProgram {
    enum Step {
        case stripFiller(afterColor: Bool)
        case packSwap
        case pack(depth: Int)
        case shift
        case swapBytes
        case swapAlpha
        case invertAlpha
        case bgr
        case invertMono
    }

    private(set) var steps: [Step] = []

    var isEmpty: Bool { self.steps.isEmpty }

    /// The shape the client is handing over, which is not the shape the file stores.
    ///
    /// A client that packs its samples supplies one to a byte, and one that supplies a filler channel
    /// supplies a channel the file has no room for — so the row that arrives is wider than the row
    /// that leaves, and the buffer has to be sized for the wider one.
    private(set) var suppliedShape: RowInfo

    init(flags: TransformFlags, header: Header, fillerAfterColor: Bool) {
        var supplied = RowInfo(header)

        // The client's own transform runs before all of these, and is applied by the caller.
        if flags.contains(.filler), !header.colorType.hasAlpha, header.bitDepth >= 8 {
            self.steps.append(.stripFiller(afterColor: fillerAfterColor))
            supplied.channels += 1
            supplied.resize()
        }

        if flags.contains(.packSwap), header.bitDepth < 8 {
            self.steps.append(.packSwap)
        }

        if flags.contains(.packing), header.bitDepth < 8 {
            self.steps.append(.pack(depth: header.bitDepth))
            supplied.bitDepth = 8
            supplied.resize()
        }

        if flags.contains(.shift) {
            self.steps.append(.shift)
        }

        if flags.contains(.swapBytes), header.bitDepth == 16 {
            self.steps.append(.swapBytes)
        }

        if flags.contains(.swapAlpha), header.colorType.hasAlpha {
            self.steps.append(.swapAlpha)
        }

        if flags.contains(.invertAlpha), header.colorType.hasAlpha {
            self.steps.append(.invertAlpha)
        }

        if flags.contains(.bgr), header.colorType.hasColor {
            self.steps.append(.bgr)
        }

        if flags.contains(.invertMono) {
            self.steps.append(.invertMono)
        }

        self.suppliedShape = supplied
    }

    /// Applies the pipeline in place, returning the shape the row ends up in.
    func apply(
        to row: UnsafeMutableBufferPointer<UInt8>,
        significant: SignificantBits?
    ) -> RowInfo {
        var info = self.suppliedShape

        for step in self.steps {
            switch step {
            case let .stripFiller(afterColor):
                Transform.stripFiller(row, &info, afterColor: afterColor)

            case .packSwap:
                Transform.packSwap(row, info)

            case let .pack(depth):
                Transform.pack(row, &info, to: depth)

            case .shift:
                if let significant {
                    Transform.writeShift(row, info, significant: significant)
                }

            case .swapBytes:
                Transform.swapBytes(row, info)

            case .swapAlpha:
                Transform.writeSwapAlpha(row, info)

            case .invertAlpha:
                Transform.invertAlpha(row, info)

            case .bgr:
                Transform.bgr(row, info)

            case .invertMono:
                Transform.invertMono(row, info)
            }
        }

        return info
    }
}

extension Transform {
    /// Drops the channel the client supplied that the file has no room for.
    static func stripFiller(
        _ row: UnsafeMutableBufferPointer<UInt8>,
        _ info: inout RowInfo,
        afterColor: Bool
    ) {
        guard info.bitDepth >= 8, info.channels > 1 else { return }

        let width = info.bitDepth / 8
        let source = info.channels
        let target = info.channels - 1
        let skip = afterColor ? target : 0

        for pixel in 0 ..< info.width {
            var written = 0

            for channel in 0 ..< source where channel != skip {
                for byte in 0 ..< width {
                    row[(pixel * target + written) * width + byte] =
                        row[(pixel * source + channel) * width + byte]
                }

                written += 1
            }
        }

        info.channels = target
        info.resize()
    }

    /// Packs samples the client supplied one to a byte into the byte the format stores them in.
    static func pack(
        _ row: UnsafeMutableBufferPointer<UInt8>,
        _ info: inout RowInfo,
        to depth: Int
    ) {
        guard info.bitDepth == 8, depth < 8 else { return }

        let perByte = 8 / depth
        let mask = UInt8((1 << depth) - 1)
        let count = info.width * info.channels

        // One bit is the odd one out: at that depth the reference asks whether the sample is anything
        // at all rather than taking its low bit, so a client handing over 2 gets a set bit where the
        // masking rule would give a clear one.  Every other depth masks.
        let isBoolean = depth == 1
        let bytes = (count * depth + 7) / 8

        // Forwards, because each output byte is built from samples that lie further along the row
        // than it does: nothing is read after it has been overwritten.
        for byte in 0 ..< bytes {
            var packed: UInt8 = 0

            for slot in 0 ..< perByte {
                let index = byte * perByte + slot

                guard index < count else { break }

                let value = isBoolean
                    ? (row[index] != 0 ? 1 : 0)
                    : row[index] & mask

                packed |= value << ((perByte - 1 - slot) * depth)
            }

            row[byte] = packed
        }

        info.bitDepth = depth
        info.resize()
    }

    /// Moves the alpha channel from before the colour to after it.
    ///
    /// The reverse of what the reading kernel does, and the two are not the same operation for more
    /// than two channels: moving the first channel to the end is not the same as moving the last to
    /// the front.
    static func writeSwapAlpha(_ row: UnsafeMutableBufferPointer<UInt8>, _ info: RowInfo) {
        guard info.colorType.hasAlpha, info.bitDepth >= 8 else { return }

        let width = info.bitDepth / 8
        let colorChannels = info.channels - 1
        let stride = info.channels * width

        for pixel in 0 ..< info.width {
            let base = pixel * stride

            for byte in 0 ..< width {
                let alpha = row[base + byte]

                for channel in 0 ..< colorChannels {
                    row[base + channel * width + byte] = row[base + (channel + 1) * width + byte]
                }

                row[base + colorChannels * width + byte] = alpha
            }
        }
    }

    /// Moves each sample up into the range the file stores, filling what it leaves behind.
    ///
    /// The reverse of the reading shift, and not simply a shift the other way: moving a five bit value
    /// into eight bits leaves three bits with nothing in them, and leaving them zero would make the
    /// brightest value fall short of the brightest the file can hold.  So the value is repeated down
    /// into them, which is what the reference does and what makes the round trip come back where it
    /// started.
    static func writeShift(
        _ row: UnsafeMutableBufferPointer<UInt8>,
        _ info: RowInfo,
        significant: SignificantBits
    ) {
        guard !info.colorType.isIndexed else { return }

        let depth = info.bitDepth
        var bits = [Int](repeating: depth, count: 4)

        if info.colorType.hasColor {
            bits[0] = Int(significant.red)
            bits[1] = Int(significant.green)
            bits[2] = Int(significant.blue)
            if info.colorType.hasAlpha { bits[3] = Int(significant.alpha) }
        } else {
            bits[0] = Int(significant.gray)
            if info.colorType.hasAlpha { bits[1] = Int(significant.alpha) }
        }

        for index in 0 ..< 4 where bits[index] < 1 || bits[index] > depth {
            bits[index] = depth
        }

        guard bits.prefix(info.channels).contains(where: { $0 < depth }) else { return }

        let samples = info.width * info.channels

        for index in 0 ..< samples {
            let significantBits = bits[index % info.channels]

            guard significantBits < depth else { continue }

            let value = depth == 16
                ? Int(row[index * 2]) << 8 | Int(row[index * 2 + 1])
                : Int(row[index])

            var result = 0
            var shift = depth - significantBits

            // Repeated down rather than shifted once: each copy fills the bits the one above it left.
            while shift > -significantBits {
                result |= shift > 0 ? value << shift : value >> (-shift)
                shift -= significantBits
            }

            if depth == 16 {
                row[index * 2] = UInt8(truncatingIfNeeded: result >> 8)
                row[index * 2 + 1] = UInt8(truncatingIfNeeded: result)
            } else {
                row[index] = UInt8(truncatingIfNeeded: result)
            }
        }
    }
}
