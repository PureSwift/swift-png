#!/bin/sh
# compare_progressive.sh - push each image in at several block sizes and compare what comes back
#
# The progressive reader is the sequential one turned inside out, and the property that matters is
# that the block size cannot be felt: a client handing over one byte at a time must be told exactly
# what a client handing over the whole file is told.
#
# So each image is decoded at several sizes and every output compared against the reference's — and
# the sizes are chosen to fall inside the units the format is built from.  One byte lands in the
# middle of everything; three and seven fall inside a chunk's header; the larger ones span chunks.
#
# usage: compare_progressive.sh <ours> <reference> <corpus> [known-differences-file]

set -e

ours="$1"
reference="$2"
corpus="$3"
known="$4"

if [ ! -x "$ours" ] || [ ! -x "$reference" ] || [ ! -d "$corpus" ]; then
    echo "compare_progressive.sh: usage: compare_progressive.sh <ours> <reference> <corpus>" >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
exempt=0
count=0
used=""

for path in "$corpus"/*.png; do
    image=$(basename "$path")

    for block in 1 3 7 64 8192; do
        count=$((count + 1))

        "$reference" "$path" "$block" > "$work/reference" 2>&1 || echo "exit $?" >> "$work/reference"
        "$ours" "$path" "$block" > "$work/ours" 2>&1 || echo "exit $?" >> "$work/ours"

        if diff -q "$work/reference" "$work/ours" > /dev/null; then
            continue
        fi

        if [ -n "$known" ] && [ -f "$known" ] && grep -q "^$image " "$known"; then
            exempt=$((exempt + 1))
            used="$used $image"
            continue
        fi

        failures=$((failures + 1))

        if [ "$failures" -le 4 ]; then
            echo "--- $image at $block bytes a time ---"
            diff "$work/reference" "$work/ours" | head -8
        else
            echo "--- $image at $block bytes a time differs ---"
        fi
    done
done

if [ "$count" -eq 0 ]; then
    echo "no images found in $corpus" >&2
    exit 2
fi

stale=0

if [ -n "$known" ] && [ -f "$known" ]; then
    while read -r image rest; do
        case "$image" in ''|\#*) continue ;; esac

        if ! echo "$used" | grep -q " $image"; then
            echo "stale exemption: $image now matches the reference" >&2
            stale=$((stale + 1))
        fi
    done < "$known"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures of $count progressive decodes differed" >&2
    exit 1
fi

if [ "$stale" -ne 0 ]; then
    echo "$stale recorded differences no longer differ; remove them from $(basename "$known")" >&2
    exit 1
fi

if [ "$exempt" -ne 0 ]; then
    echo "$((count - exempt)) progressive decodes matched the reference, $exempt differ as recorded"
else
    echo "$count progressive decodes matched the reference"
fi
