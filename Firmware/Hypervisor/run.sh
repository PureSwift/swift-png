#!/bin/sh
# run.sh - boot the firmware in a real VM and check what it reports
#
# The loader's own exit code already reflects the firmware's result (see loader.c), so unlike
# Firmware/QEMU/run.sh — where the emulator's process exit code carries no information — this
# one can be trusted directly. What still needs its own handling is the case this environment
# adds that an emulator does not: `hv_vm_create` itself can fail if the host has no nested
# virtualization to offer, which is a real possibility on a macOS runner that is itself a VM.
# That is reported distinctly from a firmware fault, because "this environment cannot run the
# test" and "the code being tested is broken" call for different responses from whoever is
# reading the result.
#
# usage: run.sh <firmware.macho> <loader>

set -e

firmware="$1"
loader="$2"

if [ -z "$firmware" ] || [ -z "$loader" ] || [ ! -f "$firmware" ] || [ ! -x "$loader" ]; then
    echo "run.sh: usage: run.sh <firmware.macho> <loader>" >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$loader" "$firmware" > "$work/output" 2>&1
status=$?

cat "$work/output"

if grep -q "hv_vm_create(NULL) failed" "$work/output"; then
    echo "run.sh: unsupported here — this host has no nested virtualization to offer" >&2
    exit 3
fi

if [ "$status" -eq 0 ] && grep -q "round trip OK" "$work/output"; then
    echo "run.sh: pass"
    exit 0
fi

echo "run.sh: fail — see the output above" >&2
exit 1
