import Testing

@testable import LZ77

/// The decompressor is checked against streams whose compressed form is written out here by
/// hand or produced by a known-good compressor, rather than by this module's own compressor:
/// a codec compared only against itself agrees with itself and with nothing else, which is the
/// one failure a round-trip test cannot see.
@Suite("Inflate")
struct InflateTests {
    /// Runs a whole stream through in one go, with a generous output buffer.
    static func inflate(
        _ compressed: [UInt8],
        into capacity: Int = 65536,
        feeding chunkSize: Int = Int.max
    ) throws -> [UInt8] {
        let stream = Inflate()
        var output = [UInt8](repeating: 0, count: capacity)
        var produced = 0
        var offset = 0

        var input = compressed

        try input.withUnsafeMutableBufferPointer { buffer in
            while true {
                if stream.needsInput, offset < buffer.count {
                    let size = min(chunkSize, buffer.count - offset)
                    stream.setInput(
                        UnsafeBufferPointer(start: buffer.baseAddress! + offset, count: size)
                    )
                    offset += size
                }

                let made = try output.withUnsafeMutableBufferPointer { out in
                    try stream.inflate(
                        into: out.baseAddress! + produced,
                        count: out.count - produced
                    )
                }

                produced += made

                if stream.isFinished { break }

                // No progress and nothing left to give it: the stream is truncated rather than
                // merely hungry, and looping again would spin.
                if made == 0, offset >= buffer.count, stream.needsInput {
                    break
                }

                if made == 0, !stream.needsInput, offset >= buffer.count {
                    break
                }
            }
        }

        return Array(output[0 ..< produced])
    }

    /// A stored (uncompressed) block: the simplest stream the format defines, so a failure here
    /// is in the framing rather than in any coding.
    @Test("A stored block round-trips")
    func storedBlock() throws {
        let payload: [UInt8] = Array("hello, world".utf8)

        var stream: [UInt8] = [0x78, 0x01]
        stream.append(0x01) // BFINAL 1, BTYPE 00
        stream.append(UInt8(payload.count & 0xFF))
        stream.append(UInt8((payload.count >> 8) & 0xFF))
        stream.append(UInt8(~payload.count & 0xFF))
        stream.append(UInt8((~payload.count >> 8) & 0xFF))
        stream.append(contentsOf: payload)

        var checksum = Adler32()
        payload.withUnsafeBufferPointer { checksum.update($0) }
        let value = checksum.value
        stream.append(UInt8(truncatingIfNeeded: value >> 24))
        stream.append(UInt8(truncatingIfNeeded: value >> 16))
        stream.append(UInt8(truncatingIfNeeded: value >> 8))
        stream.append(UInt8(truncatingIfNeeded: value))

        #expect(try Self.inflate(stream) == payload)
    }

    /// Produced by zlib at level 6: "aaaaaaaaaaaaaaaaaaaa" (twenty a's), which exercises a
    /// fixed-Huffman block with one literal and one long match back into it.
    @Test("A fixed-Huffman block with a match")
    func fixedHuffmanMatch() throws {
        let compressed: [UInt8] = [
            0x78, 0x9c, 0x4b, 0x4c, 0xc4, 0x04, 0x00, 0x4f, 0xa6, 0x07, 0x95,
        ]

        #expect(try Self.inflate(compressed) == [UInt8](repeating: UInt8(ascii: "a"), count: 20))
    }

    /// The same stream fed one byte at a time. Every resumption point in the decoder is on the
    /// path here — mid-header, mid-symbol, mid-extra-bits, mid-match — and the result has to be
    /// identical to feeding it whole.
    @Test("Feeding one byte at a time gives the same answer")
    func bytewiseFeeding() throws {
        let compressed: [UInt8] = [
            0x78, 0x9c, 0x4b, 0x4c, 0xc4, 0x04, 0x00, 0x4f, 0xa6, 0x07, 0x95,
        ]

        let whole = try Self.inflate(compressed)
        let piecemeal = try Self.inflate(compressed, feeding: 1)

        #expect(whole == piecemeal)
        #expect(piecemeal == [UInt8](repeating: UInt8(ascii: "a"), count: 20))
    }

    /// A dynamic-Huffman block, which is what zlib emits for anything with structure worth a
    /// custom table. Produced by zlib at level 9 for the text below.
    @Test("A dynamic-Huffman block")
    func dynamicHuffman() throws {
        let text = "the quick brown fox jumps over the lazy dog, the quick brown fox"
        let compressed: [UInt8] = [
            0x78, 0xda, 0x2b, 0xc9, 0x48, 0x55, 0x28, 0x2c, 0xcd, 0x4c, 0xce, 0x56, 0x48,
            0x2a, 0xca, 0x2f, 0xcf, 0x53, 0x48, 0xcb, 0xaf, 0x50, 0xc8, 0x2a, 0xcd, 0x2d,
            0x28, 0x56, 0xc8, 0x2f, 0x4b, 0x2d, 0x52, 0x28, 0x01, 0x4a, 0xe7, 0x24, 0x56,
            0x55, 0x2a, 0xa4, 0xe4, 0xa7, 0xeb, 0x80, 0x79, 0x68, 0x8a, 0x01, 0xfe, 0x64,
            0x17, 0x79,
        ]

        let produced = try Self.inflate(compressed)
        #expect(produced == Array(text.utf8))
    }

    /// A checksum that does not match has to be reported rather than passed off as a good
    /// decode: the bytes may be right, but nothing downstream can tell that from here.
    @Test("A bad checksum is refused")
    func badChecksum() throws {
        var compressed: [UInt8] = [
            0x78, 0x9c, 0x4b, 0x4c, 0xc4, 0x04, 0x00, 0x4f, 0xa6, 0x07, 0x95,
        ]
        compressed[compressed.count - 1] ^= 0xFF

        #expect(throws: DeflateError.self) {
            _ = try Self.inflate(compressed)
        }
    }

    @Test("A bad zlib header is refused")
    func badHeader() throws {
        let compressed: [UInt8] = [0x00, 0x00, 0x03, 0x00]

        #expect(throws: DeflateError.self) {
            _ = try Self.inflate(compressed)
        }
    }
}
