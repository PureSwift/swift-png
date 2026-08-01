// App.swift - the thing this whole harness exists to run
//
// Encodes a small synthetic image with PNGCore's own writer, decodes it back with its own
// reader, and checks the round trip pixel for pixel — the same shape as
// Tests/PNGCoreTests/RoundTripTests.swift, run here as compiled ARM object code under an
// emulator instead of as a host-native test. Neither the C API boundary nor the system zlib
// trait is reachable on this target, so what runs is exactly what a client embedding PNGCore
// directly, with the pure-Swift LZ77 module, would run.
//
// The `@_silgen_name` declarations below are how a freestanding Swift file built with a bare
// `swiftc` invocation — no SwiftPM target, no bridging header — names C symbols it expects to
// find at link time; `shim.c` is where each of them is actually defined.

import PNGCore

@_silgen_name("bump_malloc") func c_malloc(_ size: Int) -> UnsafeMutableRawPointer?
@_silgen_name("bump_free") func c_free(_ ptr: UnsafeMutableRawPointer?)
@_silgen_name("write0") func c_write0(_ s: UnsafePointer<CChar>?)
@_silgen_name("write_uint") func c_write_uint(_ v: UInt32)
@_silgen_name("dwt_cycles") func c_cycles() -> UInt32

func log(_ s: StaticString) {
    s.withUTF8Buffer { buffer in
        var bytes = [UInt8](buffer)
        bytes.append(0)
        bytes.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: p.count) { c_write0($0) }
        }
    }
}

final class Spool {
    var bytes: [UInt8] = []
    var offset = 0
}

func makeHost(_ spool: Spool) -> Host {
    Host(
        owner: Unmanaged.passUnretained(spool).toOpaque(),
        allocate: { _, size in c_malloc(Int(size)) },
        deallocate: { _, memory in c_free(memory) },
        read: { owner, destination, count in
            let spool = Unmanaged<Spool>.fromOpaque(owner!).takeUnretainedValue()
            guard spool.offset + Int(count) <= spool.bytes.count else { return }
            spool.bytes.withUnsafeBufferPointer { buffer in
                destination?.update(from: buffer.baseAddress! + spool.offset, count: Int(count))
            }
            spool.offset += Int(count)
        },
        warn: { _, _, _ in },
        warnChunk: { _, _, _, _ in },
        writeBytes: { owner, data, count in
            let spool = Unmanaged<Spool>.fromOpaque(owner!).takeUnretainedValue()
            guard let data else { return }
            spool.bytes.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(count)))
        },
        flushBytes: { _ in }
    )
}

@_cdecl("swift_main")
public func swift_main() -> Int32 {
    let width = 48
    let height = 48

    let spool = Spool()
    let host = makeHost(spool)

    log("encoding...\n")
    let encodeStart = c_cycles()

    let writer = PngContext(host: host, isReading: false)
    let writeInfo = InfoStore(host: host)

    do throws(Diagnostic) {
        try writer.writeHeader(
            Header.Fields(
                width: UInt32(width), height: UInt32(height), bitDepth: 8, colorType: 2,
                compressionMethod: 0, filterMethod: 0, interlaceMethod: 0
            )
        )
        try writer.writePalette(writeInfo)

        for y in 0 ..< height {
            var row = [UInt8]()
            for x in 0 ..< width {
                row.append(UInt8(truncatingIfNeeded: x * 5))
                row.append(UInt8(truncatingIfNeeded: y * 5))
                row.append(UInt8(truncatingIfNeeded: (x ^ y) * 5))
            }
            try row.withUnsafeMutableBufferPointer { (buffer) throws(Diagnostic) in try writer.writeRow(buffer.baseAddress) }
        }

        try writer.writeEnd(writeInfo)
    } catch {
        log("encode failed\n")
        return 1
    }

    let encodeCycles = c_cycles() &- encodeStart
    writeInfo.release()
    writer.release()

    log("wrote bytes: ")
    c_write_uint(UInt32(spool.bytes.count))
    log("\n")
    log("encode cycles: ")
    c_write_uint(encodeCycles)
    log("\n")

    log("decoding...\n")
    spool.offset = 0
    let decodeStart = c_cycles()

    let reader = PngContext(host: host, isReading: true)
    let readInfo = InfoStore(host: host)
    var ok = true

    do throws(Diagnostic) {
        try reader.readInfo(into: readInfo)
        try reader.updateInfoForClient(readInfo)

        var buffer = [UInt8](repeating: 0, count: readInfo.rowBytes)

        for y in 0 ..< height {
            try buffer.withUnsafeMutableBufferPointer { (rowBuffer) throws(Diagnostic) in try reader.readRow(into: rowBuffer.baseAddress) }

            for x in 0 ..< width {
                let expected: [UInt8] = [
                    UInt8(truncatingIfNeeded: x * 5),
                    UInt8(truncatingIfNeeded: y * 5),
                    UInt8(truncatingIfNeeded: (x ^ y) * 5),
                ]
                if buffer[x * 3] != expected[0] || buffer[x * 3 + 1] != expected[1]
                    || buffer[x * 3 + 2] != expected[2] {
                    ok = false
                }
            }
        }

        try reader.readEnd(into: nil)
    } catch {
        log("decode failed\n")
        return 2
    }

    let decodeCycles = c_cycles() &- decodeStart
    readInfo.release()
    reader.release()

    log("decode cycles: ")
    c_write_uint(decodeCycles)
    log("\n")

    if ok {
        log("round trip OK\n")
        return 0
    } else {
        log("round trip MISMATCH\n")
        return 3
    }
}
