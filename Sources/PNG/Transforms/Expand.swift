// Expand.swift - turning indices and low depths into samples
//
// These are the transforms that make a row wider rather than merely rearranging it, and they are
// the ones clients reach for most: a program that wants pixels rather than palette indices asks
// for the expansion and stops caring what the file happened to contain.
//
// All three grow the row, so all three walk it backwards.  The palette expansion grows it most —
// a one bit indexed row becomes four bytes a pixel, thirty-two times larger — which is what sizes
// the row buffer for the whole pipeline.

extension Transform {
    /// Replaces palette indices with the colours they name.
    ///
    /// An index outside the palette is a defect in the file rather than something to fail on: the
    /// reference substitutes a colour and carries on, so the row still decodes.
    static func paletteToRgb(
        _ row: UnsafeMutableBufferPointer<UInt8>,
        _ info: inout RowInfo,
        palette: UnsafeBufferPointer<Rgb8>,
        alpha: UnsafeBufferPointer<UInt8>
    ) {
        guard info.colorType.isIndexed else { return }

        let withAlpha = !alpha.isEmpty
        let channels = withAlpha ? 4 : 3
        let depth = info.bitDepth
        let perByte = depth < 8 ? 8 / depth : 1
        let mask = UInt8((1 << min(depth, 8)) - 1)

        for pixel in stride(from: info.width - 1, through: 0, by: -1) {
            let index: Int

            if depth < 8 {
                let shift = (perByte - 1 - pixel % perByte) * depth
                index = Int((row[pixel / perByte] >> shift) & mask)
            } else {
                index = Int(row[pixel])
            }

            let target = pixel * channels

            // Out of range reads as black, and as transparent when there is an alpha channel,
            // rather than as whatever happened to be adjacent in memory.
            let entry = index < palette.count ? palette[index] : Rgb8()

            row[target] = entry.red
            row[target + 1] = entry.green
            row[target + 2] = entry.blue

            if withAlpha {
                // A table shorter than the palette says nothing about the entries past its end, and
                // what it does not mention is opaque.
                row[target + 3] = index < alpha.count ? alpha[index] : 0xFF
            }
        }

        info.colorType = withAlpha ? .rgba : .rgb
        info.channels = channels
        info.bitDepth = 8
        info.resize()
    }

    /// Widens greyscale samples narrower than a byte to a full byte each.
    ///
    /// The values are scaled to the new range rather than merely unpacked, so that a one bit
    /// sample of 1 becomes 255 and reads as white. That is what separates this from the packing
    /// transform, which unpacks without scaling.
    static func grayTo8(_ row: UnsafeMutableBufferPointer<UInt8>, _ info: inout RowInfo) {
        guard info.colorType == .grayscale, info.bitDepth < 8 else { return }

        let depth = info.bitDepth
        let perByte = 8 / depth
        let mask = UInt8((1 << depth) - 1)

        // Repeating the bit pattern is what scales it: 0b1 becomes 0b11111111, 0b10 becomes
        // 0b10101010, and both land at the right place in the eight bit range.
        let multiplier: UInt8 = depth == 1 ? 0xFF : (depth == 2 ? 0x55 : 0x11)

        for pixel in stride(from: info.width - 1, through: 0, by: -1) {
            let shift = (perByte - 1 - pixel % perByte) * depth
            let value = (row[pixel / perByte] >> shift) & mask

            row[pixel] = value &* multiplier
        }

        info.bitDepth = 8
        info.resize()
    }

    /// Adds an alpha channel derived from the file's transparent colour.
    ///
    /// Every pixel matching that colour becomes fully transparent and everything else fully
    /// opaque, which is the whole of what the chunk means for a non-indexed image.
    static func transparencyToAlpha(
        _ row: UnsafeMutableBufferPointer<UInt8>,
        _ info: inout RowInfo,
        transparent: Rgb16
    ) {
        guard !info.colorType.hasAlpha, !info.colorType.isIndexed, info.bitDepth >= 8 else {
            return
        }

        let width = info.bitDepth / 8
        let sourceChannels = info.channels
        let targetChannels = sourceChannels + 1
        let opaque: UInt8 = 0xFF

        let isColor = info.colorType.hasColor

        // The chunk stores the colour at sixteen bits whatever the image's depth, so the
        // comparison is made at the image's depth.
        let keyRed = width == 2 ? transparent.red : UInt16(transparent.red & 0xFF)
        let keyGreen = width == 2 ? transparent.green : UInt16(transparent.green & 0xFF)
        let keyBlue = width == 2 ? transparent.blue : UInt16(transparent.blue & 0xFF)
        let keyGray = width == 2 ? transparent.gray : UInt16(transparent.gray & 0xFF)

        for pixel in stride(from: info.width - 1, through: 0, by: -1) {
            let source = pixel * sourceChannels * width
            let target = pixel * targetChannels * width

            func sample(_ channel: Int) -> UInt16 {
                width == 2
                    ? UInt16(row[source + channel * 2]) << 8 | UInt16(row[source + channel * 2 + 1])
                    : UInt16(row[source + channel])
            }

            let matches: Bool

            if isColor {
                matches = sample(0) == keyRed && sample(1) == keyGreen && sample(2) == keyBlue
            } else {
                matches = sample(0) == keyGray
            }

            // Moved backwards within the pixel, since the colour slides down and the alpha goes
            // after it.
            for byte in stride(from: sourceChannels * width - 1, through: 0, by: -1) {
                row[target + byte] = row[source + byte]
            }

            let alpha: UInt8 = matches ? 0 : opaque

            for byte in 0 ..< width {
                row[target + sourceChannels * width + byte] = alpha
            }
        }

        info.colorType = isColor ? .rgba : .grayscaleAlpha
        info.channels = targetChannels
        info.resize()
    }
}
