#!/bin/sh
# compare_bench.sh - time both libraries over the same images and print the two side by side
#
# Not a test.  Nothing here can fail the build, because a timing that varies with what else the
# machine is doing is not something to gate on — what it is for is telling whether a change made
# things faster or slower, and by how much.
#
# The two are run alternately rather than one after the other, so that a machine that warms up or
# throttles part way through affects both equally.
#
# usage: compare_bench.sh <ours> <reference> <corpus> [rounds]

set -e

ours="$1"
reference="$2"
corpus="$3"
rounds="${4:-20}"

if [ ! -x "$ours" ] || [ ! -x "$reference" ] || [ ! -d "$corpus" ]; then
    echo "compare_bench.sh: usage: compare_bench.sh <ours> <reference> <corpus> [rounds]" >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The corpus is made of awkward little images, which is right for comparing behaviour and useless for
# comparing speed: at thirteen pixels across, what is timed is setting up rather than working.  So a
# few large ones are made here, and they are what the totals are mostly about.
python3 - "$work" <<'MAKE'
import pathlib, struct, sys, zlib

def chunk(name, payload):
    return struct.pack(">I", len(payload)) + name + payload + struct.pack(
        ">I", zlib.crc32(name + payload) & 0xFFFFFFFF)

def write(path, width, height, colour, channels, noisy):
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            # Two kinds of picture, because they compress and filter quite differently: a smooth
            # gradient is what a photograph looks like to a filter, and noise is the worst case.
            if noisy:
                value = (x * 2654435761 + y * 40503) & 0xFF
            else:
                value = (x + y) & 0xFF
            row += bytes([value, (value * 3) & 0xFF, (value * 7) & 0xFF, 0xFF][:channels])
        rows.append(bytes(row))

    raw = b"".join(b"\x00" + r for r in rows)
    body = b"\x89PNG\r\n\x1a\x0a".replace(b"\x0a", b"\n")
    body = b"\x89PNG\r\n\x1a\n"
    body += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, colour, 0, 0, 0))
    body += chunk(b"IDAT", zlib.compress(raw, 6))
    body += chunk(b"IEND", b"")
    pathlib.Path(path).write_bytes(body)

out = pathlib.Path(sys.argv[1])
write(out / "large-rgb-smooth.png", 512, 512, 2, 3, False)
write(out / "large-rgb-noisy.png", 512, 512, 2, 3, True)
write(out / "large-rgba-smooth.png", 512, 512, 6, 4, False)
write(out / "large-gray-smooth.png", 512, 512, 0, 1, False)
MAKE

printf '%-34s %19s %19s %19s\n' "" "decode" "decode+transforms" "encode"
printf '%-34s %8s %8s  %8s %8s  %8s %8s\n' "image" "theirs" "ours" "theirs" "ours" "theirs" "ours"

total_theirs=0
total_ours=0

for path in "$work"/large-*.png "$corpus"/*.png; do
    image=$(basename "$path")

    # The damaged ones are not worth timing: what they measure is how quickly each library gives up.
    case "$image" in bad-*|damaged-*|over-*) continue ;; esac

    "$reference" "$path" "$rounds" > "$work/theirs" 2>/dev/null || continue
    "$ours" "$path" "$rounds" > "$work/ours" 2>/dev/null || continue

    grep -q unreadable "$work/theirs" && continue
    grep -q unreadable "$work/ours" && continue

    set -- $(cat "$work/theirs")
    theirs_decode=$4; theirs_transformed=$6; theirs_encode=$8
    set -- $(cat "$work/ours")
    ours_decode=$4; ours_transformed=$6; ours_encode=$8

    printf '%-34s %8s %8s  %8s %8s  %8s %8s\n' "$image" \
        "$theirs_decode" "$ours_decode" \
        "$theirs_transformed" "$ours_transformed" \
        "$theirs_encode" "$ours_encode"

    total_theirs=$(echo "$total_theirs $theirs_decode $theirs_transformed $theirs_encode" \
        | awk '{ print $1 + $2 + $3 + $4 }')
    total_ours=$(echo "$total_ours $ours_decode $ours_transformed $ours_encode" \
        | awk '{ print $1 + $2 + $3 + $4 }')
done

echo
echo "$total_theirs $total_ours" | awk '{
    printf "everything added up: reference %.3f ms, this library %.3f ms", $1, $2
    if ($1 > 0) printf ", which is %.2f times", $2 / $1
    printf "\n"
}'
