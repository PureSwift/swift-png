// ParseText.swift - the three text chunks
//
// Three chunks carry text and they are not variations on one layout, so each is parsed
// separately: an uncompressed keyword and value; the same with the value compressed; and
// a form that adds a language tag and a translated keyword, and whose value may be
// compressed or not depending on a flag inside it.
//
// They share their storage, because the API reports all three through one array with a
// field saying which kind each entry was.  A client walks that array and expects the
// strings to stay put, so entries accumulate rather than being replaced, and the array is
// reallocated as it grows.

/// One text entry, in the shape the API reports.
public struct TextEntry {
    public init() {}

    /// Which chunk this came from, as the API's own compression codes: -1 for
    /// uncompressed text, 0 for compressed text, 1 and 2 for the international form
    /// uncompressed and compressed.
    public var compression: Int32 = -1

    public var keyword = TextStorage()
    public var text = TextStorage()
    public var language = TextStorage()
    public var translatedKeyword = TextStorage()

    public func deallocate(host: Host) {
        self.keyword.deallocate(host: host)
        self.text.deallocate(host: host)
        self.language.deallocate(host: host)
        self.translatedKeyword.deallocate(host: host)
    }
}

extension InfoStore {
    /// How many text entries have been collected.
    public var textCount: Int { self.textEntries.count }

    /// Adds an entry, growing the array.
    ///
    /// The entry is passed in fully built: every string it holds is already allocated, so
    /// there is nothing here that can fail part way and leave a half-formed entry in the
    /// array.
    public func appendText(_ entry: TextEntry) throws {
        self.textEntries.append(entry)
    }

    /// Releases every text entry.
    func releaseText() {
        for entry in self.textEntries {
            entry.deallocate(host: self.host)
        }
        self.textEntries.removeAll()
    }

    /// A keyword: one to 79 bytes.
    private func validateKeyword(
        _ keyword: UnsafeBufferPointer<UInt8>,
        chunk: ChunkName
    ) throws {
        guard keyword.count >= 1, keyword.count <= 79 else {
            throw Diagnostic("invalid keyword", chunk: chunk)
        }
    }

    private func separator(
        in payload: UnsafeBufferPointer<UInt8>,
        from start: Int
    ) -> Int? {
        var index = start
        while index < payload.count {
            if payload[index] == 0 { return index }
            index += 1
        }
        return nil
    }

    private func slice(
        _ payload: UnsafeBufferPointer<UInt8>,
        _ range: Range<Int>
    ) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(rebasing: payload[range])
    }

    /// A keyword and an uncompressed value.
    func parseText(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard let end = self.separator(in: payload, from: 0) else {
            throw Diagnostic("malformed", chunk: .text)
        }

        let keyword = self.slice(payload, 0 ..< end)
        try self.validateKeyword(keyword, chunk: .text)

        // The value runs to the end of the chunk and carries no terminator of its own,
        // which is why the storage adds one.
        let value = self.slice(payload, (end + 1) ..< payload.count)

        var entry = TextEntry()
        entry.compression = -1

        do {
            entry.keyword = try TextStorage.copying(keyword, host: self.host)
            entry.text = try TextStorage.copying(value, host: self.host)
        } catch {
            entry.deallocate(host: self.host)
            throw error
        }

        try self.appendText(entry)
    }

    /// A keyword and a compressed value.
    func parseCompressedText(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard let end = self.separator(in: payload, from: 0) else {
            throw Diagnostic("malformed", chunk: .ztxt)
        }

        let keyword = self.slice(payload, 0 ..< end)
        try self.validateKeyword(keyword, chunk: .ztxt)

        guard payload.count > end + 1 else {
            throw Diagnostic("malformed", chunk: .ztxt)
        }

        let method = payload[end + 1]

        guard method == 0 else {
            throw Diagnostic("Unknown compression type", chunk: .ztxt)
        }

        let compressed = self.slice(payload, (end + 2) ..< payload.count)

        var entry = TextEntry()
        entry.compression = 0

        do {
            entry.keyword = try TextStorage.copying(keyword, host: self.host)

            var inflated = try self.inflatePayload(compressed, chunk: .ztxt)
            entry.text = try TextStorage.copying(
                UnsafeBufferPointer(inflated.elements),
                host: self.host
            )
            inflated.deallocate(host: self.host)
        } catch {
            entry.deallocate(host: self.host)
            throw error
        }

        try self.appendText(entry)
    }

    /// A keyword, a language tag, a translated keyword, and a value that may be
    /// compressed.
    func parseInternationalText(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard let keywordEnd = self.separator(in: payload, from: 0) else {
            throw Diagnostic("malformed", chunk: .itxt)
        }

        let keyword = self.slice(payload, 0 ..< keywordEnd)
        try self.validateKeyword(keyword, chunk: .itxt)

        // A compression flag and a method, then two more terminated strings.
        guard payload.count > keywordEnd + 2 else {
            throw Diagnostic("malformed", chunk: .itxt)
        }

        let isCompressed = payload[keywordEnd + 1]
        let method = payload[keywordEnd + 2]

        guard isCompressed == 0 || isCompressed == 1 else {
            throw Diagnostic("invalid compression flag", chunk: .itxt)
        }

        // The method is only meaningful when something is compressed, but the reference
        // checks it either way.
        guard method == 0 else {
            throw Diagnostic("Unknown compression method", chunk: .itxt)
        }

        guard let languageEnd = self.separator(in: payload, from: keywordEnd + 3) else {
            throw Diagnostic("malformed", chunk: .itxt)
        }

        let language = self.slice(payload, (keywordEnd + 3) ..< languageEnd)

        guard let translatedEnd = self.separator(in: payload, from: languageEnd + 1) else {
            throw Diagnostic("malformed", chunk: .itxt)
        }

        let translated = self.slice(payload, (languageEnd + 1) ..< translatedEnd)
        let value = self.slice(payload, (translatedEnd + 1) ..< payload.count)

        var entry = TextEntry()
        // The API distinguishes the international form from the older one, and whether
        // its value was compressed, with these two codes.
        entry.compression = isCompressed == 1 ? 2 : 1

        do {
            entry.keyword = try TextStorage.copying(keyword, host: self.host)
            entry.language = try TextStorage.copying(language, host: self.host)
            entry.translatedKeyword = try TextStorage.copying(translated, host: self.host)

            if isCompressed == 1 {
                var inflated = try self.inflatePayload(value, chunk: .itxt)
                entry.text = try TextStorage.copying(
                    UnsafeBufferPointer(inflated.elements),
                    host: self.host
                )
                inflated.deallocate(host: self.host)
            } else {
                entry.text = try TextStorage.copying(value, host: self.host)
            }
        } catch {
            entry.deallocate(host: self.host)
            throw error
        }

        try self.appendText(entry)
    }
}
