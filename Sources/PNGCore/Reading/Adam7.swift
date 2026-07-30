// Adam7.swift - the seven-pass interlaced layout
//
// An interlaced image is stored as seven subimages, each a sparse grid of the whole.  The
// first is every eighth pixel of every eighth row, so a decoder that has read only that
// pass already has a recognisable eighth-scale version of the picture; each later pass fills
// in more.
//
// Each pass is a complete little image in its own right: its own scanlines, its own filter
// bytes, its own reconstruction starting from a notional row of zeroes.  That is what makes
// the geometry worth having in one place — every buffer size, every filter reach and every
// row count in an interlaced decode is derived from these four tables.

enum Adam7 {
    static let passCount = 7

    /// Where each pass starts, and how far apart its pixels are.
    ///
    /// Read down the columns and the pattern is the eight-by-eight grid the format defines:
    /// pass 0 takes one pixel of every sixty-four, and pass 6 takes every pixel of every
    /// other row.
    static let columnStart = [0, 4, 0, 2, 0, 1, 0]
    static let rowStart = [0, 0, 4, 0, 2, 0, 1]
    static let columnStride = [8, 8, 4, 4, 2, 2, 1]
    static let rowStride = [8, 8, 8, 4, 4, 2, 2]

    /// How many pixels wide a pass is for an image of this width.
    ///
    /// Zero when the image is too narrow to contain any of this pass, which happens for
    /// real images: a four pixel wide image has nothing in pass 1, whose first column is 4.
    static func width(ofPass pass: Int, imageWidth: Int) -> Int {
        let start = Self.columnStart[pass]
        guard imageWidth > start else { return 0 }

        let stride = Self.columnStride[pass]
        return (imageWidth - start + stride - 1) / stride
    }

    static func height(ofPass pass: Int, imageHeight: Int) -> Int {
        let start = Self.rowStart[pass]
        guard imageHeight > start else { return 0 }

        let stride = Self.rowStride[pass]
        return (imageHeight - start + stride - 1) / stride
    }

    /// Whether a pass contains anything at all.
    ///
    /// An empty pass is not present in the stream — not as a zero-length run of scanlines,
    /// but absent — so a decoder has to skip it rather than read nothing from it.
    static func isEmpty(pass: Int, imageWidth: Int, imageHeight: Int) -> Bool {
        Self.width(ofPass: pass, imageWidth: imageWidth) == 0
            || Self.height(ofPass: pass, imageHeight: imageHeight) == 0
    }

    /// Which row of the whole image a pass's row corresponds to.
    static func imageRow(ofPass pass: Int, passRow: Int) -> Int {
        Self.rowStart[pass] + passRow * Self.rowStride[pass]
    }

    /// Which column of the whole image a pass's pixel corresponds to.
    static func imageColumn(ofPass pass: Int, passColumn: Int) -> Int {
        Self.columnStart[pass] + passColumn * Self.columnStride[pass]
    }

    /// The bytes one scanline of a pass occupies, excluding its filter byte.
    static func rowBytes(ofPass pass: Int, header: Header) -> Int {
        Header.rowBytes(
            width: Self.width(ofPass: pass, imageWidth: header.width),
            pixelDepth: header.pixelDepth
        )
    }

    /// The largest scanline any pass of this image has.
    ///
    /// What the row buffer is sized from, so that one allocation serves every pass.
    static func widestRowBytes(header: Header) -> Int {
        var widest = 0

        for pass in 0 ..< Self.passCount {
            widest = max(widest, Self.rowBytes(ofPass: pass, header: header))
        }

        return widest
    }
}

/// Moving single pixels between rows of different geometry.
///
/// De-interlacing is a scatter: each pixel of a pass row belongs at a different column of a
/// full-width row.  Above a byte per pixel that is a short copy, and below one it is bit
/// work, because several pixels share a byte and the neighbours must not be disturbed.
enum PixelCopy {
    /// Copies one pixel from `source` to `destination`.
    ///
    /// The indices are in pixels, not bytes.
    static func copy(
        from source: UnsafeBufferPointer<UInt8>,
        at sourceIndex: Int,
        to destination: UnsafeMutableBufferPointer<UInt8>,
        at destinationIndex: Int,
        pixelDepth: Int
    ) {
        if pixelDepth >= 8 {
            let width = pixelDepth / 8
            let from = sourceIndex * width
            let to = destinationIndex * width

            for offset in 0 ..< width {
                destination[to + offset] = source[from + offset]
            }

            return
        }

        // Several pixels to a byte.  The first pixel of a byte occupies its high bits, which
        // is why the shift counts down from the top rather than up from the bottom.
        let perByte = 8 / pixelDepth
        let mask = UInt8((1 << pixelDepth) - 1)

        let sourceShift = (perByte - 1 - sourceIndex % perByte) * pixelDepth
        let value = (source[sourceIndex / perByte] >> sourceShift) & mask

        let destinationShift = (perByte - 1 - destinationIndex % perByte) * pixelDepth
        let byte = destinationIndex / perByte

        destination[byte] &= ~(mask << destinationShift)
        destination[byte] |= value << destinationShift
    }
}
