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
#
# 0x04 to 0x07 are the linear ones: samples that are already light, written as a sixteen bit file
# that says so rather than being encoded on the way in.  The two that carry coverage, 0x05 and 0x07,
# also have it multiplied into the colour, which the format does not store — so those drive the
# undoing of that as well.  0x25 and 0x27 put the coverage first, which is a second arrangement of
# the same row and a place the undoing could get the channel wrong.
#
# The last of them is large for a reason: undoing a pre-multiplication is a division that rounds, and
# whether two roundings agree depends on where the quotient falls between two integers.  A few hundred
# samples visit too few of those places for a difference of one count to show up; a quarter of a
# million visit enough.
#
# The `narrow` cases ask for that same sixteen bit input to come down to an eight bit file, which is
# a conversion rather than a container: the light goes through the display's curve on the way.  Its
# own large case is there for the same reason as the one above.
#
# 0x08 to 0x0f are colour-mapped: a client's own colour map rather than samples, written as an
# indexed file with a palette and, wherever the map carries real coverage, a transparency table.
# 0x0c to 0x0f are the ones whose map entries are themselves sixteen bit light rather than eight
# bit sRGB, needing the same undoing 0x05 and 0x07 do above — done once per colour-map entry
# instead of once per pixel.  0x18/0x19/0x1a/0x1b and 0x28/0x29/0x2a/0x2b drive BGR and AFIRST
# through the map the way the plain sRGB formats above drive them through a row.
cases="0x00:13:7 0x01:13:7 0x02:13:7 0x03:13:7 0x11:13:7 0x12:13:7 0x13:13:7 0x21:13:7 0x23:13:7
0x02:1:1 0x03:256:2 0x00:2:64 0x04:13:7 0x06:13:7 0x06:1:1 0x04:2:64
0x05:13:7 0x07:13:7 0x07:1:1 0x05:2:64 0x25:13:7 0x27:13:7 0x07:256:256
0x04:13:7:narrow 0x06:13:7:narrow 0x05:13:7:narrow 0x07:13:7:narrow
0x25:13:7:narrow 0x27:13:7:narrow 0x06:1:1:narrow 0x07:256:256:narrow
0x02:13:7:memory 0x03:13:7:memory 0x13:5:3:memory 0x06:13:7:memory 0x07:13:7:memory
0x08:13:7 0x09:13:7 0x0a:13:7 0x0b:13:7 0x0c:13:7 0x0d:13:7 0x0e:13:7 0x0f:13:7
0x18:13:7 0x19:13:7 0x1a:13:7 0x1b:13:7 0x28:13:7 0x29:13:7 0x2a:13:7 0x2b:13:7
0x0b:1:1 0x08:256:2 0x0a:2:64 0x0f:5:3:memory 0x0b:17:19"

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
