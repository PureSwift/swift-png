#!/bin/sh
# compare_roundtrip.sh - read every corpus image, write it back, and compare what survived
#
# The widest check on the writer.  Where the write comparison makes its own images from a short list
# of shapes, this takes every file in the corpus — with whatever awkward geometry, depth and metadata
# it was built to have — and asks whether the library can reproduce it.
#
# What is compared is the reading of the file each library *wrote*, and then each library's reading of
# the other's file.  Comparing the two readings within one run would be weaker: a library that reads a
# chunk wrongly and writes it back the same way would pass that, and this is meant to catch such a
# pair.
#
# What it covers is what the API can carry.  A chunk whose accessors are not yet implemented is
# dropped by both libraries and so passes silently — the comparison says nothing about it until the
# accessors land, at which point the harness copies it and this starts checking it.
#
# Images that are meant to be unreadable are skipped.  A file that cannot be read cannot be written
# back, and what a library does with a broken file is the error comparison's business rather than
# this one's.  So are the ones a writer is required to refuse: they read perfectly well and are then
# not writable at all, which is a fact about writing them rather than about what survives a round
# trip.
#
# usage: compare_roundtrip.sh <ours> <reference> <corpus> [known-differences-file]

set -e

ours="$1"
reference="$2"
corpus="$3"
known="$4"

if [ ! -x "$ours" ] || [ ! -x "$reference" ] || [ ! -d "$corpus" ]; then
    echo "compare_roundtrip.sh: usage: compare_roundtrip.sh <ours> <reference> <corpus>" >&2
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
used=""

for path in "$corpus"/*.png; do
    image=$(basename "$path")

    case "$image" in damaged-*|bad-*|over-*) continue ;; esac

    count=$((count + 1))

    # Cleared first, so that a write which fails leaves nothing behind: without this the next
    # comparison would be made against whichever file the previous image left in place, and would
    # pass or fail for reasons that have nothing to do with the image being tested.
    rm -f "$work/reference.png" "$work/ours.png"

    "$reference" "$path" "$work/reference.png" > "$work/reference" 2>&1 \
        || echo "exit $?" >> "$work/reference"
    "$ours" "$path" "$work/ours.png" > "$work/ours" 2>&1 \
        || echo "exit $?" >> "$work/ours"

    "$ours" "$work/reference.png" dump > "$work/ours-reading-theirs" 2>&1 \
        || echo "exit $?" >> "$work/ours-reading-theirs"
    "$reference" "$work/ours.png" dump > "$work/theirs-reading-ours" 2>&1 \
        || echo "exit $?" >> "$work/theirs-reading-ours"

    for reading in ours ours-reading-theirs theirs-reading-ours; do
        if diff -q "$work/reference" "$work/$reading" > /dev/null; then
            continue
        fi

        if [ -n "$known" ] && [ -f "$known" ] && grep -q "^$image " "$known"; then
            exempt=$((exempt + 1))
            used="$used $image"
            continue
        fi

        failures=$((failures + 1))

        case "$reading" in
            ours) what="wrote a different file" ;;
            ours-reading-theirs) what="read the reference's file differently" ;;
            theirs-reading-ours) what="wrote a file the reference reads differently" ;;
        esac

        if [ "$failures" -le 4 ]; then
            echo "--- $image: $what ---"
            diff "$work/reference" "$work/$reading" | head -8
        else
            echo "--- $image: $what ---"
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
    echo "$failures of $((count * 3)) round-trip comparisons differed" >&2
    exit 1
fi

if [ "$stale" -ne 0 ]; then
    echo "$stale recorded differences no longer differ; remove them from $(basename "$known")" >&2
    exit 1
fi

if [ "$exempt" -ne 0 ]; then
    echo "$count images round-tripped three ways," \
        "$((count * 3 - exempt)) comparisons matching and $exempt differing as recorded"
else
    echo "$count images round-tripped three ways, all matching the reference"
fi
