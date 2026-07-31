#!/bin/sh
# compare_simple.sh - read every image the short way, in every format, and compare
#
# The header is compared on its own as well as with a format, because a client decides what to ask for
# from what the header said: a library that read the pixels perfectly but described the file wrongly
# would still be unusable.
#
# usage: compare_simple.sh <ours> <reference> <corpus> [known-differences-file]

set -e

ours="$1"
reference="$2"
corpus="$3"
known="$4"

if [ ! -x "$ours" ] || [ ! -x "$reference" ] || [ ! -d "$corpus" ]; then
    echo "compare_simple.sh: usage: compare_simple.sh <ours> <reference> <corpus>" >&2
    exit 2
fi

# The header alone, then every format the API defines that is not colour-mapped.
formats="header 0x00 0x01 0x02 0x03 0x11 0x12 0x13 0x21 0x23 0x04 0x05 0x06 0x07"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
exempt=0
count=0
used=""

for path in "$corpus"/*.png; do
    image=$(basename "$path")

    case "$image" in damaged-*|bad-*) continue ;; esac

    for format in $formats; do
        count=$((count + 1))

        if [ "$format" = header ]; then
            "$reference" "$path" > "$work/reference" 2>&1 || echo "exit $?" >> "$work/reference"
            "$ours" "$path" > "$work/ours" 2>&1 || echo "exit $?" >> "$work/ours"
        else
            "$reference" "$path" "$format" > "$work/reference" 2>&1 \
                || echo "exit $?" >> "$work/reference"
            "$ours" "$path" "$format" > "$work/ours" 2>&1 || echo "exit $?" >> "$work/ours"
        fi

        if diff -q "$work/reference" "$work/ours" > /dev/null; then
            continue
        fi

        # A case this library says it has not implemented is recorded as a class rather than one file
        # at a time: which files reach it depends on what each one is, so listing them would be listing
        # the corpus.  The marker line in the known-differences file is what says that is allowed, and
        # it goes stale the moment nothing reaches it.
        if grep -q "not implemented" "$work/ours" 2>/dev/null &&
           [ -n "$known" ] && [ -f "$known" ] && grep -q "^unimplemented " "$known"; then
            exempt=$((exempt + 1))
            used="$used unimplemented"
            continue
        fi

        if [ -n "$known" ] && [ -f "$known" ] && grep -q "^$image $format " "$known"; then
            exempt=$((exempt + 1))
            used="$used $image:$format"
            continue
        fi

        failures=$((failures + 1))

        if [ "$failures" -le 4 ]; then
            echo "--- $image as $format ---"
            diff "$work/reference" "$work/ours" | head -6
        else
            echo "--- $image as $format differs ---"
        fi
    done
done

if [ "$count" -eq 0 ]; then
    echo "no images found in $corpus" >&2
    exit 2
fi

stale=0

if [ -n "$known" ] && [ -f "$known" ]; then
    while read -r image format rest; do
        case "$image" in ''|\#*) continue ;; esac

        if [ "$image" = unimplemented ]; then
            if ! echo "$used" | grep -q " unimplemented"; then
                echo "stale exemption: nothing is refused as unimplemented any more" >&2
                stale=$((stale + 1))
            fi

            continue
        fi

        if ! echo "$used" | grep -q " $image:$format"; then
            echo "stale exemption: $image $format now matches the reference" >&2
            stale=$((stale + 1))
        fi
    done < "$known"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures of $count simplified reads differed" >&2
    exit 1
fi

if [ "$stale" -ne 0 ]; then
    echo "$stale recorded differences no longer differ; remove them from $(basename "$known")" >&2
    exit 1
fi

if [ "$exempt" -ne 0 ]; then
    echo "$((count - exempt)) simplified reads matched the reference, $exempt differ as recorded"
else
    echo "$count simplified reads matched the reference"
fi
