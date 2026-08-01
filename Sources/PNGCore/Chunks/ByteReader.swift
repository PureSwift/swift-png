// ByteReader.swift - bounds-checked big-endian reads over a chunk payload
//
// Chunk payloads arrive from a file, so their length is never something to trust.
// Every read here is checked, and a read past the end throws rather than
// returning a value assembled from whatever followed in memory.

/// A cursor over a chunk payload.
struct ByteReader {
    private let bytes: UnsafeBufferPointer<UInt8>
    private(set) var offset: Int

    init(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
        self.offset = 0
    }

    var remaining: Int { self.bytes.count - self.offset }
    var isAtEnd: Bool { self.remaining == 0 }

    private mutating func take(_ count: Int) throws(Diagnostic) -> Int {
        guard self.remaining >= count else {
            throw Diagnostic("chunk is truncated")
        }
        let start = self.offset
        self.offset += count
        return start
    }

    mutating func readUInt8() throws(Diagnostic) -> UInt8 {
        self.bytes[try self.take(1)]
    }

    mutating func readUInt16() throws(Diagnostic) -> UInt16 {
        let start = try self.take(2)
        return UInt16(self.bytes[start]) << 8 | UInt16(self.bytes[start + 1])
    }

    /// Reads a 32-bit big-endian value.
    ///
    /// PNG uses these for lengths and dimensions, where the specification requires
    /// the top bit to be clear; callers that need that guarantee use
    /// ``readUInt31()`` instead.
    mutating func readUInt32() throws(Diagnostic) -> UInt32 {
        let start = try self.take(4)
        return UInt32(self.bytes[start]) << 24
            | UInt32(self.bytes[start + 1]) << 16
            | UInt32(self.bytes[start + 2]) << 8
            | UInt32(self.bytes[start + 3])
    }

    /// Reads a 32-bit value the format requires to fit in 31 bits.
    mutating func readUInt31() throws(Diagnostic) -> UInt32 {
        let value = try self.readUInt32()

        guard value & 0x8000_0000 == 0 else {
            throw Diagnostic("PNG unsigned integer out of range")
        }

        return value
    }

    mutating func readBytes(_ count: Int) throws(Diagnostic) -> UnsafeBufferPointer<UInt8> {
        let start = try self.take(count)
        return UnsafeBufferPointer(rebasing: self.bytes[start ..< start + count])
    }
}
