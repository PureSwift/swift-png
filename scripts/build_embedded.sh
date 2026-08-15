#!/bin/sh
# build_embedded.sh - the engine as static libraries for a target with no operating system
#
# SwiftPM drives the desktop and WASM builds, but a bare-metal target has no Swift SDK bundle to
# hand it: what exists is the toolchain's own Embedded Swift standard library, shipped as one
# .swiftmodule per target triple.  So this drives swiftc directly — two modules, compiled in
# dependency order with whole-module optimisation, each packed into a static archive.  Three of
# them now: DEFLATE and its zlib wrapper come from the sibling package rather than from this
# repository, so they are fetched once into the build tree at the pinned tag and compiled from
# there — SwiftPM's own checkout is used when one is already present, so an ordinary working
# copy needs no second clone.
#
# What comes out is half of a firmware: the decode and encode engine, expecting the platform to
# provide what Embedded Swift requires of it — an allocator (posix_memalign or malloc), and
# nothing else.  No C library is assumed: the compression modules are the Swift implementation,
# and the one libm call the gamma tables want has a fallback built from series when no libm is
# declared importable, which on these triples it is not.
#
# usage: build_embedded.sh [triple] [output-directory]
#        triples with a shipped stdlib: armv6m|armv7|armv7em|aarch64-none-none-*, and more under
#        $TOOLCHAIN/usr/lib/swift/embedded

set -e

triple="${1:-armv7em-none-none-eabi}"
output="${2:-build/embedded/$triple}"

root=$(cd "$(dirname "$0")/.." && pwd)

# The toolchain is found through swiftc itself rather than guessed at, so whichever toolchain
# the caller has selected is the one whose embedded stdlib is used.
swiftc=$(xcrun --find swiftc 2>/dev/null || command -v swiftc)
toolchain=$(dirname "$(dirname "$swiftc")")

if [ ! -d "$toolchain/lib/swift/embedded/$triple" ] \
    && [ ! -d "$toolchain/usr/lib/swift/embedded/$triple" ]; then
    # Fall back to any installed toolchain that does ship it. Both locations, because a
    # per-user install (swiftly, or a manually unpacked toolchain) lands under the caller's
    # home directory, while the official swift.org .pkg installer — run with `installer
    # -target /`, which is what a CI runner does — places it system-wide instead.
    for candidate in "$HOME"/Library/Developer/Toolchains/*.xctoolchain \
                     /Library/Developer/Toolchains/*.xctoolchain; do
        if [ -d "$candidate/usr/lib/swift/embedded/$triple" ]; then
            swiftc="$candidate/usr/bin/swiftc"
            break
        fi
    done
fi

if ! "$swiftc" --version > /dev/null 2>&1; then
    echo "build_embedded.sh: no swiftc with an embedded stdlib for $triple" >&2
    exit 2
fi

mkdir -p "$output"

# The compression package, at the tag Package.resolved pins.  A checkout SwiftPM has already
# made is preferred over cloning a second one; otherwise this is a shallow clone into the build
# tree, which is also what CI gets.
zlib_tag=1.0.6
zlib_source="$root/.build/checkouts/swift-zlib"

if [ ! -d "$zlib_source/Sources/LZ77" ]; then
    zlib_source="$root/build/embedded/deps/swift-zlib"

    if [ ! -d "$zlib_source/Sources/LZ77" ]; then
        echo "fetching swift-zlib $zlib_tag"
        rm -rf "$zlib_source"
        mkdir -p "$(dirname "$zlib_source")"
        git clone --quiet --depth 1 --branch "$zlib_tag" \
            https://github.com/PureSwift/swift-zlib.git "$zlib_source"
    fi
fi

flags="-target $triple -enable-experimental-feature Embedded -wmo -parse-as-library -O"

ar=$( (command -v llvm-ar || xcrun --find llvm-ar || command -v ar) 2>/dev/null | head -1 )

echo "building LZ77 for $triple"
# shellcheck disable=SC2086
"$swiftc" $flags \
    -module-name LZ77 \
    -emit-module -emit-module-path "$output/LZ77.swiftmodule" \
    -c -o "$output/LZ77.o" \
    "$zlib_source"/Sources/LZ77/*.swift

"$ar" rcs "$output/libLZ77.a" "$output/LZ77.o"

echo "building Zlib for $triple"
# shellcheck disable=SC2086
"$swiftc" $flags \
    -module-name Zlib \
    -I "$output" \
    -emit-module -emit-module-path "$output/Zlib.swiftmodule" \
    -c -o "$output/Zlib.o" \
    "$zlib_source"/Sources/Zlib/*.swift

"$ar" rcs "$output/libZlib.a" "$output/Zlib.o"

echo "building PNG for $triple"
# shellcheck disable=SC2086
"$swiftc" $flags \
    -module-name PNG \
    -I "$output" \
    -emit-module -emit-module-path "$output/PNG.swiftmodule" \
    -c -o "$output/PNG.o" \
    $(find "$root/Sources/PNG" -name '*.swift')

"$ar" rcs "$output/libPNG.a" "$output/PNG.o"

echo "wrote $output/libLZ77.a, $output/libZlib.a and $output/libPNG.a"
