// SequentialReader.swift - decoding rows on demand
//
// The client drives this: it calls for a row, and the reader draws whatever
// compressed bytes it needs to produce one.  That inverts the usual arrangement,
// where a decoder consumes a whole stream and emits rows as it goes, and it is why
// the loop is written around "produce exactly one scanline" rather than "consume
// the input".
//
// Every buffer belongs to the context, not to a frame here.  Reading runs the
// client's callback, and a client may jump out of it; anything owned by a frame
// on the Swift stack at that moment would be abandoned without being released.

/// How far through the stream the reader has got.
enum ReadPhase {
    case start
    /// The header has been read and the first image data chunk located.
    case header
    case rows
    /// The image data is exhausted; only trailing chunks remain.
    case imageEnd
    case streamEnd
}

/// Pulls scanlines from a stream on demand.
///
/// A class for the same reason the lexer is one: as a struct property of the
/// context, every `mutating` call would hold an exclusive access to that property
/// across the client's read callback, and a jump out of the callback would leave it
/// open.
final class SequentialReader {
    /// How much of an image data chunk to draw at a time.
    ///
    /// Matches the reference build's default so that the pattern of read callbacks
    /// a client observes is the same.
    static let inputBufferSize = 8192

    private(set) var phase: ReadPhase = .start

    let lexer = ChunkLexer()

    /// How many scanlines of the current pass have been consumed.
    private(set) var rowIndex = 0

    /// Which row of the whole image the next call corresponds to.
    ///
    /// Only meaningful when the client asked for the passes to be spread across full-width
    /// rows.  In that arrangement a client sweeps every row of the image once per pass, and
    /// most of those sweeps are over rows the pass does not contain, so this counts calls
    /// rather than scanlines.
    private(set) var imageRowIndex = 0

    /// Which pass the next row belongs to, or zero for an image that is not interlaced.
    ///
    /// Empty passes are skipped rather than read from: a pass with no pixels is absent from
    /// the stream, not present as nothing.
    private(set) var pass = 0

    /// Set when the checksum of a chunk did not match. What to do about it is the
    /// client's choice, so it is recorded rather than acted on here.
    private(set) var sawBadChecksum = false

    /// Reads up to the first image data chunk, leaving its header current.
    ///
    /// - Parameter signatureBytesConsumed: what the client declared through
    ///   `png_set_sig_bytes`.
    func readInfo(
        into info: InfoStore,
        context: PngContext,
        signatureBytesConsumed: Int
    ) throws {
        guard self.phase == .start else { return }

        try ChunkLexer.readSignature(
            host: context.host,
            alreadyConsumed: signatureBytesConsumed
        )

        var sawHeader = false

        while true {
            let chunk = try self.lexer.readHeader(host: context.host)

            if chunk.name == .ihdr {
                guard !sawHeader else {
                    throw Diagnostic("Duplicate IHDR", chunk: .ihdr)
                }

                try context.reserve(\.scratch, chunk.length)
                try self.lexer.readWholePayload(
                    into: context.scratch.bytes,
                    host: context.host
                )

                let fields = try Header.Fields(
                    parsing: UnsafeBufferPointer(
                        start: context.scratch.bytes.baseAddress,
                        count: chunk.length
                    )
                )

                // Each problem is reported on its own, then the parse fails with one
                // generic message.  A client with a warning handler learns what was
                // actually wrong, which the error alone does not say.
                let problems = fields.problems

                if !problems.isEmpty {
                    problems.report(to: context.host)
                    throw Diagnostic("Invalid IHDR data")
                }

                info.header = Header(fields)

                sawHeader = true
                try self.finishChunk(context: context)
                continue
            }

            // The header has to come first; anything before it means the stream is
            // not laid out the way the format requires.
            guard sawHeader else {
                throw Self.missingHeader(before: chunk.name)
            }

            if chunk.name == .idat {
                // Stop with this chunk current, so the row loop can draw from it.
                self.phase = .header
                return
            }

            // The end marker before any image data: the file is structurally complete
            // but describes no image, which is reported against the marker itself
            // rather than as a missing chunk.
            if chunk.name == .iend {
                throw Diagnostic("out of place", chunk: .iend)
            }

            try self.handleOptional(chunk, info: info, context: context)
        }
    }

    /// Prepares the row buffers. Called once, before the first row.
    func startRows(context: PngContext) throws {
        guard self.phase == .header else { return }

        guard let header = context.header else {
            throw Diagnostic("Missing IHDR")
        }

        // A client that never called png_read_update_info still gets its transforms applied, so
        // the pipeline is resolved here if it has not been already.
        if context.transforms == nil {
            try context.resolveTransforms()
        }

        // Sized for the widest pass, so one allocation serves all seven.  For an image that
        // is not interlaced that is simply the image's own row.
        let widestStored = header.isInterlaced
            ? Adam7.widestRowBytes(header: header)
            : header.rowBytes

        // The transforms run in the same buffer, and some of them make a row larger — a one bit
        // indexed row expanded to colour with alpha grows thirty-twofold — so the buffer is sized
        // for the largest shape the row passes through, not the shape it arrives in or leaves with.
        var widest = widestStored

        if let program = context.transforms {
            let hasTransparency = context.hasTransparency

            for pass in 0 ..< (header.isInterlaced ? Adam7.passCount : 1) {
                let start = header.isInterlaced
                    ? RowInfo(header, pass: pass)
                    : RowInfo(header)

                widest = max(
                    widest,
                    program.maximumRowBytes(from: start, hasTransparency: hasTransparency)
                )
            }
        }

        // One extra byte because the reconstruction reads a filter byte ahead of
        // each scanline.
        try context.reserve(\.rowBuffer, widest + 1)

        // The reference row only ever holds stored bytes, so it is sized for those alone.
        try context.reserve(\.previousRow, widestStored)
        try context.reserve(\.inputBuffer, Self.inputBufferSize)

        context.inflater = try InflateStream()

        self.phase = .rows
        self.pass = 0
        self.rowIndex = 0

        if header.isInterlaced {
            self.skipEmptyPasses(header: header)
        }

        // The filters that refer upwards treat the row above the first as zeroes, and each
        // pass starts afresh: a pass's first row has no predecessor either.
        context.previousRow.zero()
    }

    /// Advances past any pass this image is too small to contain.
    private func skipEmptyPasses(header: Header) {
        while self.pass < Adam7.passCount,
              Adam7.isEmpty(
                  pass: self.pass,
                  imageWidth: header.width,
                  imageHeight: header.height
              ) {
            self.pass += 1
        }
    }

    /// How many scanlines the current pass has.
    private func rowsInCurrentPass(header: Header) -> Int {
        guard header.isInterlaced else { return header.height }
        guard self.pass < Adam7.passCount else { return 0 }

        return Adam7.height(ofPass: self.pass, imageHeight: header.height)
    }

    /// How many bytes a scanline of the current pass occupies.
    private func bytesInCurrentPass(header: Header) -> Int {
        guard header.isInterlaced else { return header.rowBytes }
        guard self.pass < Adam7.passCount else { return 0 }

        return Adam7.rowBytes(ofPass: self.pass, header: header)
    }

    /// Whether every pass has been read.
    var isImageComplete: Bool {
        self.phase == .imageEnd || self.phase == .streamEnd
    }

    /// Decodes one scanline of the current pass into the row buffer, leaving it there.
    ///
    /// Returns how many bytes of it are meaningful, which for an interlaced image is the
    /// current pass's width rather than the image's.
    ///
    /// Advances nothing but the scanline count. What a row means to the client differs
    /// between the three ways of reading, so moving to the next pass is the caller's job.
    @discardableResult
    private func decodeScanline(context: PngContext) throws -> Int {
        if self.phase == .header {
            try self.startRows(context: context)
        }

        guard self.phase == .rows, let header = context.header else {
            throw Diagnostic("no image data to read")
        }

        guard self.rowIndex < self.rowsInCurrentPass(header: header) else {
            throw Diagnostic("all rows have already been read")
        }

        let stored = self.bytesInCurrentPass(header: header)

        // The filter byte and the scanline are one contiguous run in the stream.
        try self.inflateExactly(count: stored + 1, context: context)

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

        // This row becomes the reference for the next one, and it has to be the
        // bytes as stored: the encoder computed its filters against those, so
        // discarding anything first would decode the next row wrongly.
        context.previousRow.bytes.baseAddress!.update(from: row.baseAddress!, count: stored)

        self.rowIndex += 1

        // Applied here rather than at each caller, so that every way of reading a row goes through
        // the same pipeline.  The shape is that of the current pass, which for an interlaced image
        // is narrower than the image's.
        var shape = header.isInterlaced
            ? RowInfo(header, pass: self.pass)
            : RowInfo(header)

        // The bits past the end of the row are cleared before the transforms run, not after.  Every
        // transform that reads a sub-byte row reads only the samples inside the width, and the one
        // that would otherwise disturb the spare bits — inverting greyscale — confines itself to
        // the width for the same reason.
        self.maskTrailingBits(of: shape, in: row)

        guard let program = context.transforms, !program.isEmpty else {
            self.transformedShape = nil
            return stored
        }

        // The buffer is sized for the largest shape the row passes through, so the pipeline is given
        // the whole of it rather than the part currently in use.
        let whole = UnsafeMutableBufferPointer(
            start: context.rowBuffer.bytes.baseAddress! + 1,
            count: context.rowBuffer.count - 1
        )

        program.apply(to: whole, info: &shape, inputs: context.transformInputs)

        self.transformedShape = shape

        return shape.rowBytes
    }

    /// The shape the last decoded row ended up with, when the pipeline changed it.
    private(set) var transformedShape: RowInfo?

    /// Clears the bits past the end of a row.
    ///
    /// A row narrower than a whole number of bytes leaves spare bits that the format says nothing
    /// about, and the reference hands them over as zeroes so that a client sees the same bytes
    /// whatever the encoder wrote there.
    private func maskTrailingBits(
        of shape: RowInfo,
        in row: UnsafeMutableBufferPointer<UInt8>
    ) {
        guard shape.rowBytes > 0, shape.rowBytes <= row.count else { return }

        let used = (shape.width * shape.pixelDepth) % 8

        guard used != 0 else { return }

        row[shape.rowBytes - 1] &= UInt8(truncatingIfNeeded: 0xFF << (8 - used))
    }

    /// Moves to the next pass, or finishes the image when there is none.
    private func advancePass(header: Header, context: PngContext) {
        self.pass += 1
        self.rowIndex = 0
        self.imageRowIndex = 0
        self.skipEmptyPasses(header: header)

        if self.pass >= Adam7.passCount {
            self.phase = .imageEnd
            return
        }

        // Each pass reconstructs from its own notional row of zeroes, so the reference row is
        // cleared rather than carried over from the pass that just ended.
        context.previousRow.zero()
    }

    /// Whether a row of the image is one the current pass carries.
    private func passContains(imageRow: Int) -> Bool {
        guard self.pass < Adam7.passCount else { return false }

        let start = Adam7.rowStart[self.pass]

        guard imageRow >= start else { return false }

        return (imageRow - start) % Adam7.rowStride[self.pass] == 0
    }

    /// Writes a decoded pass scanline into a full-width row at the columns it belongs to.
    ///
    /// Everything between those columns is left as it was, which is what lets a client read
    /// all seven passes into the same rows and end up with the whole picture.
    private func spread(
        _ row: UnsafeBufferPointer<UInt8>,
        ofPass pass: Int,
        into destination: UnsafeMutablePointer<UInt8>,
        header: Header,
        context: PngContext
    ) {
        // The pixels are placed at their transformed size, not their stored one: by this point the
        // pipeline may have widened them, and the destination row is sized for the result.
        let pixelDepth = self.transformedShape?.pixelDepth
            ?? context.transformedShape?.pixelDepth
            ?? header.pixelDepth
        let rowBytes = context.transformedShape?.rowBytes ?? header.rowBytes

        let full = UnsafeMutableBufferPointer(start: destination, count: rowBytes)
        let width = Adam7.width(ofPass: pass, imageWidth: header.width)

        for column in 0 ..< width {
            PixelCopy.copy(
                from: row,
                at: column,
                to: full,
                at: Adam7.imageColumn(ofPass: pass, passColumn: column),
                pixelDepth: pixelDepth
            )
        }
    }

    /// The scanline last decoded, as it sits in the row buffer.
    private func decodedRow(count: Int, context: PngContext) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: context.rowBuffer.bytes.baseAddress! + 1, count: count)
    }

    /// Produces the next row into `destination`.
    ///
    /// What a row means depends on the image and on what the client asked for. For an image
    /// that is not interlaced it is one scanline. For an interlaced one it is a scanline of
    /// the current pass, which is narrower — unless the client called for the passes to be
    /// spread, in which case a call stands for one row of the whole image and only the rows
    /// the pass actually carries consume anything from the stream.
    ///
    /// That last arrangement is the one the reference documents, and it is why a client can
    /// sweep every row of the image seven times without knowing which rows are in which pass.
    ///
    /// `destination` is the client's buffer, so it is written only once the row is complete
    /// and correct.
    func readRow(
        into destination: UnsafeMutablePointer<UInt8>?,
        context: PngContext
    ) throws {
        if self.phase == .header {
            try self.startRows(context: context)
        }

        guard let header = context.header else {
            throw Diagnostic("no image data to read")
        }

        guard header.isInterlaced else {
            let stored = try self.decodeScanline(context: context)

            if let destination {
                destination.update(
                    from: self.decodedRow(count: stored, context: context).baseAddress!,
                    count: stored
                )
            }

            if self.rowIndex >= header.height {
                self.phase = .imageEnd
            }

            return
        }

        guard context.spreadsInterlacedRows else {
            // The client is placing the pass's pixels itself, so it gets the subimage row as
            // it stands and is responsible for calling the right number of times per pass.
            let sourcePass = self.pass
            let stored = try self.decodeScanline(context: context)

            if let destination {
                destination.update(
                    from: self.decodedRow(count: stored, context: context).baseAddress!,
                    count: stored
                )
            }

            if self.rowIndex >= Adam7.height(ofPass: sourcePass, imageHeight: header.height) {
                self.advancePass(header: header, context: context)
            }

            return
        }

        // Sweeps left over after the last pass are ignored rather than refused.  A client
        // following the documented loop makes seven of them whatever the image is, and an
        // image small enough to have empty passes runs out of data before it runs out of
        // sweeps: a single pixel is carried entirely by the first pass, so six of the seven
        // sweeps over it have nothing to do.
        guard self.phase == .rows else { return }

        // A sweep over every row of the image.  Most calls in most passes fall on rows the
        // pass does not carry, and those consume nothing.
        if self.passContains(imageRow: self.imageRowIndex) {
            let sourcePass = self.pass
            let stored = try self.decodeScanline(context: context)

            if let destination {
                self.spread(
                    self.decodedRow(count: stored, context: context),
                    ofPass: sourcePass,
                    into: destination,
                    header: header,
                    context: context
                )
            }
        }

        self.imageRowIndex += 1

        if self.imageRowIndex >= header.height {
            self.advancePass(header: header, context: context)
        }
    }

    /// Decodes the whole image into `rows`, one entry per row of the image.
    ///
    /// Interlacing is resolved here rather than left to the client: each pass's pixels are
    /// scattered to the rows and columns they belong to, so what the client is left with is
    /// the picture rather than seven subimages.
    func readImage(
        rows: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        context: PngContext
    ) throws {
        if self.phase == .header {
            try self.startRows(context: context)
        }

        guard let header = context.header else {
            throw Diagnostic("no image data to read")
        }

        guard header.isInterlaced else {
            for index in 0 ..< header.height {
                try self.readRow(into: rows[index], context: context)
            }
            return
        }

        // A client that resolved the pipeline before asking for the whole image was told a row shape
        // that did not account for the passes being spread, so it has been given a slightly
        // misleading answer.  The image still decodes — the passes are resolved here regardless —
        // but the reference says so, and clients see it.
        if context.clientUpdatedInfo, !context.spreadsInterlacedRows {
            context.host.warn(
                "Interlace handling should be turned on when using png_read_image"
            )
        }

        while self.pass < Adam7.passCount, self.phase == .rows {
            let sourcePass = self.pass
            let passRows = Adam7.height(ofPass: sourcePass, imageHeight: header.height)

            for passRow in 0 ..< passRows {
                let stored = try self.decodeScanline(context: context)

                let imageRow = Adam7.imageRow(ofPass: sourcePass, passRow: passRow)

                if let destination = rows[imageRow] {
                    self.spread(
                        self.decodedRow(count: stored, context: context),
                        ofPass: sourcePass,
                        into: destination,
                        header: header,
                        context: context
                    )
                }
            }

            self.advancePass(header: header, context: context)
        }
    }

    /// Fills the start of the row buffer with exactly `count` decompressed bytes.
    private func inflateExactly(count: Int, context: PngContext) throws {
        guard let inflater = context.inflater else {
            throw Diagnostic("no image data to read")
        }

        let destination = context.rowBuffer.bytes.baseAddress!
        var produced = 0

        while produced < count {
            if inflater.needsInput {
                try self.refillInput(context: context)
            }

            let made = try inflater.inflate(
                into: destination + produced,
                count: count - produced
            )

            produced += made

            if made == 0 {
                // No progress and nothing left to give it: the stream ended before
                // the image did.
                if inflater.isFinished || self.lexer.remainingInChunk == 0 {
                    throw Diagnostic("Not enough image data")
                }
            }
        }
    }

    /// Draws more compressed bytes, moving to the next image data chunk when the
    /// current one runs out.
    private func refillInput(context: PngContext) throws {
        while self.lexer.remainingInChunk == 0 {
            try self.finishChunk(context: context)

            let chunk = try self.lexer.readHeader(host: context.host)

            if chunk.name != .idat {
                // The image data has ended.  Leave this chunk current so that the
                // end-of-stream walk continues from it.
                throw Diagnostic("Not enough image data")
            }
        }

        let buffer = context.inputBuffer.bytes
        let read = self.lexer.readPayload(
            into: buffer.baseAddress!,
            count: buffer.count,
            host: context.host
        )

        context.inflater?.setInput(
            UnsafeMutableBufferPointer(start: buffer.baseAddress!, count: read)
        )
    }

    /// Reads whatever remains of the stream after the image data, up to and
    /// including the end marker.
    func readEnd(info: InfoStore?, context: PngContext) throws {
        guard self.phase == .imageEnd || self.phase == .rows else { return }

        // Image data the client did not read still has to be walked past, since it may
        // have stopped short of the last row.  Only the image data: the condition must not
        // also test for unread bytes, or it would swallow the first metadata chunk after
        // it as well.
        while self.lexer.current?.name == .idat {
            try self.skipChunk(context: context)
            _ = try self.lexer.readHeader(host: context.host)
        }

        // Metadata is allowed after the image data as well as before it, and is reported
        // through the same accessors, so the walk parses rather than discards.
        while true {
            guard let current = self.lexer.current else { return }

            if current.name == .iend {
                try self.finishChunk(context: context)
                self.phase = .streamEnd
                return
            }

            try self.handleOptional(current, info: info, context: context)
            _ = try self.lexer.readHeader(host: context.host)
        }
    }

    /// Reads an optional chunk whole and parses it, or skips it when it is one this
    /// library does not recognise.
    ///
    /// The payload is buffered into the context rather than a local, because reading it
    /// runs the client's callback and a client may jump out of that.
    private func handleOptional(
        _ chunk: ChunkHeader,
        info: InfoStore?,
        context: PngContext
    ) throws {
        // With nowhere to record it, there is nothing to gain from parsing it; the
        // checksum is still verified on the way past.
        guard let info, Self.isRecognised(chunk.name) else {
            try self.skipChunk(context: context)
            return
        }

        // A chunk far larger than anything these carry is refused rather than allocated
        // for: the length comes from the file, and an ancillary chunk is not worth
        // exhausting memory over.
        guard chunk.length <= InfoStore.chunkMallocMax else {
            host: do { context.host.warn("chunk is too large") }
            try self.skipChunk(context: context)
            return
        }

        try context.reserve(\.scratch, max(chunk.length, 1))
        try self.lexer.readWholePayload(into: context.scratch.bytes, host: context.host)

        // The checksum is verified before the contents are trusted, so that a damaged
        // payload is reported as damaged rather than as malformed.
        try self.finishChunk(context: context)

        try self.parseOptional(
            chunk.name,
            payload: UnsafeBufferPointer(
                start: context.scratch.bytes.baseAddress,
                count: chunk.length
            ),
            info: info,
            host: context.host
        )
    }

    /// Names the chunk that turned up where the header should have been.
    ///
    /// The message spells out the chunk rather than relying on the prefix, because
    /// that is how the reference words it and clients match on the text.
    private static func missingHeader(before name: ChunkName) -> Diagnostic {
        switch name {
        case .idat:
            return Diagnostic("Missing IHDR before IDAT", chunk: .idat)
        case .iend:
            return Diagnostic("Missing IHDR before IEND", chunk: .iend)
        case .plte:
            return Diagnostic("Missing IHDR before PLTE", chunk: .plte)
        default:
            return Diagnostic("Missing IHDR", chunk: name)
        }
    }

    /// Discards the current chunk's payload and checks its trailing checksum.
    private func skipChunk(context: PngContext) throws {
        try context.reserve(\.scratch, Self.inputBufferSize)
        self.lexer.skipPayload(host: context.host, scratch: context.scratch.bytes)
        try self.finishChunk(context: context)
    }

    /// Reads the trailing checksum of the current chunk.
    private func finishChunk(context: PngContext) throws {
        guard self.lexer.current != nil else { return }

        if !self.lexer.readAndCheckCrc(host: context.host) {
            // Recorded as well as raised: png_set_crc_action lets a client decide what
            // a mismatch means, and that handling arrives with it.
            self.sawBadChecksum = true
            throw Diagnostic("CRC error", chunk: self.lexer.current?.name)
        }
    }
}
