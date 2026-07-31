// ParseCompressed.swift - chunks whose payload is a compressed or delimited blob
//
// These are the awkward ones.  Their payloads are not fixed-size fields but sequences
// of null-separated strings, some of them followed by compressed data whose
// decompressed size the chunk does not state.
//
// Two things follow from that.  A separator has to be found rather than assumed, and a
// payload with no separator in it is malformed rather than a payload with one field.  And
// decompressing needs a limit that does not come from the file: a small chunk can expand
// without bound, so the cap is ours to impose, and it is the same cap the reference
// applies.

extension InfoStore {
    /// The largest a decompressed payload may become.
    ///
    /// Not derived from the file, deliberately.  A few hundred bytes of input can expand
    /// to gigabytes, and a decoder that trusted the input to be reasonable would be a
    /// way to exhaust memory. This is the reference build's default.
    static let chunkMallocMax = 8_000_000

    /// The size of the fixed header every colour profile begins with.
    ///
    /// A payload shorter than this is not a profile, so it is refused rather than reported
    /// as one a client would then read past the end of.
    static let minimumProfileLength = 132

    /// The fewest tags a profile may describe.
    ///
    /// Two, which is the reference's rule and not a size in disguise: it refuses a profile
    /// carrying one tag however large the payload is, and accepts one carrying two.
    static let minimumProfileTags = 2

    /// Finds the null that ends a field.
    ///
    /// Returns nil when there is none, which makes the payload malformed rather than a
    /// single unterminated field: every chunk that uses this requires the separator.
    private static func separator(
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

    /// A slice of a payload, without copying it.
    private static func slice(
        _ payload: UnsafeBufferPointer<UInt8>,
        _ range: Range<Int>
    ) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(rebasing: payload[range])
    }

    /// A keyword: between one and 79 bytes, and the leading field of every text chunk
    /// and of the colour profile.
    private static func validateKeyword(
        _ keyword: UnsafeBufferPointer<UInt8>,
        chunk: ChunkName
    ) throws {
        guard keyword.count >= 1, keyword.count <= 79 else {
            throw Diagnostic("invalid keyword", chunk: chunk)
        }
    }

    /// The embedded colour profile: a name, a compression method, then the compressed
    /// profile.
    func parseColorProfile(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard let end = Self.separator(in: payload, from: 0) else {
            throw Diagnostic("malformed", chunk: .iccp)
        }

        let name = Self.slice(payload, 0 ..< end)
        try Self.validateKeyword(name, chunk: .iccp)

        // The separator, then the compression method byte.
        guard payload.count > end + 1 else {
            throw Diagnostic("malformed", chunk: .iccp)
        }

        let method = payload[end + 1]

        guard method == 0 else {
            throw Diagnostic("Unknown compression method", chunk: .iccp)
        }

        let compressed = Self.slice(payload, (end + 2) ..< payload.count)

        // Both allocated before either is recorded, so a failure in the second leaves
        // no half-written profile behind.
        let storedName = try TextStorage.copying(name, host: self.host)
        let profile: EscapingBuffer<UInt8>

        do {
            profile = try self.inflatePayload(compressed, chunk: .iccp)
        } catch {
            storedName.deallocate(host: self.host)
            throw error
        }

        // A profile shorter than its own fixed header cannot be one, whatever it
        // decompressed to, and one describing fewer tags than the fewest a profile may have
        // describes nothing usable.
        //
        // The reference checks a good deal more than this — the signature, the version, the
        // device and connection spaces, the rendering intent, the tag table's bounds — and
        // reports each fault with its own wording. Those checks are not reproduced yet, so
        // a profile that is malformed in one of those ways is accepted here and refused
        // there.
        if profile.count < Self.minimumProfileLength
            || self.profileTagCount(profile) < Self.minimumProfileTags {
            storedName.deallocate(host: self.host)
            profile.deallocate(host: self.host)
            throw Diagnostic("too short", chunk: .iccp)
        }

        self.profileName.deallocate(host: self.host)
        self.profile.deallocate(host: self.host)

        self.profileName = storedName
        self.profile = profile
        self.profileCompression = method
        self.markValid(Valid.iccp)
    }

    /// How many tags a profile says it carries, read from the field after its header.
    private func profileTagCount(_ profile: EscapingBuffer<UInt8>) -> Int {
        guard profile.count >= Self.minimumProfileLength else { return 0 }

        let bytes = profile.elements

        return Int(bytes[128]) << 24 | Int(bytes[129]) << 16
            | Int(bytes[130]) << 8 | Int(bytes[131])
    }

    /// The physical scale, as two decimal strings.
    ///
    /// Stored as text because the format allows a precision no fixed binary type holds,
    /// and a client can ask for the strings verbatim.
    func parseScale(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard payload.count > 2 else {
            throw Diagnostic("invalid", chunk: .scal)
        }

        let unit = payload[0]

        guard unit == 1 || unit == 2 else {
            throw Diagnostic("invalid unit", chunk: .scal)
        }

        guard let end = Self.separator(in: payload, from: 1) else {
            throw Diagnostic("malformed", chunk: .scal)
        }

        let width = Self.slice(payload, 1 ..< end)
        let height = Self.slice(payload, (end + 1) ..< payload.count)

        guard width.count > 0, height.count > 0 else {
            throw Diagnostic("invalid", chunk: .scal)
        }

        let storedWidth = try TextStorage.copying(width, host: self.host)
        let storedHeight: TextStorage

        do {
            storedHeight = try TextStorage.copying(height, host: self.host)
        } catch {
            storedWidth.deallocate(host: self.host)
            throw error
        }

        self.scale.width.deallocate(host: self.host)
        self.scale.height.deallocate(host: self.host)

        self.scale.unit = unit
        self.scale.width = storedWidth
        self.scale.height = storedHeight
        self.markValid(Valid.scal)
    }

    /// Decompresses a chunk payload into memory from the client's allocator.
    ///
    /// The size is not known ahead of time, so this decompresses in steps into a growing
    /// buffer, stopping at the cap.
    func inflatePayload(
        _ compressed: UnsafeBufferPointer<UInt8>,
        chunk: ChunkName
    ) throws -> EscapingBuffer<UInt8> {
        let stream = try InflateStream()
        defer { stream.release() }

        // The input is not copied, and the stream is finished with before this returns,
        // so addressing the caller's payload directly is safe here.
        let input = UnsafeMutableBufferPointer(
            start: UnsafeMutablePointer(mutating: compressed.baseAddress),
            count: compressed.count
        )
        stream.setInput(input)

        // Grown by doubling from a guess proportional to the input, since a chunk's
        // compression ratio is usually modest and a resize costs a copy.
        var capacity = max(64, compressed.count * 4)
        var produced = 0
        var buffer = try RawBuffer.allocate(capacity, host: self.host)

        // Everything from here to the handover is wrapped, because everything in it can fail and
        // all of it is holding the same buffer.  Growing takes a second allocation, the decompressor
        // can refuse the data, and the handover takes an allocation of its own — and each of those
        // used to lose whatever had been decompressed so far.
        do {
            while true {
                let made = try stream.inflate(
                    into: buffer.bytes.baseAddress! + produced,
                    count: capacity - produced
                )
                produced += made

                if stream.isFinished { break }

                if produced == capacity {
                    guard capacity < Self.chunkMallocMax else {
                        throw Diagnostic("Read Error", chunk: chunk)
                    }

                    let larger = min(capacity * 2, Self.chunkMallocMax)
                    let grown = try RawBuffer.allocate(larger, host: self.host)

                    grown.bytes.baseAddress!.update(
                        from: buffer.bytes.baseAddress!,
                        count: produced
                    )
                    buffer.deallocate(host: self.host)

                    buffer = grown
                    capacity = larger
                    continue
                }

                if made == 0 {
                    // No progress, no more input, and no end marker: the stream is short.
                    throw Diagnostic("Truncated compressed data", chunk: chunk)
                }
            }

            // Handed over at exactly its length, because the accessor reports that length and
            // a client may read every byte of it.
            let result = try EscapingBuffer<UInt8>.allocated(produced, host: self.host)

            if produced > 0 {
                result.elements.baseAddress!.update(
                    from: buffer.bytes.baseAddress!,
                    count: produced
                )
            }

            buffer.deallocate(host: self.host)

            return result
        } catch {
            buffer.deallocate(host: self.host)
            throw error
        }
    }
}
