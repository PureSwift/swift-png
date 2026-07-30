#!/bin/sh
# compare_decode.sh - decode a corpus with both libraries and diff the results
#
# The two programs are the same source compiled against the two libraries.  If
# their output differs on any image, this library decodes it differently from the
# reference, and the diff points at the byte.
#
# usage: compare_decode.sh <pngdump-ours> <pngdump-reference> <corpus-directory>

set -e

ours="$1"
reference="$2"
corpus="$3"

if [ ! -x "$ours" ] || [ ! -x "$reference" ] || [ ! -d "$corpus" ]; then
    echo "compare_decode.sh: usage: compare_decode.sh <ours> <reference> <corpus>" >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
count=0

for image in "$corpus"/*.png; do
    [ -f "$image" ] || continue

    name=$(basename "$image")
    count=$((count + 1))

    # Exit statuses are compared too: agreeing on the pixels but disagreeing on
    # whether the decode succeeded is still a difference.
    "$reference" "$image" > "$work/reference" 2>&1 || echo "exit $?" >> "$work/reference"
    "$ours" "$image" > "$work/ours" 2>&1 || echo "exit $?" >> "$work/ours"

    if ! diff -q "$work/reference" "$work/ours" > /dev/null; then
        failures=$((failures + 1))
        echo "--- $name differs ---"
        diff "$work/reference" "$work/ours" | head -20
    fi
done

if [ "$count" -eq 0 ]; then
    echo "no images found in $corpus" >&2
    exit 2
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures of $count images decoded differently" >&2
    exit 1
fi

echo "$count images decoded identically to the reference"
