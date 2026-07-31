// WriteText.swift - the words a file carries
//
// Three chunks for one idea, and the differences between them are the whole of this file.  The plain
// one holds a keyword and its text in Latin-1; the compressed one holds the same thing deflated,
// which is worth it for anything long and worse than useless for anything short; and the
// international one adds a language and a translated keyword, and holds UTF-8 whether or not it
// compresses the text.
//
// A client says which it wants by a number, and the numbers are the API's own: below zero for the
// plain chunk, zero for the compressed one, and one and two for the international pair.  That
// numbering looks arbitrary because it is — it grew — and reproducing it is the point.

extension SequentialWriter {
    /// Writes every text entry the client has set.
    ///
    /// Called twice, before and after the image data, because the format allows text in both places
    /// and a client that set some before writing rows means those to appear before them.
    func writeTextBeforeRows(_ info: InfoStore, context: PngContext) throws {
        try self.writeText(info, context: context)
    }

    func writeTextAfterRows(_ info: InfoStore, context: PngContext) throws {
        try self.writeText(info, context: context)
    }

    private func writeText(_ info: InfoStore, context: PngContext) throws {
        while self.textWritten < info.textEntries.count {
            let entry = info.textEntries[self.textWritten]

            // Counted before it is written rather than after: an entry the writer refuses is an entry
            // it must not try again from the other side of the image data.
            self.textWritten += 1

            try self.writeTextEntry(entry, context: context)
        }
    }

    private func writeTextEntry(_ entry: TextEntry, context: PngContext) throws {
        let keyword = entry.keyword.bytes
        let text = entry.text.bytes

        // A keyword is what the chunk is indexed by, so a chunk without one says nothing that could
        // be looked up.  The reference refuses it rather than writing it.
        guard keyword.count >= 1, keyword.count <= 79 else {
            throw Diagnostic("Invalid text keyword")
        }

        switch entry.compression {
        case -1:
            try self.write(.text, context: context, count: keyword.count + 1 + text.count) { bytes in
                Self.copy(keyword, into: bytes, at: 0)
                bytes[keyword.count] = 0
                Self.copy(text, into: bytes, at: keyword.count + 1)
            }

        case 0:
            let produced = try self.compressed(text, context: context)

            let body = UnsafeBufferPointer(
                start: context.textStaging.bytes.baseAddress,
                count: produced
            )

            try self.write(
                .ztxt,
                context: context,
                count: keyword.count + 2 + produced
            ) { bytes in
                Self.copy(keyword, into: bytes, at: 0)
                bytes[keyword.count] = 0
                bytes[keyword.count + 1] = 0
                Self.copy(body, into: bytes, at: keyword.count + 2)
            }

        case 1, 2:
            try self.writeInternational(entry, context: context)

        default:
            throw Diagnostic("Unknown compression type")
        }
    }

    /// The international form, which carries a language and a translated keyword as well.
    private func writeInternational(_ entry: TextEntry, context: PngContext) throws {
        let keyword = entry.keyword.bytes
        let language = entry.language.bytes
        let translated = entry.translatedKeyword.bytes
        let text = entry.text.bytes
        let compresses = entry.compression == 2

        let produced = compresses ? try self.compressed(text, context: context) : 0

        let body = compresses
            ? UnsafeBufferPointer(start: context.textStaging.bytes.baseAddress, count: produced)
            : text
        let count = keyword.count + 1 + 2 + language.count + 1 + translated.count + 1 + body.count

        try self.write(.itxt, context: context, count: count) { bytes in
            var offset = 0

            Self.copy(keyword, into: bytes, at: offset)
            offset += keyword.count
            bytes[offset] = 0
            offset += 1

            // Whether the text is compressed, and by what.  The second byte is only meaningful when
            // the first says yes, and the format still requires it to be there.
            bytes[offset] = compresses ? 1 : 0
            bytes[offset + 1] = 0
            offset += 2

            Self.copy(language, into: bytes, at: offset)
            offset += language.count
            bytes[offset] = 0
            offset += 1

            Self.copy(translated, into: bytes, at: offset)
            offset += translated.count
            bytes[offset] = 0
            offset += 1

            Self.copy(body, into: bytes, at: offset)
        }
    }

    /// Deflates a run of bytes into the context's own buffer, and says how much came out.
    ///
    /// A buffer rather than a stream, because a chunk's length comes before its contents: the whole
    /// compressed form has to exist before any of it can be written.  That is unlike the image data,
    /// which is written a bufferful at a time precisely to avoid this.
    ///
    /// The context's buffer rather than one of this function's, because the caller hands what comes
    /// out to the client, and a client may leave from there without returning.  Anything this frame
    /// owned at that moment would be lost; the context's is reclaimed when the structure is.
    @discardableResult
    func compressed(
        _ bytes: UnsafeBufferPointer<UInt8>,
        context: PngContext
    ) throws -> Int {
        let stream = try DeflateStream(settings: context.textCompression)

        defer { stream.release() }

        // Deflate never expands by more than a fraction plus a small header, and this is generous
        // about it: text is small, and growing the buffer mid-stream would mean a second pass.
        var capacity = bytes.count + bytes.count / 8 + 64
        var produced = 0

        try context.reserve(\.textStaging, capacity)

        stream.setInput(bytes)

        while !stream.isFinished {
            if produced == capacity {
                // The estimate was wrong, which for incompressible input it can be.  Rather than
                // guess again, the buffer doubles — and since the context's buffer is replaced rather
                // than grown, what has been produced so far is carried across by hand.
                let carried = try RawBuffer.allocate(produced, host: context.host)

                if produced > 0 {
                    carried.bytes.baseAddress!.update(
                        from: context.textStaging.bytes.baseAddress!,
                        count: produced
                    )
                }

                do {
                    try context.reserve(\.textStaging, capacity * 2)
                } catch {
                    carried.deallocate(host: context.host)
                    throw error
                }

                if produced > 0 {
                    context.textStaging.bytes.baseAddress!.update(
                        from: carried.bytes.baseAddress!,
                        count: produced
                    )
                }

                carried.deallocate(host: context.host)
                capacity *= 2
            }

            produced += try stream.deflate(
                into: context.textStaging.bytes.baseAddress! + produced,
                count: capacity - produced,
                ending: .finish
            )
        }

        return produced
    }

    static func copy(
        _ source: UnsafeBufferPointer<UInt8>,
        into destination: UnsafeMutableBufferPointer<UInt8>,
        at offset: Int
    ) {
        guard source.count > 0 else { return }

        destination.baseAddress!.advanced(by: offset)
            .update(from: source.baseAddress!, count: source.count)
    }
}

extension TextStorage {
    /// The bytes, without the terminator that follows them.
    ///
    /// Public because more than the writer wants them: the accessors that read a number out of a text
    /// field parse these.
    public var bytes: UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(
            start: self.address.map { UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self) },
            count: self.count
        )
    }
}
