#!/bin/sh
# run_faults.sh - abandon every corpus image's decode at every point, and check nothing is lost
#
# The program does the work; this exists to hand it the corpus and to fail the build on its exit
# status, since ctest needs a command rather than a glob.
#
# usage: run_faults.sh <pngfaults> <corpus>

set -e

faults="$1"
corpus="$2"

if [ ! -x "$faults" ] || [ ! -d "$corpus" ]; then
    echo "run_faults.sh: usage: run_faults.sh <pngfaults> <corpus>" >&2
    exit 2
fi

"$faults" "$corpus"/*.png
