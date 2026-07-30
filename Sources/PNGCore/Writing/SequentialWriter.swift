// SequentialWriter.swift - producing a file, a row at a time
//
// The mirror of the sequential reader, and shaped by the same constraint: a client hands over one row
// at a time and the file has to be produced as it goes, because an encoder that needed the whole image
// at once would need the whole image in memory.
//
// So the order the client calls in is the order the file comes out in, and the writer's job is mostly
// to insist on that order.  A chunk written after the image data cannot be moved before it, and the
// format says which chunks belong where — so a client that asks for a palette after the first row is
// making a mistake that cannot be repaired, and is told.
//
// A class rather than a struct, and for the reason everything else here is: it is held by the context,
// and a client jumping out of its own write callback must not be able to leave an exclusive access to
// it open behind them.

/// One image being written.
final class SequentialWriter {
    /// How far through the file the writer has got.
    ///
    /// The order is the format's own, and each step forbids what came before it.
    enum Stage: Int, Comparable {
        case start = 0
        case beforePalette = 1
        case afterPalette = 2
        case rows = 3
        case ended = 4

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    private(set) var stage: Stage = .start

    /// Which row of the current pass comes next, and which pass that is.
    private(set) var rowIndex = 0
    private(set) var pass = 0

    /// Which of the seven passes are being written, for an interlaced image.
    private(set) var writesInterlaced = false

    var deflater: DeflateStream?

    /// Whether anything has been handed to the compressor yet.
    ///
    /// Distinguishes an image with no rows written from one part way through, which matters at the end:
    /// the compressor has to be finished either way, but a stream that was never started has nothing to
    /// finish.
    private var startedImageData = false

    func beginFile(context: PngContext) throws {
        guard self.stage == .start else { return }

        try context.reserve(\.writeStaging, 8)

        var writer = context.chunkWriter
        writer.writeSignature()

        self.stage = .beforePalette
    }

    /// Writes the header chunk, which every other chunk's meaning depends on.
    func writeHeader(_ fields: Header.Fields, _ header: Header, context: PngContext) throws {
        try self.beginFile(context: context)

        try context.reserve(\.scratch, 13)

        let bytes = context.scratch.bytes

        Self.put32(bytes, 0, fields.width)
        Self.put32(bytes, 4, fields.height)
        bytes[8] = fields.bitDepth
        bytes[9] = fields.colorType
        bytes[10] = fields.compressionMethod
        bytes[11] = fields.filterMethod
        bytes[12] = fields.interlaceMethod

        var writer = context.chunkWriter
        writer.write(.ihdr, UnsafeBufferPointer(start: bytes.baseAddress, count: 13))

        self.writesInterlaced = header.isInterlaced
    }

    /// Writes the palette, which for an indexed image the file is unreadable without.
    func writePalette(_ info: InfoStore, context: PngContext) throws {
        let entries = info.palette.elements

        guard entries.count > 0 else {
            throw Diagnostic("Valid palette required for paletted images")
        }

        let count = entries.count * 3

        try context.reserve(\.scratch, count)

        let bytes = context.scratch.bytes

        for index in 0 ..< entries.count {
            bytes[index * 3] = entries[index].red
            bytes[index * 3 + 1] = entries[index].green
            bytes[index * 3 + 2] = entries[index].blue
        }

        var writer = context.chunkWriter
        writer.write(.plte, UnsafeBufferPointer(start: bytes.baseAddress, count: count))

        self.stage = .afterPalette
    }

    /// Compresses one scanline and emits whatever chunks that fills.
    func writeRow(_ row: UnsafeBufferPointer<UInt8>, context: PngContext) throws {
        guard let header = context.header else {
            throw Diagnostic("png_write_row called before png_write_info")
        }

        guard self.stage < .ended else {
            throw Diagnostic("png_write_row called after png_write_end")
        }

        if self.stage < .rows {
            try self.startImageData(context: context)
        }

        let stored = RowInfo(header).rowBytes

        guard stored > 0 else { return }

        try context.reserve(\.rowBuffer, stored + 1)
        try context.reserve(\.filterScratch, stored)

        // The row the client handed over is theirs, so the encoding is done into ours.
        let encoded = UnsafeMutableBufferPointer(
            start: context.rowBuffer.bytes.baseAddress!,
            count: stored + 1
        )

        FilterSelect.encode(
            UnsafeBufferPointer(start: row.baseAddress, count: stored),
            previous: UnsafeBufferPointer(
                start: context.previousRow.bytes.baseAddress,
                count: stored
            ),
            stride: header.filterStride,
            allowed: context.filters,
            into: encoded,
            scratch: UnsafeMutableBufferPointer(
                start: context.filterScratch.bytes.baseAddress!,
                count: stored
            )
        )

        // The row as the client gave it, which is what the next row is differenced against.
        context.previousRow.bytes.baseAddress!.update(from: row.baseAddress!, count: stored)

        try self.compress(
            UnsafeBufferPointer(start: encoded.baseAddress, count: stored + 1),
            context: context
        )

        self.rowIndex += 1
    }

    /// Finishes the compressed stream and writes the chunk that ends the file.
    func writeEnd(context: PngContext) throws {
        guard self.stage < .ended else { return }

        if self.startedImageData {
            try self.finishImageData(context: context)
        }

        var writer = context.chunkWriter
        writer.begin(.iend, length: 0)
        writer.end()

        self.stage = .ended
    }

    // -- the image data ------------------------------------------------------

    private func startImageData(context: PngContext) throws {
        guard let header = context.header else { return }

        let widest = header.isInterlaced
            ? Adam7.widestRowBytes(header: header)
            : header.rowBytes

        try context.reserve(\.previousRow, widest)
        context.previousRow.bytes.baseAddress!.update(repeating: 0, count: widest)

        try context.reserve(\.inputBuffer, max(context.compression.bufferSize, 1024))

        self.deflater = try DeflateStream(settings: context.compression)
        self.startedImageData = true
        self.stage = .rows
    }

    /// Hands one filtered row to the compressor and writes out whatever comes back.
    private func compress(
        _ bytes: UnsafeBufferPointer<UInt8>,
        context: PngContext
    ) throws {
        guard let deflater = self.deflater else { return }

        deflater.setInput(bytes)

        while !deflater.needsInput {
            try self.drain(deflater, context: context, finishing: false)
        }
    }

    private func finishImageData(context: PngContext) throws {
        guard let deflater = self.deflater else { return }

        deflater.setInput(UnsafeBufferPointer(start: nil, count: 0))

        while !deflater.isFinished {
            try self.drain(deflater, context: context, finishing: true)
        }

        deflater.release()
        self.deflater = nil
    }

    /// Takes one bufferful out of the compressor and writes it as a chunk.
    ///
    /// One chunk per bufferful rather than one chunk for the whole image, because the length comes
    /// before the contents on the wire: writing it as one chunk would mean holding the whole compressed
    /// image to find out how long it is.
    private func drain(
        _ deflater: DeflateStream,
        context: PngContext,
        finishing: Bool
    ) throws {
        let capacity = context.inputBuffer.count
        let produced = try deflater.deflate(
            into: context.inputBuffer.bytes.baseAddress!,
            count: capacity,
            finishing: finishing
        )

        // Nothing came back: the compressor is holding what it was given, which is what it does until
        // it has enough to work with.  An empty chunk would be legal and pointless.
        guard produced > 0 else { return }

        var writer = context.chunkWriter
        writer.write(
            .idat,
            UnsafeBufferPointer(start: context.inputBuffer.bytes.baseAddress, count: produced)
        )
    }

    static func put32(_ bytes: UnsafeMutableBufferPointer<UInt8>, _ offset: Int, _ value: UInt32) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 24)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value)
    }
}
