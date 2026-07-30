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
# A case that cannot be compared is listed with its reason in the known-differences file, and a
# listing that no longer applies fails the run: an exemption that has silently stopped being needed is
# worse than none, since it covers whatever regresses into its place.
#
# usage: compare_write.sh <ours> <reference> [known-differences-file]

set -e

ours="$1"
reference="$2"
known="$3"

if [ ! -x "$ours" ] || [ ! -x "$reference" ]; then
    echo "compare_write.sh: usage: compare_write.sh <ours> <reference>" >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
exempt=0
count=0

: > "$(mktemp -d)/unused"
used=""

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

        if [ -n "$known" ] && [ -f "$known" ] && grep -q "^$case " "$known"; then
            exempt=$((exempt + 1))
            used="$used $case"
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

stale=0

if [ -n "$known" ] && [ -f "$known" ]; then
    while read -r case rest; do
        case "$case" in ''|\#*) continue ;; esac

        if ! echo "$used" | grep -q " $case"; then
            echo "stale exemption: $case now matches the reference" >&2
            stale=$((stale + 1))
        fi
    done < "$known"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures of $((count * 3)) written-image comparisons differed" >&2
    exit 1
fi

if [ "$stale" -ne 0 ]; then
    echo "$stale recorded differences no longer differ; remove them from $(basename "$known")" >&2
    exit 1
fi

if [ "$exempt" -ne 0 ]; then
    echo "$count images written and read back three ways," \
        "$((count * 3 - exempt)) comparisons matching and $exempt differing as recorded"
else
    echo "$count images written and read back three ways, all matching the reference"
fi
