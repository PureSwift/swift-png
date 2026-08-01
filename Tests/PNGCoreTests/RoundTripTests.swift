import Testing

@testable import PNGCore

/// A whole file written and read back through the engine, with no C API and no file system:
/// bytes go out through a host callback into an array and come back in the same way.
///
/// This is the one test whose meaning changes with the build: with the system zlib trait it
/// exercises the seam, and without it the compression is this package's own — so the same suite
/// passing in both configurations is what says the two backends are interchangeable.
@Suite("Whole-file round trip")
struct RoundTripTests {
    /// The in-memory file the host callbacks read and write.
    final class Spool {
        var bytes: [UInt8] = []
        var offset = 0
        var failed = false
    }

    static func makeHost(_ spool: Spool) -> Host {
        Host(
            owner: Unmanaged.passUnretained(spool).toOpaque(),
            allocate: { _, size in
                UnsafeMutableRawPointer.allocate(
                    byteCount: Int(size),
                    alignment: MemoryLayout<UInt64>.alignment
                )
            },
            deallocate: { _, memory in memory?.deallocate() },
            read: { owner, destination, count in
                let spool = Unmanaged<Spool>.fromOpaque(owner!).takeUnretainedValue()

                guard spool.offset + Int(count) <= spool.bytes.count else {
                    // A short read may not return; marking and padding keeps the engine moving
                    // toward its own "truncated" diagnostic, which the test then reports.
                    spool.failed = true
                    destination?.update(repeating: 0, count: Int(count))
                    return
                }

                spool.bytes.withUnsafeBufferPointer { buffer in
                    destination?.update(
                        from: buffer.baseAddress! + spool.offset,
                        count: Int(count)
                    )
                }
                spool.offset += Int(count)
            },
            warn: { _, _, _ in },
            warnChunk: { _, _, _, _ in },
            writeBytes: { owner, data, count in
                let spool = Unmanaged<Spool>.fromOpaque(owner!).takeUnretainedValue()

                guard let data else { return }

                spool.bytes.append(
                    contentsOf: UnsafeBufferPointer(start: data, count: Int(count))
                )
            },
            flushBytes: { _ in }
        )
    }

    /// Writes `rows` as an eight-bit RGB image and reads it back, returning the decoded rows.
    static func roundTrip(width: Int, height: Int, rows: [[UInt8]]) throws -> [[UInt8]] {
        let spool = Spool()
        let writeHost = Self.makeHost(spool)
        let writer = PngContext(host: writeHost, isReading: false)
        let writeInfo = InfoStore(host: writeHost)
        defer {
            writeInfo.release()
            writer.release()
        }

        try writer.writeHeader(
            Header.Fields(
                width: UInt32(width),
                height: UInt32(height),
                bitDepth: 8,
                colorType: 2,
                compressionMethod: 0,
                filterMethod: 0,
                interlaceMethod: 0
            )
        )
        try writer.writePalette(writeInfo)

        for row in rows {
            var row = row
            try row.withUnsafeMutableBufferPointer { buffer in
                try writer.writeRow(buffer.baseAddress)
            }
        }

        try writer.writeEnd(writeInfo)

        let readHost = Self.makeHost(spool)
        let reader = PngContext(host: readHost, isReading: true)
        let readInfo = InfoStore(host: readHost)
        defer {
            readInfo.release()
            reader.release()
        }

        spool.offset = 0
        try reader.readInfo(into: readInfo)
        try reader.updateInfoForClient(readInfo)

        var decoded: [[UInt8]] = []
        var buffer = [UInt8](repeating: 0, count: readInfo.rowBytes)

        for _ in 0 ..< height {
            try buffer.withUnsafeMutableBufferPointer { row in
                try reader.readRow(into: row.baseAddress)
            }
            decoded.append(buffer)
        }

        try reader.readEnd(into: nil)

        #expect(!spool.failed, "the reader ran past the end of what was written")

        return decoded
    }

    @Test("A gradient survives the trip")
    func gradient() throws {
        let width = 97
        let height = 41
        var rows: [[UInt8]] = []

        for y in 0 ..< height {
            var row: [UInt8] = []

            for x in 0 ..< width {
                row.append(UInt8((x + y) & 0xFF))
                row.append(UInt8((x * 3) & 0xFF))
                row.append(UInt8((y * 7) & 0xFF))
            }

            rows.append(row)
        }

        #expect(try Self.roundTrip(width: width, height: height, rows: rows) == rows)
    }

    @Test("Noise survives the trip")
    func noise() throws {
        let width = 64
        let height = 64
        var state: UInt32 = 0x1234_5678
        var rows: [[UInt8]] = []

        for _ in 0 ..< height {
            var row: [UInt8] = []

            for _ in 0 ..< (width * 3) {
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                row.append(UInt8(truncatingIfNeeded: state))
            }

            rows.append(row)
        }

        #expect(try Self.roundTrip(width: width, height: height, rows: rows) == rows)
    }
}
