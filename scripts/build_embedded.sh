#!/bin/sh
# build_embedded.sh - the engine as static libraries for a target with no operating system
#
# SwiftPM drives the desktop and WASM builds, but a bare-metal target has no Swift SDK bundle to
# hand it: what exists is the toolchain's own Embedded Swift standard library, shipped as one
# .swiftmodule per target triple.  So this drives swiftc directly — two modules, compiled in
# dependency order with whole-module optimisation, each packed into a static archive.
#
# What comes out is half of a firmware: the decode and encode engine, expecting the platform to
# provide what Embedded Swift requires of it — an allocator (posix_memalign or malloc), and
# nothing else.  No C library is assumed: the compression module is the Swift implementation,
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
    # Fall back to any installed toolchain that does ship it, newest first.
    for candidate in "$HOME"/Library/Developer/Toolchains/*.xctoolchain; do
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

flags="-target $triple -enable-experimental-feature Embedded -wmo -parse-as-library -O"

echo "building LZ77 for $triple"
# shellcheck disable=SC2086
"$swiftc" $flags \
    -module-name LZ77 \
    -emit-module -emit-module-path "$output/LZ77.swiftmodule" \
    -c -o "$output/LZ77.o" \
    "$root"/Sources/LZ77/*.swift

ar=$( (command -v llvm-ar || xcrun --find llvm-ar || command -v ar) 2>/dev/null | head -1 )
"$ar" rcs "$output/libLZ77.a" "$output/LZ77.o"

echo "building PNGCore for $triple"
# shellcheck disable=SC2086
"$swiftc" $flags \
    -module-name PNGCore \
    -I "$output" \
    -emit-module -emit-module-path "$output/PNGCore.swiftmodule" \
    -c -o "$output/PNGCore.o" \
    $(find "$root/Sources/PNGCore" -name '*.swift')

"$ar" rcs "$output/libPNGCore.a" "$output/PNGCore.o"

echo "wrote $output/libLZ77.a and $output/libPNGCore.a"
