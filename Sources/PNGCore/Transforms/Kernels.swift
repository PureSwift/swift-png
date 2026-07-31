// Kernels.swift - the transforms themselves
//
// Each of these rewrites a row in place and updates its shape.  Working in place is what keeps
// the pipeline to one buffer, and it is why the ones that make a row larger walk it backwards:
// writing the last pixel first means the bytes still to be read are always ahead of the write.
//
// The buffer is sized for the largest shape the row will ever take, which the program computes
// before any row is read, so a growing transform never has to check whether it has room.

enum Transform {
    // -- widening and narrowing samples ---------------------------------------

    /// Takes the high byte of each sixteen bit sample.
    ///
    /// Fast and lossy in a particular way: 0xFFFF becomes 0xFF, but so does 0xFF00, so the top of
    /// the range is compressed. The scaling variant exists for callers that care.
    static func strip16(_ row: UnsafeMutableBufferPointer<UInt8>, _ info: inout RowInfo) {
        guard info.bitDepth == 16 else { return }

        let samples = info.width * info.channels

        for index in 0 ..< samples {
            row[index] = row[index * 2]
        }

        info.bitDepth = 8
        info.resize()
    }

    /// Scales each sixteen bit sample into eight bits.
    ///
    /// Divides by 257 rather than by 256, because 0xFFFF has to become 0xFF exactly: the two
    /// ranges are 0 to 65535 and 0 to 255, and 65535 is 257 times 255.
    static func scale16(_ row: UnsafeMutableBufferPointer<UInt8>, _ info: inout RowInfo) {
        guard info.bitDepth == 16 else { return }

        let samples = info.width * info.channels

        for index in 0 ..< samples {
            let value = Int(row[index * 2]) << 8 | Int(row[index * 2 + 1])

            // Rounded rather than truncated, which is the difference between this and taking the
            // high byte for values in the middle of the range.
            row[index] = UInt8((value + 128) / 257)
        }

        info.bitDepth = 8
        info.resize()
    }

    /// Widens eight bit samples to sixteen.
    ///
    /// Each byte is repeated rather than shifted, so that 0xFF becomes 0xFFFF and not 0xFF00: the
    /// full range has to map to the full range.
    static func expand16(_ row: UnsafeMutableBufferPointer<UInt8>, _ info: inout RowInfo) {
        guard info.bitDepth == 8 else { return }

        let samples = info.width * info.channels

        // Backwards, because the row grows and the source bytes must stay ahead of the writes.
        for index in stride(from: samples - 1, through: 0, by: -1) {
            let value = row[index]
            row[index * 2] = value
            row[index * 2 + 1] = value
        }

        info.bitDepth = 16
        info.resize()
    }

    /// Spreads samples narrower than a byte one to a byte.
    ///
    /// The values are not scaled, only unpacked: a two bit sample of 3 becomes a byte of 3, not
    /// 255. A client that wants the full range asks for the shift as well.
    static func packing(_ row: UnsafeMutableBufferPointer<UInt8>, _ info: inout RowInfo) {
        guard info.bitDepth < 8 else { return }

        let depth = info.bitDepth
        let perByte = 8 / depth
        let mask = UInt8((1 << depth) - 1)
        let samples = info.width * info.channels

        // Backwards, as the row grows by up to eight times.
        for index in stride(from: samples - 1, through: 0, by: -1) {
            let shift = (perByte - 1 - index % perByte) * depth
            row[index] = (row[index / perByte] >> shift) & mask
        }

        info.bitDepth = 8
        info.resize()
    }

    /// Recovers samples that were widened to the stored depth when the image was written.
    ///
    /// The direction is the opposite of what the name suggests, and it is worth being exact about.
    /// An image whose significant bits chunk says five bits of red was stored in eight had its five
    /// bit values scaled up to fill the byte; this moves them back down, so a client gets the five
    /// bit numbers the image was made from rather than the eight bit ones it was stored as.
    static func shift(
        _ row: UnsafeMutableBufferPointer<UInt8>,
        _ info: inout RowInfo,
        significant: SignificantBits
    ) {
        // Nothing to do to a row of palette indices: what the shift describes is the precision of the
        // palette's samples, and an index is not one of them.  Once the palette has been expanded the
        // row holds samples and this does apply, which is why the expansion runs first.
        guard !info.colorType.isIndexed else { return }

        // How far to move each channel down, in the order the channels appear.
        var shifts = [Int](repeating: 0, count: 4)
        let depth = info.bitDepth

        if info.colorType.hasColor {
            shifts[0] = depth - Int(significant.red)
            shifts[1] = depth - Int(significant.green)
            shifts[2] = depth - Int(significant.blue)
            if info.colorType.hasAlpha { shifts[3] = depth - Int(significant.alpha) }
        } else {
            shifts[0] = depth - Int(significant.gray)
            if info.colorType.hasAlpha { shifts[1] = depth - Int(significant.alpha) }
        }

        for index in 0 ..< 4 where shifts[index] < 0 {
            shifts[index] = 0
        }

        guard shifts.contains(where: { $0 > 0 }) else { return }

        switch depth {
        case 16:
            for index in 0 ..< info.width * info.channels {
                let shift = shifts[index % info.channels]
                let value = UInt16(row[index * 2]) << 8 | UInt16(row[index * 2 + 1])
                let shifted = value >> shift

                row[index * 2] = UInt8(truncatingIfNeeded: shifted >> 8)
                row[index * 2 + 1] = UInt8(truncatingIfNeeded: shifted)
            }

        case 8:
            for index in 0 ..< info.width * info.channels {
                row[index] = row[index] >> shifts[index % info.channels]
            }

        default:
            // Below a byte the samples share bytes, so each is extracted, shifted and put back.
            let perByte = 8 / depth
            let mask = UInt8((1 << depth) - 1)

            for index in 0 ..< info.width * info.channels {
                let byte = index / perByte
                let position = (perByte - 1 - index % perByte) * depth
                let value = (row[byte] >> position) & mask
                let shifted = (value >> shifts[index % info.channels]) & mask

                row[byte] &= ~(mask << position)
                row[byte] |= shifted << position
            }
        }
    }

    // -- rearranging channels -------------------------------------------------

    /// Replaces a single grey channel with three equal colour channels.
    static func grayToRgb(_ row: UnsafeMutableBufferPointer<UInt8>, _ info: inout RowInfo) {
        guard !info.colorType.hasColor, info.bitDepth >= 8 else { return }

        let hadAlpha = info.colorType.hasAlpha
        let pixels = info.width
        let base = row.baseAddress!

        // Backwards, three channels where there was one, with a loop per layout: picking the shape
        // once out here rather than per byte in there is most of the speed of this kernel, and a
        // pair of moving pointers is the rest of it.
        switch (info.bitDepth, hadAlpha) {
        case (8, false):
            var source = base + pixels
            var target = base + pixels * 3

            for _ in 0 ..< pixels {
                source -= 1
                target -= 3

                let gray = source[0]

                target[0] = gray
                target[1] = gray
                target[2] = gray
            }

        case (8, true):
            var source = base + pixels * 2
            var target = base + pixels * 4

            for _ in 0 ..< pixels {
                source -= 2
                target -= 4

                let gray = source[0]
                let alpha = source[1]

                target[0] = gray
                target[1] = gray
                target[2] = gray
                target[3] = alpha
            }

        case (_, false):
            var source = base + pixels * 2
            var target = base + pixels * 6

            for _ in 0 ..< pixels {
                source -= 2
                target -= 6

                let hi = source[0]
                let lo = source[1]

                target[0] = hi
                target[1] = lo
                target[2] = hi
                target[3] = lo
                target[4] = hi
                target[5] = lo
            }

        case (_, true):
            var source = base + pixels * 4
            var target = base + pixels * 8

            for _ in 0 ..< pixels {
                source -= 4
                target -= 8

                let hi = source[0]
                let lo = source[1]
                let alphaHi = source[2]
                let alphaLo = source[3]

                target[0] = hi
                target[1] = lo
                target[2] = hi
                target[3] = lo
                target[4] = hi
                target[5] = lo
                target[6] = alphaHi
                target[7] = alphaLo
            }
        }

        info.colorType = hadAlpha ? .rgba : .rgb
        info.channels = hadAlpha ? 4 : 3
        info.resize()
    }

    /// Removes the alpha channel.
    static func stripAlpha(_ row: UnsafeMutableBufferPointer<UInt8>, _ info: inout RowInfo) {
        guard info.colorType.hasAlpha, info.bitDepth >= 8 else { return }

        let width = info.bitDepth / 8
        let colorChannels = info.channels - 1

        for pixel in 0 ..< info.width {
            let source = pixel * info.channels * width
            let target = pixel * colorChannels * width

            for byte in 0 ..< colorChannels * width {
                row[target + byte] = row[source + byte]
            }
        }

        info.colorType = info.colorType.hasColor ? .rgb : .grayscale
        info.channels = colorChannels
        info.resize()
    }

    /// Adds a channel of constant value, either before or after the colour.
    ///
    /// Whether the new channel counts as alpha is the caller's choice, and it is the whole
    /// difference between the two published entry points: the bytes are identical, but a row with
    /// a filler still reports no alpha.
    static func filler(
        _ row: UnsafeMutableBufferPointer<UInt8>,
        _ info: inout RowInfo,
        value: UInt32,
        afterColor: Bool,
        countsAsAlpha: Bool
    ) {
        // Not for a row of palette indices: an index is not a channel and has nothing to pad.  A
        // client that wants alpha on an indexed image expands the palette first.
        guard info.bitDepth >= 8, !info.colorType.hasAlpha, !info.colorType.isIndexed,
              info.channels < 4
        else { return }

        let width = info.bitDepth / 8
        let sourceChannels = info.channels
        let targetChannels = sourceChannels + 1
        let pixels = info.width
        let base = row.baseAddress!

        // The value is given at sixteen bits; at eight only the low byte is used.
        let high = UInt8(truncatingIfNeeded: value >> 8)
        let low = UInt8(truncatingIfNeeded: value)

        // Backwards, with a loop per layout and the filler's place chosen out here, for the same
        // reason as the kernel above: the shape has to be settled before the loop starts.
        switch (width, sourceChannels, afterColor) {
        case (1, 1, true):
            var source = base + pixels
            var target = base + pixels * 2

            for _ in 0 ..< pixels {
                source -= 1
                target -= 2

                let gray = source[0]

                target[0] = gray
                target[1] = low
            }

        case (1, 1, false):
            var source = base + pixels
            var target = base + pixels * 2

            for _ in 0 ..< pixels {
                source -= 1
                target -= 2

                let gray = source[0]

                target[0] = low
                target[1] = gray
            }

        case (1, 3, true):
            var source = base + pixels * 3
            var target = base + pixels * 4

            for _ in 0 ..< pixels {
                source -= 3
                target -= 4

                let red = source[0]
                let green = source[1]
                let blue = source[2]

                target[0] = red
                target[1] = green
                target[2] = blue
                target[3] = low
            }

        case (1, 3, false):
            var source = base + pixels * 3
            var target = base + pixels * 4

            for _ in 0 ..< pixels {
                source -= 3
                target -= 4

                let red = source[0]
                let green = source[1]
                let blue = source[2]

                target[0] = low
                target[1] = red
                target[2] = green
                target[3] = blue
            }

        case (2, 1, true):
            var source = base + pixels * 2
            var target = base + pixels * 4

            for _ in 0 ..< pixels {
                source -= 2
                target -= 4

                let hi = source[0]
                let lo = source[1]

                target[0] = hi
                target[1] = lo
                target[2] = high
                target[3] = low
            }

        case (2, 1, false):
            var source = base + pixels * 2
            var target = base + pixels * 4

            for _ in 0 ..< pixels {
                source -= 2
                target -= 4

                target[2] = source[0]
                target[3] = source[1]
                target[0] = high
                target[1] = low
            }

        case (2, 3, true):
            var source = base + pixels * 6
            var target = base + pixels * 8

            for _ in 0 ..< pixels {
                source -= 6
                target -= 8

                let byte0 = source[0]
                let byte1 = source[1]
                let byte2 = source[2]
                let byte3 = source[3]
                let byte4 = source[4]
                let byte5 = source[5]

                target[0] = byte0
                target[1] = byte1
                target[2] = byte2
                target[3] = byte3
                target[4] = byte4
                target[5] = byte5
                target[6] = high
                target[7] = low
            }

        case (2, 3, false):
            var source = base + pixels * 6
            var target = base + pixels * 8

            for _ in 0 ..< pixels {
                source -= 6
                target -= 8

                let byte0 = source[0]
                let byte1 = source[1]
                let byte2 = source[2]
                let byte3 = source[3]
                let byte4 = source[4]
                let byte5 = source[5]

                target[2] = byte0
                target[3] = byte1
                target[4] = byte2
                target[5] = byte3
                target[6] = byte4
                target[7] = byte5
                target[0] = high
                target[1] = low
            }

        default:
            // A shape outside the usual eight — a second filler on a row that already has one.
            for pixel in stride(from: pixels - 1, through: 0, by: -1) {
                let source = pixel * sourceChannels * width
                let target = pixel * targetChannels * width

                let colorOffset = afterColor ? 0 : width
                let fillerOffset = afterColor ? sourceChannels * width : 0

                for byte in stride(from: sourceChannels * width - 1, through: 0, by: -1) {
                    row[target + colorOffset + byte] = row[source + byte]
                }

                if width == 2 {
                    row[target + fillerOffset] = high
                    row[target + fillerOffset + 1] = low
                } else {
                    row[target + fillerOffset] = low
                }
            }
        }

        info.channels = targetChannels

        if countsAsAlpha {
            info.colorType = info.colorType.hasColor ? .rgba : .grayscaleAlpha
        }

        info.resize()
    }

    /// Exchanges the red and blue channels.
    static func bgr(_ row: UnsafeMutableBufferPointer<UInt8>, _ info: RowInfo) {
        guard info.colorType.hasColor, info.bitDepth >= 8, info.channels >= 3 else { return }

        let width = info.bitDepth / 8
        let stride = info.channels * width

        for pixel in 0 ..< info.width {
            let base = pixel * stride

            for byte in 0 ..< width {
                let red = row[base + byte]
                row[base + byte] = row[base + 2 * width + byte]
                row[base + 2 * width + byte] = red
            }
        }
    }

    /// Moves the alpha channel from after the colour to before it.
    static func swapAlpha(_ row: UnsafeMutableBufferPointer<UInt8>, _ info: RowInfo) {
        guard info.colorType.hasAlpha, info.bitDepth >= 8 else { return }

        let width = info.bitDepth / 8
        let colorChannels = info.channels - 1
        let stride = info.channels * width

        for pixel in 0 ..< info.width {
            let base = pixel * stride

            // The alpha is lifted out, the colour slides up, and the alpha goes in front.
            for byte in 0 ..< width {
                let alpha = row[base + colorChannels * width + byte]

                var offset = colorChannels * width + byte
                while offset >= width {
                    row[base + offset] = row[base + offset - width]
                    offset -= width
                }

                row[base + byte] = alpha
            }
        }
    }

    /// Turns opacity into transparency, and back.
    static func invertAlpha(_ row: UnsafeMutableBufferPointer<UInt8>, _ info: RowInfo) {
        guard info.colorType.hasAlpha, info.bitDepth >= 8 else { return }

        let width = info.bitDepth / 8
        let stride = info.channels * width
        let alphaOffset = (info.channels - 1) * width

        for pixel in 0 ..< info.width {
            let base = pixel * stride + alphaOffset

            for byte in 0 ..< width {
                row[base + byte] = ~row[base + byte]
            }
        }
    }

    /// Inverts a greyscale row, so that zero reads as white.
    static func invertMono(_ row: UnsafeMutableBufferPointer<UInt8>, _ info: RowInfo) {
        guard !info.colorType.hasColor, !info.colorType.isIndexed else { return }

        guard info.colorType.hasAlpha else {
            // No alpha, so every byte of the row is grey and inverts wholesale.
            for index in 0 ..< info.rowBytes {
                row[index] = ~row[index]
            }

            // Except the bits past the end of the row, which are not pixels and are handed to the
            // client as zeroes.  Inverting them would set them, so they are cleared again here
            // rather than by the caller: this is the only transform that touches them.
            let used = (info.width * info.pixelDepth) % 8

            if used != 0, info.rowBytes > 0 {
                row[info.rowBytes - 1] &= UInt8(truncatingIfNeeded: 0xFF << (8 - used))
            }

            return
        }

        // With alpha, only the grey channel is inverted and the alpha is left alone.
        let width = info.bitDepth / 8
        let stride = info.channels * width

        for pixel in 0 ..< info.width {
            let base = pixel * stride

            for byte in 0 ..< width {
                row[base + byte] = ~row[base + byte]
            }
        }
    }

    /// Reverses the order of samples within each byte.
    ///
    /// Only meaningful below a byte per sample, where several share one.
    static func packSwap(_ row: UnsafeMutableBufferPointer<UInt8>, _ info: RowInfo) {
        guard info.bitDepth < 8 else { return }

        switch info.bitDepth {
        case 1:
            for index in 0 ..< info.rowBytes {
                var value = row[index]
                value = (value >> 4) | (value << 4)
                value = ((value & 0xCC) >> 2) | ((value & 0x33) << 2)
                value = ((value & 0xAA) >> 1) | ((value & 0x55) << 1)
                row[index] = value
            }

        case 2:
            for index in 0 ..< info.rowBytes {
                var value = row[index]
                value = (value >> 4) | (value << 4)
                value = ((value & 0xCC) >> 2) | ((value & 0x33) << 2)
                row[index] = value
            }

        default:
            for index in 0 ..< info.rowBytes {
                row[index] = (row[index] >> 4) | (row[index] << 4)
            }
        }
    }

    /// Exchanges the two bytes of each sixteen bit sample.
    static func swapBytes(_ row: UnsafeMutableBufferPointer<UInt8>, _ info: RowInfo) {
        guard info.bitDepth == 16 else { return }

        for index in 0 ..< info.width * info.channels {
            let high = row[index * 2]
            row[index * 2] = row[index * 2 + 1]
            row[index * 2 + 1] = high
        }
    }
}
