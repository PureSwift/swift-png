// main.swift - proof that the embedded WASM build is correct, not only that it links
//
// The `wasm-embedded` CI job compiles PNG for wasm32-unknown-wasip1 under Embedded Swift,
// which catches every restriction that target imposes — but a clean compile says nothing about
// whether the result actually produces the right bytes. This is the WASM counterpart to
// Firmware/QEMU and Firmware/Hypervisor: the same encode-then-decode round trip, run for real.
//
// It needs neither of those two's custom allocator or boot sequence. WASI is a hosted target —
// unlike a bare Cortex-M or a freestanding Mach-O image, `wasm32-unknown-wasip1` has a real
// sysroot behind it, so `WASILibc` is importable even under `-enable-experimental-feature
// Embedded` and supplies real `malloc`/`free` directly. There is nothing here that would not
// also compile as an ordinary (non-embedded) executable; what makes this a check on Embedded
// Swift specifically is that it is *built* with that flag, against the same PNG object code
// the CI job already produces.

import PNG

#if canImport(WASILibc)
import WASILibc
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// -- the host --------------------------------------------------------------

final class Spool {
    var bytes: [UInt8] = []
    var offset = 0
}

func makeHost(_ spool: Spool) -> Host {
    Host(
        owner: Unmanaged.passUnretained(spool).toOpaque(),
        allocate: { _, size in malloc(Int(size)) },
        deallocate: { _, memory in free(memory) },
        read: { owner, destination, count in
            let spool = Unmanaged<Spool>.fromOpaque(owner!).takeUnretainedValue()

            guard spool.offset + Int(count) <= spool.bytes.count else {
                fatalError("read past the end of the spool")
            }

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

// -- the round trip ----------------------------------------------------------

func roundTrip() -> Bool {
    let width = 48
    let height = 48

    let spool = Spool()
    let host = makeHost(spool)

    let writer = PngContext(host: host, isReading: false)
    let writeInfo = InfoStore(host: host)
    defer {
        writeInfo.release()
        writer.release()
    }

    var expected: [[UInt8]] = []

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

            expected.append(row)
            try row.withUnsafeMutableBufferPointer { (buffer) throws(Diagnostic) in
                try writer.writeRow(buffer.baseAddress)
            }
        }

        try writer.writeEnd(writeInfo)
    } catch {
        return false
    }

    let reader = PngContext(host: host, isReading: true)
    let readInfo = InfoStore(host: host)
    defer {
        readInfo.release()
        reader.release()
    }

    spool.offset = 0

    do throws(Diagnostic) {
        try reader.readInfo(into: readInfo)
        try reader.updateInfoForClient(readInfo)

        var buffer = [UInt8](repeating: 0, count: readInfo.rowBytes)

        for y in 0 ..< height {
            try buffer.withUnsafeMutableBufferPointer { (rowBuffer) throws(Diagnostic) in
                try reader.readRow(into: rowBuffer.baseAddress)
            }

            if buffer != expected[y] {
                return false
            }
        }

        try reader.readEnd(into: nil)
    } catch {
        return false
    }

    return true
}

// A trap (WASM `unreachable`) rather than a plain nonzero return: `wasmtime`'s own exit code for
// a trap is unambiguous, where a bare `exit(1)` call would need WASILibc's process-exit path to
// also be trustworthy under Embedded — one fewer thing this test depends on to report correctly.
if !roundTrip() {
    fatalError("round trip failed")
}
