#!/bin/sh
# check_generated.sh - assert the committed generated sources are current
#
# The generated files are committed so that a checkout builds without Python and
# so that changes to the exported surface show up in review as a diff.  That only
# holds if they are regenerated whenever their inputs change, which is what this
# checks.
#
# It runs the generators against a copy of the tree, so the working tree is not
# touched whether it passes or fails.

set -e

root=$(cd "$(dirname "$0")/.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/scripts" "$work/Sources/CPNG/include" "$work/Sources/CPNG/gen"
cp "$root"/scripts/*.py "$root"/scripts/api.json "$root"/scripts/symbols.txt \
    "$root"/scripts/implemented.txt "$work/scripts/"
cp "$root"/Sources/CPNG/include/*.h "$work/Sources/CPNG/include/"

status=0

report() {
    echo "$1 is out of date; regenerate with: $2" >&2
    status=1
}

# api.json and symbols.txt must still describe the vendored header.
python3 "$work/scripts/gen_api.py" >/dev/null

if ! diff -q "$root/scripts/api.json" "$work/scripts/api.json" >/dev/null; then
    report "scripts/api.json" "python3 scripts/gen_api.py"
fi

if ! diff -q "$root/scripts/symbols.txt" "$work/scripts/symbols.txt" >/dev/null; then
    report "scripts/symbols.txt" "python3 scripts/gen_api.py"
fi

# The stub file must cover exactly the functions that are not implemented yet.
python3 "$work/scripts/gen_stubs.py" >/dev/null
if ! diff -q "$root/Sources/CPNG/gen/swift_stubs.c" \
        "$work/Sources/CPNG/gen/swift_stubs.c" >/dev/null; then
    report "Sources/CPNG/gen/swift_stubs.c" "python3 scripts/gen_stubs.py"
fi

if [ "$status" -eq 0 ]; then
    echo "generated sources are up to date"
fi

exit "$status"
