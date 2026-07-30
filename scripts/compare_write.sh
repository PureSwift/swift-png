#!/bin/sh
# compare_write.sh - write the same images with both libraries and compare what they mean
#
# Not what they are.  Two encoders that both produce correct files need not produce the same bytes:
# which filter each row uses, how hard the compressor tries, and where the image data is cut into
# chunks are all free choices, and comparing files would test agreement on things the format leaves
# open.
#
# So each library writes the image and reads its own file back, and those readings are compared.  That
# catches an encoder that writes something wrong, and an encoder that writes something right but reads
# it back wrongly.
#
# It does not catch an encoder that agrees with itself and with nothing else — a file only it can
# read.  So the files are swapped as well: each library reads what the other wrote, and both readings
# must agree with everything above.
#
# usage: compare_write.sh <ours> <reference>

set -e

ours="$1"
reference="$2"

if [ ! -x "$ours" ] || [ ! -x "$reference" ]; then
    echo "compare_write.sh: usage: compare_write.sh <ours> <reference>" >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
count=0

for case in $("$ours" --cases); do
    count=$((count + 1))

    "$reference" "$work/reference.png" "$case" > "$work/reference" 2>&1 \
        || echo "exit $?" >> "$work/reference"
    "$ours" "$work/ours.png" "$case" > "$work/ours" 2>&1 \
        || echo "exit $?" >> "$work/ours"

    # Each library reading the other's file.
    "$ours" "$work/reference.png" dump > "$work/ours-reading-theirs" 2>&1 \
        || echo "exit $?" >> "$work/ours-reading-theirs"
    "$reference" "$work/ours.png" dump > "$work/theirs-reading-ours" 2>&1 \
        || echo "exit $?" >> "$work/theirs-reading-ours"

    for reading in ours ours-reading-theirs theirs-reading-ours; do
        if diff -q "$work/reference" "$work/$reading" > /dev/null; then
            continue
        fi

        failures=$((failures + 1))

        case "$reading" in
            ours) what="wrote a different picture" ;;
            ours-reading-theirs) what="read the reference's file differently" ;;
            theirs-reading-ours) what="wrote a file the reference reads differently" ;;
        esac

        if [ "$failures" -le 4 ]; then
            echo "--- $case: $what ---"
            diff "$work/reference" "$work/$reading" | head -10
        else
            echo "--- $case: $what ---"
        fi
    done
done

if [ "$count" -eq 0 ]; then
    echo "no cases reported by $ours" >&2
    exit 2
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures of $((count * 3)) written-image comparisons differed" >&2
    exit 1
fi

echo "$count images written and read back three ways, all matching the reference"
