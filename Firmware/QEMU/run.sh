#!/bin/sh
# run.sh - boot the smoke test under an emulated Cortex-M4F and check what it reports
#
# Checked by a marker in the firmware's own semihosting output rather than by QEMU's process
# exit code: this QEMU version exits 1 for success, for a missing kernel file, and for an
# unrecognized machine name alike, so the code carries no information and a real signal has to
# come from what the firmware actually said.
#
# usage: run.sh <firmware.elf>

set -e

elf="$1"

if [ -z "$elf" ] || [ ! -f "$elf" ]; then
    echo "run.sh: usage: run.sh <firmware.elf>" >&2
    exit 2
fi

qemu=$(command -v qemu-system-arm || true)

if [ -z "$qemu" ]; then
    echo "run.sh: qemu-system-arm not found" >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Thirty seconds is generous for a board that either finishes in well under one or hangs
# outright; a hang here means the firmware faulted somewhere this build's own fault handler did
# not catch, which is itself worth thirty seconds to find out about.
timeout 30 "$qemu" \
    -M mps2-an386 -nographic -semihosting-config enable=on,target=native \
    -kernel "$elf" > "$work/output" 2>&1 \
    || true

cat "$work/output"

if [ ! -s "$work/output" ]; then
    echo "run.sh: fail — qemu produced no output at all" >&2
    exit 1
fi

if grep -q "round trip OK" "$work/output" \
    && ! grep -qE "HARDFAULT|OOM|MISMATCH|failed" "$work/output"; then
    echo "run.sh: pass"
    exit 0
fi

echo "run.sh: fail — no clean pass marker in the output above" >&2
exit 1
