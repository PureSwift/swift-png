#!/bin/sh
# compare_simple_write.sh - write images the short way, in every format, and compare
#
# Not by the bytes of the file, which two correct encoders need not agree on, but by what the file
# means: each library writes the same generated image, reads it back through the same simplified API,
# and the readings are compared.  The file each wrote is also read by the other, which is what catches
# a file only its own writer understands.
#
# usage: compare_simple_write.sh <ours> <reference>

set -e

ours="$1"
reference="$2"

if [ ! -x "$ours" ] || [ ! -x "$reference" ]; then
    echo "compare_simple_write.sh: usage: compare_simple_write.sh <ours> <reference>" >&2
    exit 2
fi

# The eight arrangements of colour and coverage, then the same again through memory.
cases="0x00:13:7 0x01:13:7 0x02:13:7 0x03:13:7 0x11:13:7 0x12:13:7 0x13:13:7 0x21:13:7 0x23:13:7
0x02:1:1 0x03:256:2 0x00:2:64 0x02:13:7:memory 0x03:13:7:memory 0x13:5:3:memory"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
count=0

for case in $cases; do
    format=$(echo "$case" | cut -d: -f1)
    width=$(echo "$case" | cut -d: -f2)
    height=$(echo "$case" | cut -d: -f3)
    memory=$(echo "$case" | cut -d: -f4)

    count=$((count + 1))

    "$reference" "$work/reference.png" "$format" "$width" "$height" $memory \
        > "$work/reference" 2>&1 || echo "exit $?" >> "$work/reference"
    "$ours" "$work/ours.png" "$format" "$width" "$height" $memory \
        > "$work/ours" 2>&1 || echo "exit $?" >> "$work/ours"

    if ! diff -q "$work/reference" "$work/ours" > /dev/null; then
        failures=$((failures + 1))
        echo "--- $case: wrote a different image ---"

        if [ "$failures" -le 3 ]; then
            diff "$work/reference" "$work/ours" | head -8
        fi
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "$failures of $count simplified writes differed" >&2
    exit 1
fi

echo "$count images written the short way, all matching the reference"
