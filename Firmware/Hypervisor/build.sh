#!/bin/sh
# build.sh - link a bootable Mach-O image and the host that runs it
#
# Two very different things get built here. The guest firmware — guest.c, vectors.S, the same
# Firmware/QEMU/App.swift smoke test, and PNGCore+LZ77 for arm64-apple-none-macho — is linked
# into a freestanding Mach-O executable the way Firmware/QEMU links an ELF one, with `ld`'s own
# static, no-dyld options standing in for a linker script. The host, loader.c, is an ordinary
# signed macOS program that creates the VM and boots that executable inside it; it is built and
# code-signed with the Hypervisor entitlement here because nothing about it changes between runs.
#
# usage: build.sh [output-directory]

set -e

triple="arm64-apple-none-macho"
root=$(cd "$(dirname "$0")/../.." && pwd)
here=$(cd "$(dirname "$0")" && pwd)
output="${1:-$root/build/embedded/$triple/hypervisor}"

mkdir -p "$output"

echo "building LZ77 and PNGCore for $triple"
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
    "$here/../QEMU/App.swift"

echo "compiling the guest's own runtime shims and exception vectors"
xcrun -sdk macosx clang -target arm64-apple-macos11 -c -o "$output/guest.o" "$here/guest.c"
xcrun -sdk macosx clang -target arm64-apple-macos11 -c -o "$output/vectors.o" "$here/vectors.S"

echo "linking the guest firmware"
ld -static -arch arm64 -platform_version macos 11.0 11.0 -e _reset_entry \
    -pagezero_size 0x0 -image_base 0x40000000 -segaddr __TEXT 0x40000000 \
    -o "$output/firmware.macho" \
    "$output/guest.o" "$output/vectors.o" "$output/App.o" \
    "$output/libs/PNGCore.o" "$output/libs/LZ77.o"

echo "building the host loader"
xcrun -sdk macosx clang -o "$output/loader" "$here/loader.c" -framework Hypervisor

# The Hypervisor entitlement is what lets an ordinary, unprivileged process ask for a VM at all;
# an ad-hoc identity is enough to grant it locally, which is why nothing here needs a developer
# certificate.
codesign -s - --entitlements "$here/loader.entitlements" "$output/loader"

echo "wrote $output/firmware.macho and $output/loader"
