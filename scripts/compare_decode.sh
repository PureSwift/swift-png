#!/bin/sh
# compare_decode.sh - decode a corpus with both libraries and diff the results
#
# The two programs are the same source compiled against the two libraries.  If
# their output differs on any image, this library decodes it differently from the
# reference, and the diff points at the byte.
#
# A handful of images are reported but not failed on, listed with their reasons in
# known-differences.txt.  That file is for cases where the reference's behaviour is not
# something to reproduce; work not yet done does not belong in it, since an unimplemented
# function already reports itself unimplemented.
#
# usage: compare_decode.sh <pngdump-ours> <pngdump-reference> <corpus-directory>
#                          [known-differences-file]

set -e

ours="$1"
reference="$2"
corpus="$3"
known="$4"

if [ ! -x "$ours" ] || [ ! -x "$reference" ] || [ ! -d "$corpus" ]; then
    echo "compare_decode.sh: usage: compare_decode.sh <ours> <reference> <corpus>" >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A recorded difference is not always a fact about every libpng: some are facts about the version
# in the room.  Entries guarded by a reference version are dropped here when the guard does not
# hold, so they neither exempt nor go stale.  See known_differences.sh.
. "$(dirname "$0")/known_differences.sh"
spng_active_differences "$known" "$work/known-active"
known="$work/known-active"

failures=0
exempt=0
count=0

for image in "$corpus"/*.png; do
    [ -f "$image" ] || continue

    name=$(basename "$image")
    count=$((count + 1))

    # Both ways a client can ask for the rows.  They run through different code, and for an
    # interlaced image they are quite different, so a difference in either is a difference.
    #
    # Exit statuses are compared too: agreeing on the pixels but disagreeing on whether the
    # decode succeeded is still a difference.
    : > "$work/reference"
    : > "$work/ours"

    for mode in rows image; do
        echo "mode $mode" >> "$work/reference"
        echo "mode $mode" >> "$work/ours"

        "$reference" "$image" "$mode" >> "$work/reference" 2>&1 \
            || echo "exit $?" >> "$work/reference"
        "$ours" "$image" "$mode" >> "$work/ours" 2>&1 || echo "exit $?" >> "$work/ours"
    done

    if ! diff -q "$work/reference" "$work/ours" > /dev/null; then
        if [ -n "$known" ] && [ -f "$known" ] && grep -q "^$name " "$known"; then
            echo "--- $name differs, as recorded in $(basename "$known") ---"
            exempt=$((exempt + 1))
            continue
        fi

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

if [ "$exempt" -ne 0 ]; then
    echo "$((count - exempt)) images decoded identically to the reference," \
        "$exempt differ as recorded"
else
    echo "$count images decoded identically to the reference"
fi
