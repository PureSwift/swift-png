#!/bin/sh
# compare_output.sh - run one program built against each library and diff what they print
#
# For checks that take no input file: the program itself is the case, and the comparison is
# between the two libraries' answers to it.
#
# usage: compare_output.sh <ours> <reference>

set -e

ours="$1"
reference="$2"

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

if ! diff -u "$work/reference" "$work/ours"; then
    echo "$(basename "$ours") behaves differently from the reference" >&2
    exit 1
fi

echo "$(basename "$ours") matches the reference"
