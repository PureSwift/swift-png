// swift-tools-version: 6.3

import PackageDescription

// This package builds two things from one engine.
//
// `PNG` is a Swift library with a Swift API and no C dependencies.  `CPNG` is
// the same engine behind the published libpng C API, built so that a program
// compiled against libpng can link or load it unchanged.
//
// SwiftPM drives development, the Swift library, and the test suites.  The
// shipping C library is built by CMakeLists.txt, because the install name,
// soname and export list that make substitution work are not expressible here.

let package = Package(
    name: "swift-png",
    products: [
        .library(name: "PNG", targets: ["PNG"]),

        // For iterating on the C surface locally; the artifact that gets
        // installed comes from the CMake build.
        .library(name: "png", type: .dynamic, targets: ["PNGABI"]),
    ],
    traits: [
        // Enabled by default for now: the Swift compression path is not written
        // yet, so this is the only working backend.  The default flips when it is.
        .default(enabledTraits: ["SystemZlib"]),
        // The engine reaches DEFLATE through one interface with two backends.
        // Swift clients get the Swift implementation so the library stays
        // dependency-free; the C library defaults to zlib, matching what the
        // reference build links against.
        .trait(
            name: "SystemZlib",
            description: "Use the system zlib for compression instead of the Swift implementation."
        )
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
            dependencies: ["CPNG", "PNGCore"],
            path: "Sources/PNGABI"
        ),

        // The engine.  No Foundation, and no knowledge of the C API.
        .target(
            name: "PNGCore",
            dependencies: [
                "LZ77",
                .target(name: "CZlib", condition: .when(traits: ["SystemZlib"])),
            ],
            path: "Sources/PNGCore"
        ),

        // The Swift API.
        .target(
            name: "PNG",
            dependencies: ["PNGCore"],
            path: "Sources/PNG"
        ),

        // DEFLATE and INFLATE in Swift.
        .target(
            name: "LZ77",
            path: "Sources/LZ77"
        ),

        // Times the engine driven from Swift, over the same images and in the same
        // output format as Conformance/pngbench.c, so the two read side by side.
        // The C benchmark's bar is parity with the reference; with no boundary to
        // cross, this one's is beating it.
        .executableTarget(
            name: "pngbench-swift",
            dependencies: ["PNGCore"],
            path: "Sources/pngbench-swift"
        ),

        // A round trip, run for real under wasm32-unknown-wasip1 — the WASM counterpart to the
        // firmware images under Firmware/QEMU and Firmware/Hypervisor, proving the embedded
        // build is correct rather than only that it compiles. Also builds and runs on every
        // hosted platform this package supports, which is a useful sanity check on its own
        // (nothing here is WASI-specific beyond which libc it reaches for malloc/free through).
        .executableTarget(
            name: "wasm-smoke-test",
            dependencies: ["PNGCore"],
            path: "Sources/wasm-smoke-test"
        ),

        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            providers: [.brew(["zlib"]), .apt(["zlib1g-dev"])]
        ),

        .testTarget(
            name: "LZ77Tests",
            dependencies: ["LZ77"],
            path: "Tests/LZ77Tests"
        ),
        .testTarget(
            name: "PNGCoreTests",
            dependencies: ["PNGCore"],
            path: "Tests/PNGCoreTests"
        ),
        .testTarget(
            name: "PNGTests",
            dependencies: ["PNG"],
            path: "Tests/PNGTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
