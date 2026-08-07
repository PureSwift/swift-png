// ChunkLexer.swift - reading the stream's chunk framing
//
// A PNG is a signature followed by chunks, each a length, a type code, that many
// bytes of payload, and a checksum over the type and payload.  This walks that
// structure, pulling bytes through the caller's read callback.
//
// The image data is handled differently from every other chunk.  Other payloads
// are small and are buffered whole so a parser can work over them; IDAT payloads
// are the bulk of the file and are streamed straight into the decompressor, so the
// lexer exposes the current chunk's remaining length and lets the reader draw from
// it.

struct ChunkHeader {
    let name: ChunkName
    let length: Int
}

/// Walks the chunk structure of a stream.
///
/// Holds no buffers of its own; payload storage belongs to the context, since it
/// has to survive a client jump out of the read callback.
///
/// A class rather than a struct, and deliberately.  Held as a struct property it
/// would be mutated through `mutating` methods, each of which takes an exclusive
/// access to that property for the whole call — including the part that runs the
/// client's read callback.  A client jumping out of that callback would leave the
/// access open for ever, and the next touch of the property would trap.  As a class
/// every field update is its own short access, with no client code inside it.
final class ChunkLexer {
    static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    /// The checksum of the chunk being read, covering its type code and whatever
    /// payload bytes have been consumed so far.
    private var crc = Crc32()

    /// How many payload bytes of the current chunk are still unread.
    private(set) var remainingInChunk = 0

    private(set) var current: ChunkHeader?

    /// Reads and validates the signature, allowing for bytes a client already
    /// consumed and declared with `png_set_sig_bytes`.
    ///
    /// The bytes land in a tuple on the stack rather than an array, because the
    /// read runs the client's callback and a client may jump out of it; an array
    /// would be abandoned still holding its storage.
    static func readSignature(host: Host, alreadyConsumed: Int) throws(Diagnostic) {
        guard alreadyConsumed < Self.signature.count else {
            // The client says it has read the whole signature and checked it.
            return
        }

        let count = Self.signature.count - alreadyConsumed
        var raw = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))

        let matched = withUnsafeMutableBytes(of: &raw) { bytes -> Bool in
            let base = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            host.readExactly(into: base, count: count)

            for index in 0 ..< count
            where base[index] != Self.signature[alreadyConsumed + index] {
                return false
            }

            return true
        }

        guard matched else {
            throw Diagnostic("Not a PNG file")
        }
    }

    /// Reads the next chunk's length and type.
    func readHeader(host: Host, context: PngContext? = nil) throws(Diagnostic) -> ChunkHeader {
        context?.noteIO(0x0020)

        var raw = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))

        withUnsafeMutableBytes(of: &raw) { bytes in
            host.readExactly(
                into: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                count: 8
            )
        }

        let length = UInt32(raw.0) << 24 | UInt32(raw.1) << 16
            | UInt32(raw.2) << 8 | UInt32(raw.3)

        // The format caps a chunk length at 31 bits.  A stream claiming more is
        // either damaged or hostile, and either way the length cannot be honoured.
        guard length & 0x8000_0000 == 0 else {
            throw Diagnostic("chunk length is out of range")
        }

        let name = ChunkName(raw.4, raw.5, raw.6, raw.7)

        // A chunk's type is four letters, and the format says so: the case of each one carries a
        // meaning — whether the chunk may be ignored, whether it is registered, whether it may be
        // copied — and a byte that is not a letter has no case to carry any of that.  So this is not
        // an unknown chunk to be skipped; it is a stream that has stopped making sense.
        guard name.isWellFormed else {
            throw Diagnostic("bad header (invalid type)", chunk: name)
        }

        // Past the header and into the contents, which is where a client watching from its own
        // callback will see the library while a chunk is being consumed.
        context?.noteIO(0x0040, chunk: name)

        // The checksum covers the type code as well as the payload.  All four bytes in one call:
        // the checksum may be the platform's own, where a call per byte is four function calls
        // and four times the setup for four bytes of work — and a file whose image data is split
        // across many chunks pays that on every one of them.
        self.crc.reset()

        withUnsafeBytes(of: &raw) {
            self.crc.update(
                UnsafeBufferPointer(
                    start: $0.baseAddress!.advanced(by: 4).assumingMemoryBound(to: UInt8.self),
                    count: 4
                )
            )
        }

        let header = ChunkHeader(name: name, length: Int(length))
        self.current = header
        self.remainingInChunk = Int(length)

        return header
    }

    /// Reads up to `count` payload bytes of the current chunk into `destination`,
    /// returning how many were read.
    ///
    /// Used for the image data, which is consumed in whatever sized pieces the
    /// decompressor asks for rather than buffered whole.
    func readPayload(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int,
        host: Host
    ) -> Int {
        let wanted = min(count, self.remainingInChunk)
        guard wanted > 0 else { return 0 }

        host.readExactly(into: destination, count: wanted)

        self.crc.update(UnsafeBufferPointer(start: destination, count: wanted))
        self.remainingInChunk -= wanted

        return wanted
    }

    /// Reads the whole remaining payload of the current chunk into `buffer`.
    ///
    /// The buffer must already be large enough; it belongs to the context so that
    /// it survives a jump out of the read callback.
    func readWholePayload(
        into buffer: UnsafeMutableBufferPointer<UInt8>,
        host: Host
    ) throws(Diagnostic) {
        let count = self.remainingInChunk
        guard count > 0 else { return }

        guard buffer.count >= count, let base = buffer.baseAddress else {
            throw Diagnostic("chunk payload buffer is too small")
        }

        let read = self.readPayload(into: base, count: count, host: host)

        guard read == count else {
            throw Diagnostic("chunk is truncated")
        }
    }

    /// Skips whatever is left of the current chunk's payload, still checksumming
    /// it so that the trailing check is meaningful.
    func skipPayload(host: Host, scratch: UnsafeMutableBufferPointer<UInt8>) {
        guard let base = scratch.baseAddress else { return }

        while self.remainingInChunk > 0 {
            _ = self.readPayload(into: base, count: scratch.count, host: host)
        }
    }

    /// Reads the trailing checksum and compares it with what was computed.
    ///
    /// Returns whether it matched, rather than throwing, because what to do about
    /// a mismatch is the client's choice to make through `png_set_crc_action`.
    func readAndCheckCrc(host: Host, context: PngContext? = nil) -> Bool {
        context?.noteIO(0x0080)

        var raw = (UInt8(0), UInt8(0), UInt8(0), UInt8(0))

        withUnsafeMutableBytes(of: &raw) { bytes in
            host.readExactly(
                into: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                count: 4
            )
        }

        let stored = UInt32(raw.0) << 24 | UInt32(raw.1) << 16
            | UInt32(raw.2) << 8 | UInt32(raw.3)

        return stored == self.crc.checksum
    }
}
