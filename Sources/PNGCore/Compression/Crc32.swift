// Crc32.swift - the checksum that follows every chunk
//
// Computed incrementally, because a chunk's data is not necessarily held in one
// piece: an IDAT is consumed in whatever sized bites the decompressor asks for,
// and the checksum has to accumulate across them.

/// The CRC-32 that PNG appends to each chunk, over its type code and payload.
struct Crc32 {
    /// The reversed polynomial the format specifies, matching what zlib uses.
    private static let polynomial: UInt32 = 0xEDB8_8320

    /// One entry per possible byte, so the checksum advances a byte at a time
    /// instead of a bit at a time.
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)

        for index in 0 ..< 256 {
            var value = UInt32(index)

            for _ in 0 ..< 8 {
                value = value & 1 != 0
                    ? Self.polynomial ^ (value >> 1)
                    : value >> 1
            }

            table[index] = value
        }

        return table
    }()

    private var state: UInt32 = 0xFFFF_FFFF

    init() {}

    mutating func reset() {
        self.state = 0xFFFF_FFFF
    }

    mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
        var state = self.state

        for byte in bytes {
            state = Self.table[Int((state ^ UInt32(byte)) & 0xFF)] ^ (state >> 8)
        }

        self.state = state
    }

    mutating func update(_ byte: UInt8) {
        self.state = Self.table[Int((self.state ^ UInt32(byte)) & 0xFF)]
            ^ (self.state >> 8)
    }

    /// The checksum as it appears in the file.
    var checksum: UInt32 {
        self.state ^ 0xFFFF_FFFF
    }
}
