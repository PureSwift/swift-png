#!/bin/sh
# build.sh - link a bootable smoke test for a target with no operating system
#
# scripts/build_embedded.sh proves the engine *compiles* under Embedded Swift's restrictions;
# this proves the object code it produces is correct — a real ARM ELF, containing PNG and
# LZ77 exactly as a client embedding them would, booted under an emulator and checked for a
# byte-exact round trip rather than merely for a clean compile.
#
# usage: build.sh [output-directory]

set -e

triple="armv7em-none-none-eabi"
root=$(cd "$(dirname "$0")/../.." && pwd)
here=$(cd "$(dirname "$0")" && pwd)
output="${1:-$root/build/embedded/$triple/firmware}"

mkdir -p "$output"

echo "building the compression modules and PNG for $triple"
"$root/scripts/build_embedded.sh" "$triple" "$output/libs"

swiftc=$(xcrun --find swiftc 2>/dev/null || command -v swiftc)
toolchain=$(dirname "$(dirname "$swiftc")")

if [ ! -d "$toolchain/usr/lib/swift/embedded/$triple" ] \
    && [ ! -d "$toolchain/lib/swift/embedded/$triple" ]; then
    for candidate in "$HOME"/Library/Developer/Toolchains/*.xctoolchain; do
        if [ -d "$candidate/usr/lib/swift/embedded/$triple" ]; then
            swiftc="$candidate/usr/bin/swiftc"
            break
        fi
    done
fi

echo "compiling the smoke test itself"
"$swiftc" \
    -target "$triple" -enable-experimental-feature Embedded -wmo -parse-as-library -Osize \
    -I "$output/libs" \
    -c -o "$output/App.o" \
    "$here/App.swift"

arm_gcc=$(command -v arm-none-eabi-gcc || true)

if [ -z "$arm_gcc" ]; then
    echo "build.sh: arm-none-eabi-gcc not found" >&2
    exit 2
fi

echo "linking"
"$arm_gcc" \
    -mcpu=cortex-m4 -mthumb -mfloat-abi=soft -nostdlib -nostartfiles -ffreestanding \
    -Os -T "$here/link.ld" -Wl,--gc-sections \
    "$here/startup.c" "$here/shim.c" "$here/main.c" \
    "$output/App.o" "$output/libs/PNG.o" "$output/libs/Zlib.o" "$output/libs/LZ77.o" \
    -lgcc \
    -o "$output/firmware.elf"

echo "wrote $output/firmware.elf"
