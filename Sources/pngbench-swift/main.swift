// main.swift - how long the engine takes when driven from Swift
//
// The C benchmark next door times the published API, boundary and all; this one calls PNGCore
// directly, which is what the Swift library will do.  There is no per-row crossing into C and no
// opaque-pointer lookup here, so parity with the reference is not the bar — beating it is.
//
// The shape is pngbench.c's exactly: the file is read into memory first, what is written goes
// nowhere, each case runs many times, and the best time is kept.  Same cases, same transform
// tokens, same output line, so the two can be run over the same images and read side by side.
//
// usage: pngbench-swift <file.png> [rounds] [transform,transform,...]

import Foundation
import PNGCore

// -- the host ----------------------------------------------------------------
//
// The engine reaches its caller through C function pointers, which cannot capture, so the state
// they need travels through the owner pointer: the file being read from and a count of bytes
// written.  A short read aborts, which is what a libpng read callback does with the whole process
// standing in for the client's jump target.

final class Console {
    var data: UnsafeMutableBufferPointer<UInt8> = .init(start: nil, count: 0)
    var offset = 0
    var written = 0
}

func makeHost(_ console: Console) -> PNGCore.Host {
    PNGCore.Host(
        owner: Unmanaged.passUnretained(console).toOpaque(),
        allocate: { _, size in malloc(Int(size)) },
        deallocate: { _, memory in free(memory) },
        read: { owner, destination, count in
            let console = Unmanaged<Console>.fromOpaque(owner!).takeUnretainedValue()

            guard console.offset + Int(count) <= console.data.count else {
                fatalError("ran out of file")
            }

            destination!.update(
                from: console.data.baseAddress! + console.offset,
                count: Int(count)
            )
            console.offset += Int(count)
        },
        warn: { _, _, _ in },
        warnChunk: { _, _, _, _ in },
        writeBytes: { owner, _, count in
            Unmanaged<Console>.fromOpaque(owner!).takeUnretainedValue().written += Int(count)
        },
        flushBytes: { _ in }
    )
}

// -- what pngbench.c calls the same things -----------------------------------

struct Want: OptionSet {
    let rawValue: Int

    static let expand = Want(rawValue: 0x01)
    static let gray = Want(rawValue: 0x02)
    static let filler = Want(rawValue: 0x04)
    static let gamma = Want(rawValue: 0x08)
    static let scale16 = Want(rawValue: 0x10)
    static let image = Want(rawValue: 0x20)

    static let all: Want = [.expand, .gray, .filler, .gamma, .scale16]
}

func parseTransforms(_ list: String) -> Want {
    var want: Want = []

    for token in list.split(separator: ",") {
        switch token {
        case "expand": want.insert(.expand)
        case "gray": want.insert(.gray)
        case "filler": want.insert(.filler)
        case "gamma": want.insert(.gamma)
        case "scale16": want.insert(.scale16)
        case "image": want.insert(.image)
        case "all": want.insert(.all)
        case "none": break
        default:
            complain("pngbench-swift: unknown transform '\(token)'\n")
            exit(2)
        }
    }

    return want
}

/// To the error stream by descriptor: Glibc's `stderr` is a mutable global that strict
/// concurrency refuses to touch from top-level code, and the descriptor says the same thing
/// on both platforms.
func complain(_ message: String) {
    var message = message
    _ = message.withUTF8 { buffer in
        write(2, buffer.baseAddress, buffer.count)
    }
}

func now() -> Double {
    var t = timespec()
    clock_gettime(CLOCK_MONOTONIC, &t)
    return Double(t.tv_sec) * 1000.0 + Double(t.tv_nsec) / 1_000_000.0
}

// -- one decode --------------------------------------------------------------

/// Mirrors pngbench.c's `decode`: the requested transforms switched on and the count of rows
/// produced returned.
func decode(_ console: Console, want: Want) throws -> Int {
    let host = makeHost(console)
    let context = PngContext(host: host, isReading: true)
    let info = InfoStore(host: host)
    defer {
        info.release()
        context.release()
    }

    console.offset = 0
    try context.readInfo(into: info)

    guard let header = info.header else { throw Diagnostic("no header") }

    // The same requests png_set_expand, png_set_gray_to_rgb, png_set_add_alpha, png_set_gamma
    // and png_set_scale_16 record, made the way the boundary makes them.
    if want.contains(.expand) {
        context.transformFlags.insert([.expand, .expandTransparency, .expandGrayTo8])
    }

    if want.contains(.gray) {
        context.transformFlags.insert([.grayToRgb, .expand])
    }

    if want.contains(.filler) {
        context.fillerValue = 0xFFFF
        context.fillerAfterColor = true
        context.transformFlags.insert(.addAlpha)
    }

    if want.contains(.gamma) {
        context.gamma.screenGamma = FixedPoint(2.2 * 100_000 + 0.5)
        context.gamma.fileGamma = FixedPoint(0.45455 * 100_000 + 0.5)
        context.transformFlags.insert(.gamma)
    }

    if want.contains(.scale16) {
        context.transformFlags.insert(.scale16)
    }

    var passes = 1

    if header.isInterlaced {
        passes = context.enableInterlaceHandling()
    }

    try context.updateInfoForClient(info)

    let rowBytes = info.rowBytes
    var produced = 0

    if want.contains(.image) {
        // The whole image through one call, mirroring png_read_image.
        let height = header.height
        let block = UnsafeMutablePointer<UInt8>.allocate(capacity: rowBytes * height)
        var pointers: [UnsafeMutablePointer<UInt8>?] = (0 ..< height).map {
            block + $0 * rowBytes
        }
        defer { block.deallocate() }

        try pointers.withUnsafeMutableBufferPointer {
            try context.readImage(rows: $0.baseAddress!)
        }
        produced = height * passes
    } else {
        let row = UnsafeMutablePointer<UInt8>.allocate(capacity: rowBytes)
        defer { row.deallocate() }

        for _ in 0 ..< passes {
            for _ in 0 ..< header.height {
                try context.readRow(into: row)
                produced += 1
            }
        }
    }

    try context.readEnd(into: nil)

    return produced
}

// -- keeping rows for the encode ---------------------------------------------

func keepRows(_ console: Console) throws
    -> (rows: [UnsafeMutableBufferPointer<UInt8>], header: Header)
{
    let host = makeHost(console)
    let context = PngContext(host: host, isReading: true)
    let info = InfoStore(host: host)
    defer {
        info.release()
        context.release()
    }

    console.offset = 0
    try context.readInfo(into: info)

    guard let header = info.header else { throw Diagnostic("no header") }

    var passes = 1

    if header.isInterlaced {
        passes = context.enableInterlaceHandling()
    }

    try context.updateInfoForClient(info)

    let rowBytes = info.rowBytes
    let rows: [UnsafeMutableBufferPointer<UInt8>] = (0 ..< header.height).map { _ in
        let row = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: rowBytes)
        row.initialize(repeating: 0)
        return row
    }

    for _ in 0 ..< passes {
        for row in rows {
            try context.readRow(into: row.baseAddress)
        }
    }

    try context.readEnd(into: nil)

    return (rows, header)
}

// -- one encode --------------------------------------------------------------

func encode(
    _ rows: [UnsafeMutableBufferPointer<UInt8>],
    header: Header
) throws -> Int {
    let console = Console()
    let host = makeHost(console)
    let context = PngContext(host: host, isReading: false)
    let info = InfoStore(host: host)
    defer {
        info.release()
        context.release()
    }

    info.header = Header(
        Header.Fields(
            width: UInt32(header.width),
            height: UInt32(header.height),
            bitDepth: UInt8(header.bitDepth),
            colorType: header.colorType.rawValue,
            compressionMethod: 0,
            filterMethod: 0,
            interlaceMethod: 0
        )
    )

    // The same sequence png_write_info runs.
    try context.writeHeader(
        Header.Fields(
            width: UInt32(header.width),
            height: UInt32(header.height),
            bitDepth: UInt8(header.bitDepth),
            colorType: header.colorType.rawValue,
            compressionMethod: 0,
            filterMethod: 0,
            interlaceMethod: 0
        )
    )
    try context.writePalette(info)

    for row in rows {
        try context.writeRow(row.baseAddress)
    }

    try context.writeEnd(info)

    return console.written
}

// -- main --------------------------------------------------------------------

let arguments = CommandLine.arguments

guard arguments.count >= 2 else {
    complain("usage: pngbench-swift <file.png> [rounds] [transform,transform,...]\n")
    exit(2)
}

let path = arguments[1]
let rounds = arguments.count > 2 ? Int(arguments[2]) ?? 20 : 20
let want = arguments.count > 3 ? parseTransforms(arguments[3]) : Want.all

guard let file = fopen(path, "rb") else { exit(2) }

fseek(file, 0, SEEK_END)
let size = ftell(file)
fseek(file, 0, SEEK_SET)

let console = Console()
console.data = .allocate(capacity: size)

guard fread(console.data.baseAddress!, 1, size, file) == size else { exit(2) }
fclose(file)

var bestPlain = Double.greatestFiniteMagnitude
var bestTransformed = Double.greatestFiniteMagnitude
var bestEncode = Double.greatestFiniteMagnitude
var written = 0

guard (try? decode(console, want: [])) != nil else {
    print("\(path) unreadable")
    exit(0)
}

for _ in 0 ..< rounds {
    var started = now()
    _ = try! decode(console, want: want.intersection(.image))
    bestPlain = min(bestPlain, now() - started)

    started = now()
    _ = try! decode(console, want: want)
    bestTransformed = min(bestTransformed, now() - started)
}

let kept = try! keepRows(console)

for _ in 0 ..< rounds {
    let started = now()
    written = try! encode(kept.rows, header: kept.header)
    bestEncode = min(bestEncode, now() - started)
}

let timings = String(
    format: "decode %.4f transformed %.4f encode %.4f",
    bestPlain,
    bestTransformed,
    bestEncode
)

print("\(path) \(kept.header.width)x\(kept.header.height) \(timings) wrote \(written)")
