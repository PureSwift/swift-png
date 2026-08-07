// swift-tools-version: 6.3

import PackageDescription

// This package builds two things from one engine.
//
// `PNG` is a Swift library with a Swift API and no C dependencies.  `CPNG` is
// the same engine behind the published libpng C API, built so that a program
// compiled against libpng can link or load it unchanged.  `PNG` is that engine
// itself — chunks, row pipeline, transforms, compression — rather than a
// separate wrapper around it; nothing sits between it and a Swift client.
//
// SwiftPM drives development, the Swift library, and the test suites.  The
// shipping C library is built by CMakeLists.txt, because the install name,
// soname and export list that make substitution work are not expressible here.

let package = Package(
    name: "swift-png",
    // Only Apple platforms need saying, and this is not our floor but the one we inherit:
    // swift-zlib offers a `Span` interface, and that is as far back as `Span` back-deploys.
    // Everywhere else the standard library ships with the compiler, and the C library built
    // by CMakeLists.txt sets its own deployment target independently of this.
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PNG", targets: ["PNG"]),

        // For iterating on the C surface locally; the artifact that gets
        // installed comes from the CMake build.
        .library(name: "png", type: .dynamic, targets: ["PNGABI"]),
    ],
    traits: [
        // Enabled by default, and it stays that way now the Swift path works: what this
        // library is measured against is the reference's own output, and two encoders do not
        // produce the same compressed bytes.  A client that wants no C dependency at all asks
        // for it with `--disable-default-traits`, and the suites run both ways.
        .default(enabledTraits: ["SystemZlib"]),
        // The engine reaches DEFLATE through one interface with two backends: the
        // swift-zlib package, which is the default everywhere now — the shipped C
        // library is Swift throughout, compression included — and the system zlib,
        // which is faster and available wherever there is a system to provide it.
        .trait(
            name: "SystemZlib",
            description: "Use the system zlib for compression instead of the Swift implementation."
        )
    ],
    dependencies: [
        // DEFLATE and INFLATE in Swift, extracted so that the two libraries share one
        // implementation rather than each carrying its own copy of it.
        .package(url: "https://github.com/PureSwift/swift-zlib.git", from: "1.0.3"),
    ],
    targets: [
        // The published C API, the completed control structures, and the parts
        // of the implementation that have to be C: error dispatch and the jump
        // boundary, allocation, and the client callback trampolines.
        .target(
            name: "CPNG",
            path: "Sources/CPNG",
            publicHeadersPath: "include"
        ),

        // One `@c` function per published entry point, bound to the declaration
        // in the vendored header.
        .target(
            name: "PNGABI",
            dependencies: ["CPNG", "PNG"],
            path: "Sources/PNGABI"
        ),

        // The engine, and the Swift API: chunks, row pipeline, transforms,
        // compression.  No Foundation, and no knowledge of the C API.
        .target(
            name: "PNG",
            dependencies: [
                .product(name: "LZ77", package: "swift-zlib"),
                .product(name: "Zlib", package: "swift-zlib"),
                .target(name: "CSystemZlib", condition: .when(traits: ["SystemZlib"])),
                "CChecksum",
            ],
            path: "Sources/PNG"
        ),

        // Times the engine driven from Swift, over the same images and in the same
        // output format as Conformance/pngbench.c, so the two read side by side.
        // The C benchmark's bar is parity with the reference; with no boundary to
        // cross, this one's is beating it.
        .executableTarget(
            name: "pngbench-swift",
            dependencies: ["PNG"],
            path: "Sources/pngbench-swift"
        ),

        // A round trip, run for real under wasm32-unknown-wasip1 — the WASM counterpart to the
        // firmware images under Firmware/QEMU and Firmware/Hypervisor, proving the embedded
        // build is correct rather than only that it compiles. Also builds and runs on every
        // hosted platform this package supports, which is a useful sanity check on its own
        // (nothing here is WASI-specific beyond which libc it reaches for malloc/free through).
        .executableTarget(
            name: "wasm-smoke-test",
            dependencies: ["PNG"],
            path: "Sources/wasm-smoke-test"
        ),

        // The CRC-32 instruction, where the processor has one.  Header-only — nothing to link —
        // so the library it serves still depends on nothing; the stub .c exists because the
        // package manager requires a compiled file in a C target.
        .target(
            name: "CChecksum",
            path: "Sources/CChecksum",
            publicHeadersPath: "include"
        ),

        .systemLibrary(
            name: "CSystemZlib",
            path: "Sources/CSystemZlib",
            providers: [.brew(["zlib"]), .apt(["zlib1g-dev"])]
        ),

        .testTarget(
            name: "PNGTests",
            dependencies: ["PNG"],
            path: "Tests/PNGTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
