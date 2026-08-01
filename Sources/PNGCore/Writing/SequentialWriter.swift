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

    /// Whether the file is interlaced at all.
    private(set) var isInterlaced = false

    /// Whether the client is handing over full-width rows and leaving the passes to the library.
    ///
    /// Set by `png_set_interlace_handling`.  Without it a client writing an interlaced image is
    /// promising to hand over the narrow rows of each pass itself, already reduced — which is a
    /// different contract, and the one the format's own geometry is expressed in.
    var spreadsPasses = false

    var deflater: DeflateStream?

    /// How many text entries have already been written.
    ///
    /// Kept because the same list is written twice, once before the image data and once after: a
    /// client that adds text between the two means the second lot to appear after the rows, and one
    /// that does not must not have its text written twice.
    var textWritten = 0

    /// What the client's rows have to go through before they are the file's.
    ///
    /// Built once, when the first row arrives, because it depends on requests a client may make right
    /// up until then.
    private(set) var transforms: WriteTransformProgram?

    /// How many rows have been written since the output was last pushed.
    private var rowsSinceFlush = 0

    /// A chunk the client is filling in itself, kept across the calls that fill it.
    ///
    /// The one piece of writer state that has to survive between calls rather than living on a frame,
    /// because the client is doing the filling and decides when it is done.
    private var clientChunk: ChunkWriter?

    /// Whether anything has been handed to the compressor yet.
    ///
    /// Distinguishes an image with no rows written from one part way through, which matters at the end:
    /// the compressor has to be finished either way, but a stream that was never started has nothing to
    /// finish.
    private var startedImageData = false

    func beginFile(context: PngContext) throws(Diagnostic) {
        guard self.stage == .start else { return }

        try context.reserve(.writeStaging, 8)

        var writer = context.chunkWriter
        writer.writeSignature()

        self.stage = .beforePalette
    }

    /// Writes the header chunk, which every other chunk's meaning depends on.
    func writeHeader(_ fields: Header.Fields, _ header: Header, context: PngContext) throws(Diagnostic) {
        try self.beginFile(context: context)

        try context.reserve(.scratch, 13)

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

        self.isInterlaced = header.isInterlaced
    }

    /// Writes the palette, which for an indexed image the file is unreadable without.
    func writePalette(_ info: InfoStore, context: PngContext) throws(Diagnostic) {
        let entries = info.palette.elements

        guard entries.count > 0 else {
            throw Diagnostic("Valid palette required for paletted images")
        }

        let count = entries.count * 3

        try context.reserve(.scratch, count)

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
    func writeRow(_ row: UnsafeBufferPointer<UInt8>, context: PngContext) throws(Diagnostic) {
        guard let header = context.header else {
            throw Diagnostic("png_write_row called before png_write_info")
        }

        guard self.stage < .ended else {
            throw Diagnostic("png_write_row called after png_write_end")
        }

        if self.stage < .rows {
            try self.startImageData(context: context)
        }

        // The indices as the client is handing them over, which is what it will be told about.  A row
        // naming an entry the palette has not got is not a row this library can write meaningfully,
        // but it is written anyway and the complaint is made once the image is done — which is the
        // reference's arrangement, and the kinder one: a client learns about all of its rows rather
        // than about the first one that went wrong.
        if header.colorType.isIndexed {
            context.notePaletteIndices(row, width: header.width, bitDepth: header.bitDepth)
        }

        // An interlaced image the library is placing rows into: the client hands over every row of
        // the image once per pass, and the ones this pass does not contain are counted and dropped.
        // That is the reference's arrangement, and it is what lets a client write the seven passes
        // without knowing the geometry of any of them.
        if self.isInterlaced, self.spreadsPasses {
            guard self.pass < Adam7.passCount else { return }

            // The row is written before the counters move, and that is not a matter of taste: the row
            // that ends a pass is itself a row that pass may want, and starting the next pass first
            // would both test it against the wrong pass and hand it the next pass's blank slate to
            // difference against.
            let imageRow = self.rowIndex

            if Self.pass(self.pass, contains: imageRow) {
                // Transformed before the pass takes its pixels out of it, because the transforms are
                // about what the client's row *is* and the gather is about which of its pixels this
                // pass wants.  Reducing first would mean transforming a row that no longer has the
                // shape the client described.
                let transformed = try self.transformed(row, header: header, context: context)

                try self.writePassRow(
                    transformed,
                    pass: self.pass,
                    header: header,
                    context: context
                )
            }

            self.rowIndex += 1

            if self.rowIndex >= header.height {
                self.rowIndex = 0
                self.pass += 1
                self.startPass(header: header, context: context)
            }

            return
        }

        let stored = RowInfo(header).rowBytes

        guard stored > 0 else { return }

        // A client's rows are the client's: they are copied before anything is done to them, which is
        // what lets a client hand over the same row twice, or a row it goes on using.
        let transformed = try self.transformed(row, header: header, context: context)

        try self.encodeAndCompress(transformed, stored: stored, header: header, context: context)

        self.rowIndex += 1
        try self.flushIfDue(context: context)
    }

    /// Puts a client's row into the shape the file stores, in a buffer of ours.
    ///
    /// Returns the row unchanged when there is nothing to do, so the ordinary case copies nothing.
    private func transformed(
        _ row: UnsafeBufferPointer<UInt8>,
        header: Header,
        context: PngContext
    ) throws(Diagnostic) -> UnsafeBufferPointer<UInt8> {
        guard let program = self.transforms else { return row }

        let supplied = program.suppliedShape.rowBytes

        try context.reserve(.writeRowBuffer, max(supplied, RowInfo(header).rowBytes))

        let working = UnsafeMutableBufferPointer(
            start: context.writeRowBuffer.bytes.baseAddress!,
            count: context.writeRowBuffer.count
        )

        working.baseAddress!.update(from: row.baseAddress!, count: supplied)

        // The client's own transform runs before everything the library does, which is the mirror of
        // where it runs on the way in — and it is shown the row as the client is handing it over
        // rather than as the file will store it.  For a client that packs its samples those are
        // different shapes, and the difference is visible: a transform told the file's depth would
        // touch bits that are about to be discarded.
        //
        // What the client declared through png_set_user_transform_info has no effect here.  That call
        // says what a row will look like *after* a transform, which on the way out is the shape the
        // file already fixes.
        if context.transformFlags.contains(.userTransform), let transform = host(context) {
            let shape = program.suppliedShape

            _ = transform(
                context.host.owner,
                working.baseAddress,
                UInt32(shape.width),
                UInt32(shape.bitDepth),
                UInt32(shape.channels),
                UInt32(shape.colorType.rawValue)
            )
        }

        let shape = program.apply(to: working, significant: context.shiftBits)

        return UnsafeBufferPointer(start: working.baseAddress, count: shape.rowBytes)
    }

    /// The client's own transform, when one is installed.
    private func host(_ context: PngContext) -> Host.UserTransform? {
        context.host.writeUserTransform
    }

    /// Pushes the output when the client asked for that every so many rows.
    private func flushIfDue(context: PngContext) throws(Diagnostic) {
        guard context.flushEveryRows > 0 else { return }

        self.rowsSinceFlush += 1

        if self.rowsSinceFlush >= context.flushEveryRows {
            try self.flush(context: context)
        }
    }

    /// Filters one scanline and hands it to the compressor.
    private func encodeAndCompress(
        _ row: UnsafeBufferPointer<UInt8>,
        stored: Int,
        header: Header,
        context: PngContext
    ) throws(Diagnostic) {
        try context.reserve(.rowBuffer, stored + 1)
        try context.reserve(.filterScratch, stored * 2)

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

        // The row as it was before filtering, which is what the next row is differenced against.
        context.previousRow.bytes.baseAddress!.update(from: row.baseAddress!, count: stored)

        try self.compress(
            UnsafeBufferPointer(start: encoded.baseAddress, count: stored + 1),
            context: context
        )
    }

    /// Whether a pass takes rows from this row of the image.
    static func pass(_ pass: Int, contains imageRow: Int) -> Bool {
        guard pass < Adam7.passCount else { return false }

        return imageRow % Adam7.rowStride[pass] == Adam7.rowStart[pass]
    }

    /// Reduces one full-width row to the pixels this pass keeps, and encodes that.
    ///
    /// The reduction is a gather, and the mirror of what the reader scatters: the pass takes every
    /// nth pixel starting from an offset, so its row is shorter than the image's and its pixels are
    /// not adjacent in the row they came from.
    private func writePassRow(
        _ row: UnsafeBufferPointer<UInt8>,
        pass: Int,
        header: Header,
        context: PngContext
    ) throws(Diagnostic) {
        let width = Adam7.width(ofPass: pass, imageWidth: header.width)

        guard width > 0 else { return }

        let stored = Adam7.rowBytes(ofPass: pass, header: header)

        try context.reserve(.rowBuffer, stored + 1)
        try context.reserve(.filterScratch, stored * 2)

        // Gathered into the second half of the filter scratch, which is sized for two rows: the first
        // half is what the filters try their candidates in, and both are wanted at once.
        let gathered = UnsafeMutableBufferPointer(
            start: context.filterScratch.bytes.baseAddress! + stored,
            count: stored
        )

        gathered.baseAddress!.update(repeating: 0, count: stored)

        for column in 0 ..< width {
            PixelCopy.copy(
                from: row,
                at: Adam7.imageColumn(ofPass: pass, passColumn: column),
                to: gathered,
                at: column,
                pixelDepth: header.pixelDepth
            )
        }

        try self.encodeAndCompress(
            UnsafeBufferPointer(gathered),
            stored: stored,
            header: header,
            context: context
        )
    }

    /// Starts a pass, whose rows are differenced against each other and not against the pass before.
    private func startPass(header: Header, context: PngContext) {
        guard self.pass < Adam7.passCount else { return }

        let stored = Adam7.rowBytes(ofPass: self.pass, header: header)

        if stored > 0, context.previousRow.count >= stored {
            context.previousRow.bytes.baseAddress!.update(repeating: 0, count: stored)
        }
    }

    /// Finishes the compressed stream and writes the chunk that ends the file.
    func writeEnd(_ info: InfoStore?, context: PngContext) throws(Diagnostic) {
        // Said once, about the image rather than about a row, and said as a fault rather than as a
        // remark: a file whose rows name entries its palette has not got is a file nothing can read
        // properly, so writing one is refused unless the client has said it can live with it.
        //
        // Reported by calling rather than by throwing, because a client that said it can live with
        // this expects the file to be finished regardless, and a throw would abandon it here.
        if let info, !info.palette.elements.isEmpty,
           context.highestPaletteIndex >= info.palette.elements.count {
            context.host.benignError("Wrote palette index exceeding num_palette")
        }

        guard self.stage < .ended else { return }

        if self.startedImageData {
            try self.finishImageData(context: context)
        }

        // After the image data and not before it, which is the whole reason this is here rather than
        // at the call site: a chunk written between two pieces of the image data ends the image as far
        // as a decoder is concerned, and everything after it is lost.
        if let info {
            try self.writeUnknown(info, afterImageData: true, context: context)
            try self.writeTextAfterRows(info, context: context)
        }

        var writer = context.chunkWriter
        writer.begin(.iend, length: 0)
        writer.end()

        self.stage = .ended
    }

    // -- chunks the client writes itself -------------------------------------

    func beginClientChunk(_ name: ChunkName, length: Int, context: PngContext) throws(Diagnostic) {
        try self.beginFile(context: context)

        var writer = context.chunkWriter
        writer.begin(name, length: length)
        self.clientChunk = writer
    }

    func writeClientChunkData(_ bytes: UnsafeBufferPointer<UInt8>, context: PngContext) {
        guard var writer = self.clientChunk, bytes.count > 0 else { return }

        writer.data(bytes)
        self.clientChunk = writer
    }

    func endClientChunk(context: PngContext) {
        guard var writer = self.clientChunk else { return }

        writer.end()
        self.clientChunk = nil
    }

    // -- the image data ------------------------------------------------------

    private func startImageData(context: PngContext) throws(Diagnostic) {
        guard let header = context.header else { return }

        let widest = header.isInterlaced
            ? Adam7.widestRowBytes(header: header)
            : header.rowBytes

        try context.reserve(.previousRow, widest)
        try context.reserve(.filterScratch, widest * 2)
        context.previousRow.bytes.baseAddress!.update(repeating: 0, count: widest)

        try context.reserve(.inputBuffer, max(context.compression.bufferSize, 1024))

        // Built here rather than when the header was written, because a client may ask for a
        // transform right up until it hands over its first row.
        let program = WriteTransformProgram(
            flags: context.transformFlags,
            header: header,
            fillerAfterColor: context.fillerAfterColor
        )

        // A transform of the client's own forces the copy even when nothing else would, since the
        // client's row is the client's and this one writes into it.
        if !program.isEmpty || context.transformFlags.contains(.userTransform) {
            self.transforms = program

            // The client's row is wider than the file's when it is supplying a channel the file has
            // no room for, or a byte per sample where the file packs several.
            try context.reserve(.writeRowBuffer, max(program.suppliedShape.rowBytes, widest))
        }

        self.deflater = try DeflateStream(settings: context.compression)
        self.startedImageData = true
        self.stage = .rows
    }

    /// Hands one filtered row to the compressor and writes out whatever comes back.
    private func compress(
        _ bytes: UnsafeBufferPointer<UInt8>,
        context: PngContext
    ) throws(Diagnostic) {
        guard let deflater = self.deflater else { return }

        deflater.setInput(bytes)

        while !deflater.needsInput {
            try self.drain(deflater, context: context, ending: .none)
        }
    }

    /// Empties the compressor and asks the caller to push what it has.
    ///
    /// Both halves are needed and neither is enough: the compressor is holding bytes it has not
    /// decided how to encode yet, and whatever the client writes through is holding bytes it has not
    /// decided when to send.
    func flush(context: PngContext) throws(Diagnostic) {
        if let deflater = self.deflater, self.startedImageData, !deflater.isFinished {
            var produced = 0

            repeat {
                produced = try self.drainOnce(deflater, context: context, ending: .flush)
            } while produced > 0
        }

        context.host.flush()
        self.rowsSinceFlush = 0
    }

    private func finishImageData(context: PngContext) throws(Diagnostic) {
        guard let deflater = self.deflater else { return }

        deflater.setInput(UnsafeBufferPointer(start: nil, count: 0))

        while !deflater.isFinished {
            try self.drain(deflater, context: context, ending: .finish)
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
        ending: DeflateStream.Ending
    ) throws(Diagnostic) {
        _ = try self.drainOnce(deflater, context: context, ending: ending)
    }

    @discardableResult
    private func drainOnce(
        _ deflater: DeflateStream,
        context: PngContext,
        ending: DeflateStream.Ending
    ) throws(Diagnostic) -> Int {
        let capacity = context.inputBuffer.count
        let produced = try deflater.deflate(
            into: context.inputBuffer.bytes.baseAddress!,
            count: capacity,
            ending: ending
        )

        // Nothing came back: the compressor is holding what it was given, which is what it does until
        // it has enough to work with.  An empty chunk would be legal and pointless.
        guard produced > 0 else { return 0 }

        var writer = context.chunkWriter
        writer.write(
            .idat,
            UnsafeBufferPointer(start: context.inputBuffer.bytes.baseAddress, count: produced)
        )

        return produced
    }

    static func put32(_ bytes: UnsafeMutableBufferPointer<UInt8>, _ offset: Int, _ value: UInt32) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 24)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value)
    }
}
