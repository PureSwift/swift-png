// Crc32.swift - the checksum that follows every chunk
//
// Computed incrementally, because a chunk's data is not necessarily held in one
// piece: an IDAT is consumed in whatever sized bites the decompressor asks for,
// and the checksum has to accumulate across them.
//
// This is a real cost, not bookkeeping: the checksum covers every payload byte of
// the file, so on a large image it runs over more data than any transform does.
// The build that links the system zlib hands the buffer to its `crc32`, which is
// what the reference itself does and is hardware-assisted where the platform has
// it.  The dependency-free build keeps its own implementation, eight bytes per
// step through a sliced table rather than one, since a byte-at-a-time loop was
// once the single largest line in a whole decode's profile.

#if SystemZlib
import CZlib
#endif

/// The CRC-32 that PNG appends to each chunk, over its type code and payload.
struct Crc32 {
    /// The reversed polynomial the format specifies, matching what zlib uses.
    private static let polynomial: UInt32 = 0xEDB8_8320

    #if !SystemZlib
    /// Eight tables of 256 entries, flattened: table `n` advances a byte that is
    /// `n` positions deep in the eight-byte block being consumed at once.  The
    /// first 256 entries are the ordinary byte-at-a-time table, which is also
    /// what the single-byte update reads.
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256 * 8)

        for index in 0 ..< 256 {
            var value = UInt32(index)

            for _ in 0 ..< 8 {
                value = value & 1 != 0
                    ? Self.polynomial ^ (value >> 1)
                    : value >> 1
            }

            table[index] = value
        }

        for index in 0 ..< 256 {
            var value = table[index]

            for slice in 1 ..< 8 {
                value = table[Int(value & 0xFF)] ^ (value >> 8)
                table[slice * 256 + index] = value
            }
        }

        return table
    }()
    #endif

    private var state: UInt32 = 0xFFFF_FFFF

    init() {}

    mutating func reset() {
        self.state = 0xFFFF_FFFF
    }

    mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }

        #if SystemZlib
        // zlib's `crc32` speaks in the finished value — pre- and post-conditioned —
        // while the running state here is the raw register, so the two invert at
        // the boundary in each direction.
        self.state = ~UInt32(truncatingIfNeeded: crc32(
            uLong(~self.state),
            base,
            uInt(bytes.count)
        ))
        #else
        var state = self.state

        Self.table.withUnsafeBufferPointer { table in
            var offset = 0
            let count = bytes.count

            // Eight bytes per step: fold the low word into the state, then take
            // both words through the eight tables at their depths.  The tables
            // are built so the eight lookups compose to exactly the eight
            // byte-at-a-time steps they replace.
            while offset + 8 <= count {
                var low = UInt32(base[offset])
                low |= UInt32(base[offset + 1]) << 8
                low |= UInt32(base[offset + 2]) << 16
                low |= UInt32(base[offset + 3]) << 24

                var high = UInt32(base[offset + 4])
                high |= UInt32(base[offset + 5]) << 8
                high |= UInt32(base[offset + 6]) << 16
                high |= UInt32(base[offset + 7]) << 24

                let folded = state ^ low

                // One statement per lookup, deliberately: the single folded
                // expression this once was is exactly the shape that makes a
                // type-checker give up, and the accumulation optimizes the same.
                var next = table[7 * 256 + Int(folded & 0xFF)]
                next ^= table[6 * 256 + Int((folded >> 8) & 0xFF)]
                next ^= table[5 * 256 + Int((folded >> 16) & 0xFF)]
                next ^= table[4 * 256 + Int(folded >> 24)]
                next ^= table[3 * 256 + Int(high & 0xFF)]
                next ^= table[2 * 256 + Int((high >> 8) & 0xFF)]
                next ^= table[1 * 256 + Int((high >> 16) & 0xFF)]
                next ^= table[Int(high >> 24)]

                state = next
                offset += 8
            }

            while offset < count {
                state = table[Int((state ^ UInt32(base[offset])) & 0xFF)] ^ (state >> 8)
                offset += 1
            }
        }

        self.state = state
        #endif
    }

    mutating func update(_ byte: UInt8) {
        #if SystemZlib
        withUnsafePointer(to: byte) {
            self.state = ~UInt32(truncatingIfNeeded: crc32(uLong(~self.state), $0, 1))
        }
        #else
        self.state = Self.table[Int((self.state ^ UInt32(byte)) & 0xFF)]
            ^ (self.state >> 8)
        #endif
    }

    /// The checksum as it appears in the file.
    var checksum: UInt32 {
        self.state ^ 0xFFFF_FFFF
    }
}
