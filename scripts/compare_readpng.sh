#!/bin/sh
# compare_readpng.sh - read every image in one call, over a few transform masks, and compare
#
# The convenience form of reading is a different code path from the row-by-row one: the library makes
# the transform requests itself, allocates the rows, and hands back an array.  What can go wrong that
# the row-by-row comparison would not catch is the agreement between the size it reports and the size
# it allocated, so the masks driven here are the ones that change a row's shape.
#
# usage: compare_readpng.sh <ours> <reference> <corpus> [known-differences-file]

set -e

ours="$1"
reference="$2"
corpus="$3"
known="$4"

if [ ! -x "$ours" ] || [ ! -x "$reference" ] || [ ! -d "$corpus" ]; then
    echo "compare_readpng.sh: usage: compare_readpng.sh <ours> <reference> <corpus>" >&2
    exit 2
fi

# Identity, then each shape-changing request, then two of them together.
masks="0x0000 0x0001 0x0002 0x0004 0x0010 0x2000 0x4000 0x8000 0x0014 0x2010 0x4010 0x00c0"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
exempt=0
count=0
used=""

for path in "$corpus"/*.png; do
    image=$(basename "$path")

    case "$image" in damaged-*|bad-*) continue ;; esac

    for mask in $masks; do
        count=$((count + 1))

        "$reference" "$path" "$mask" > "$work/reference" 2>&1 || echo "exit $?" >> "$work/reference"
        "$ours" "$path" "$mask" > "$work/ours" 2>&1 || echo "exit $?" >> "$work/ours"

        if diff -q "$work/reference" "$work/ours" > /dev/null; then
            continue
        fi

        if [ -n "$known" ] && [ -f "$known" ] && grep -q "^$image $mask " "$known"; then
            exempt=$((exempt + 1))
            used="$used $image:$mask"
            continue
        fi

        failures=$((failures + 1))

        if [ "$failures" -le 4 ]; then
            echo "--- $image with $mask ---"
            diff "$work/reference" "$work/ours" | head -8
        else
            echo "--- $image with $mask differs ---"
        fi
    done
done

if [ "$count" -eq 0 ]; then
    echo "no images found in $corpus" >&2
    exit 2
fi

stale=0

if [ -n "$known" ] && [ -f "$known" ]; then
    while read -r image mask rest; do
        case "$image" in ''|\#*) continue ;; esac

        if ! echo "$used" | grep -q " $image:$mask"; then
            echo "stale exemption: $image $mask now matches the reference" >&2
            stale=$((stale + 1))
        fi
    done < "$known"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures of $count whole-image reads differed" >&2
    exit 1
fi

if [ "$stale" -ne 0 ]; then
    echo "$stale recorded differences no longer differ; remove them from $(basename "$known")" >&2
    exit 1
fi

if [ "$exempt" -ne 0 ]; then
    echo "$((count - exempt)) whole-image reads matched the reference, $exempt differ as recorded"
else
    echo "$count whole-image reads matched the reference"
fi
