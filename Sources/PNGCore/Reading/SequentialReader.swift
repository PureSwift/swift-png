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

    /// The row index the next call will produce.
    private(set) var rowIndex = 0

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

        guard !header.isInterlaced else {
            throw Diagnostic("interlaced images are not supported yet")
        }

        // One extra byte because the reconstruction reads a filter byte ahead of
        // each scanline.
        try context.reserve(\.rowBuffer, header.rowBytes + 1)
        try context.reserve(\.previousRow, header.rowBytes)
        try context.reserve(\.inputBuffer, Self.inputBufferSize)

        // The filters that refer upwards treat the row above the first as zeroes.
        context.previousRow.zero()

        context.inflater = try InflateStream()

        self.phase = .rows
        self.rowIndex = 0
    }

    /// Produces the next scanline into `destination`.
    ///
    /// `destination` is the client's buffer, so it is written only once the row is
    /// complete and correct.
    func readRow(
        into destination: UnsafeMutablePointer<UInt8>?,
        context: PngContext
    ) throws {
        if self.phase == .header {
            try self.startRows(context: context)
        }

        guard self.phase == .rows, let header = context.header else {
            throw Diagnostic("no image data to read")
        }

        guard self.rowIndex < header.height else {
            throw Diagnostic("all rows have already been read")
        }

        let stored = header.rowBytes

        // The filter byte and the scanline are one contiguous run in the stream.
        try self.inflateExactly(count: stored + 1, context: context)

        let raw = context.rowBuffer.bytes

        guard let filter = Filter(rawValue: raw[0]) else {
            throw Diagnostic("bad adaptive filter value")
        }

        let row = UnsafeMutableBufferPointer(
            start: raw.baseAddress! + 1,
            count: stored
        )

        Defilter.apply(
            filter,
            to: row,
            previous: UnsafeBufferPointer(context.previousRow.bytes),
            stride: header.filterStride
        )

        // This row becomes the reference for the next one, and it has to be the
        // bytes as stored: the encoder computed its filters against those, so
        // discarding anything first would decode the next row wrongly.
        context.previousRow.bytes.baseAddress!.update(
            from: row.baseAddress!,
            count: stored
        )

        // Only what the client sees is tidied.  A row narrower than a whole number
        // of bytes leaves spare bits the format says nothing about, and clearing
        // them means a client gets the same bytes whatever the encoder wrote there.
        if let mask = header.trailingBitMask, stored > 0 {
            row[stored - 1] &= mask
        }

        if let destination {
            destination.update(from: row.baseAddress!, count: stored)
        }

        self.rowIndex += 1

        if self.rowIndex == header.height {
            self.phase = .imageEnd
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
