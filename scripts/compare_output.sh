#!/bin/sh
# compare_output.sh - run one program built against each library and diff what they print
#
# For checks that take no input file: the program itself is the case, and the comparison is
# between the two libraries' answers to it.
#
# A known-differences file may be given.  Each line names a word that identifies a differing line and
# says why it differs; a difference on a line carrying that word is reported and not failed on, and a
# recorded word that no longer matches anything fails the build, so the file cannot go stale.
#
# usage: compare_output.sh <ours> <reference> [known-differences-file]

set -e

ours="$1"
reference="$2"
known="$3"

if [ ! -x "$ours" ] || [ ! -x "$reference" ]; then
    echo "compare_output.sh: usage: compare_output.sh <ours> <reference>" >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Exit statuses are compared too: agreeing on the output but disagreeing on whether the
# program succeeded is still a difference.
"$reference" > "$work/reference" 2>&1 || echo "exit $?" >> "$work/reference"
"$ours" > "$work/ours" 2>&1 || echo "exit $?" >> "$work/ours"

if diff -q "$work/reference" "$work/ours" > /dev/null; then
    echo "$(basename "$ours") matches the reference"
    exit 0
fi

if [ -z "$known" ] || [ ! -f "$known" ]; then
    diff -u "$work/reference" "$work/ours"
    echo "$(basename "$ours") behaves differently from the reference" >&2
    exit 1
fi

# Every differing line has to be one the file accounts for.
diff "$work/reference" "$work/ours" | grep '^[<>]' > "$work/differing" || true

failures=0
used=""

while IFS= read -r line; do
    matched=""

    while read -r word rest; do
        case "$word" in ''|\#*) continue ;; esac

        case "$line" in
            *"$word"*) matched=$word; used="$used $word" ;;
        esac
    done < "$known"

    if [ -z "$matched" ]; then
        failures=$((failures + 1))

        if [ "$failures" -le 6 ]; then
            echo "$line"
        fi
    fi
done < "$work/differing"

stale=0

while read -r word rest; do
    case "$word" in ''|\#*) continue ;; esac

    if ! echo "$used" | grep -q " $word"; then
        echo "stale exemption: $word no longer differs" >&2
        stale=$((stale + 1))
    fi
done < "$known"

if [ "$failures" -ne 0 ]; then
    echo "$(basename "$ours") behaves differently from the reference" >&2
    exit 1
fi

if [ "$stale" -ne 0 ]; then
    echo "$stale recorded differences no longer differ; remove them from $(basename "$known")" >&2
    exit 1
fi

echo "$(basename "$ours") matches the reference except where recorded"
