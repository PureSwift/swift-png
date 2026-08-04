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

# The header alone, then every format the API defines that is not colour-mapped, then the
# colour-mapped cases that are implemented: a greyscale file into a greyscale colour map, an
# opaque RGB file into the reference's fixed six-by-six-by-six colour cube, and an indexed file
# into its own palette.  0x8a and 0x8b ask for BGR order, the one variation worth driving since a
# map's entries are stored differently for it rather than merely read differently; 0x0b and 0x8b
# ask for an alpha channel alongside colour that is opaque either way; 0x09 asks for coverage kept
# through a colour map rather than colour, and the :bg/:bg0 pairing on the colour-mapped formats
# drives a background named to remove coverage a colour-mapped source carries, the same as it does
# for the ordinary formats above.  0x04 and 0x05 discard colour into a sixteen bit result, removed
# and kept; 0x25 is 0x05 with the channel order swapped, the one variation worth driving there too.
#
# 0x0c to 0x0f are the colour-mapped formats whose *map entries* are sixteen bit linear light rather
# than eight bit sRGB — the colour-mapped half of the same distinction 0x04 to 0x07 draw for plain
# samples.  They are driven here because they were not: this library refuses all four, the reference
# reads all four, and nothing in the sweep asked, so the gap was invisible rather than recorded.
formats="header 0x00 0x01 0x02 0x03 0x11 0x12 0x13 0x21 0x23 0x04 0x05 0x06 0x07 0x25
0x02:bg 0x12:bg 0x00:bg 0x11:bg 0x02:bg0 0x12:bg0 0x08 0x08:bg 0x08:bg0 0x09
0x0a 0x0a:bg 0x0a:bg0 0x8a 0x0b 0x0b:bg 0x8b
0x0c 0x0d 0x0e 0x0f"

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

    case "$image" in damaged-*|bad-*) continue ;; esac

    for spec in $formats; do
        format=${spec%%:*}
        bg=""

        # A trailing marker asks for a background to blend coverage away against.  Both ways round are
        # driven, because they are different operations rather than the same one with a default.
        case "$spec" in
            *:bg) bg=bg ;;
            *:bg0) bg=bg0 ;;
        esac

        count=$((count + 1))

        if [ "$format" = header ]; then
            "$reference" "$path" > "$work/reference" 2>&1 || echo "exit $?" >> "$work/reference"
            "$ours" "$path" > "$work/ours" 2>&1 || echo "exit $?" >> "$work/ours"
        else
            "$reference" "$path" "$format" $bg > "$work/reference" 2>&1 \
                || echo "exit $?" >> "$work/reference"
            "$ours" "$path" "$format" $bg > "$work/ours" 2>&1 || echo "exit $?" >> "$work/ours"
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

        if [ -n "$known" ] && [ -f "$known" ] && grep -q "^$image $spec " "$known"; then
            exempt=$((exempt + 1))
            used="$used $image:$spec"
            continue
        fi

        failures=$((failures + 1))

        if [ "$failures" -le 4 ]; then
            echo "--- $image as $spec ---"
            diff "$work/reference" "$work/ours" | head -6
        else
            echo "--- $image as $spec differs ---"
        fi
    done
done

if [ "$count" -eq 0 ]; then
    echo "no images found in $corpus" >&2
    exit 2
fi

stale=0

if [ -n "$known" ] && [ -f "$known" ]; then
    while read -r image spec rest; do
        case "$image" in ''|\#*) continue ;; esac

        if [ "$image" = unimplemented ]; then
            if ! echo "$used" | grep -q " unimplemented"; then
                echo "stale exemption: nothing is refused as unimplemented any more" >&2
                stale=$((stale + 1))
            fi

            continue
        fi

        if ! echo "$used" | grep -q " $image:$spec"; then
            echo "stale exemption: $image $spec now matches the reference" >&2
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
