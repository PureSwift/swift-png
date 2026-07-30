#!/bin/sh
# compare_transforms.sh - decode with transforms applied, both libraries, and diff
#
# A client asks for transforms one call at a time and in whatever order suits it; the library
# applies them in a fixed order of its own.  Two things follow, and this checks both.
#
# The interesting defects are in the interactions rather than in a single transform, so the
# combinations matter more than the individual cases.  And the result must not depend on the order
# the requests arrived in, so several combinations appear twice with their requests reversed.
#
# Images are a representative subset rather than the whole corpus: the matrix is combinations times
# images times read modes, and the images that add anything here are the ones that differ in colour
# type or depth.
#
# A few cases are reported but not failed on, listed with their reasons in the known-differences
# file.  That file separates the reference's behaviour from this library's own gaps, and the
# separation is the point: a single list would let unfinished work look like a decision.
#
# usage: compare_transforms.sh <ours> <reference> <corpus> [known-differences-file]

set -e

ours="$1"
reference="$2"
corpus="$3"
known="$4"

if [ ! -x "$ours" ] || [ ! -x "$reference" ] || [ ! -d "$corpus" ]; then
    echo "compare_transforms.sh: usage: compare_transforms.sh <ours> <reference> <corpus>" >&2
    exit 2
fi

# One image per shape a transform can care about.
images="
gray1-w13.png
gray2-w13.png
gray4-w13.png
gray8-filter0.png
gray16-filter2.png
rgb8-filter0.png
rgb16-filter4.png
rgba16-filter1.png
rgba8-filter0.png
graya8-filter0.png
palette1.png
palette2.png
palette4.png
palette8.png
meta-rgb-trns-bkgd.png
meta-gray-sbit-trns.png
meta-palette-trns-hist-bkgd.png
meta-rgb16-sbit-bkgd.png
interlaced-rgb8-9x9.png
interlaced-rgba8-16x16.png
interlaced-gray2-9x9.png
interlaced-palette8-10x10.png
interlaced-rgb16-11x7.png
"

# Every transform on its own, then combinations, then combinations reordered.
combinations="
expand
palette_to_rgb
gray_1_2_4_to_8
trns_to_alpha
expand_16
strip_16
scale_16
strip_alpha
gray_to_rgb
packing
packswap
bgr
swap
swap_alpha
invert_alpha
invert_mono
filler
filler_before
add_alpha
shift
gamma_none
gamma_bright
gamma_dark
gamma_slight
gamma_steep
gamma_shallow
rgb_to_gray
rgb_to_gray_warn
rgb_to_gray_weighted
rgb_to_gray,expand
rgb_to_gray,strip_16
rgb_to_gray,gray_to_rgb
rgb_to_gray,gamma_bright
rgb_to_gray,packing
rgb_to_gray,add_alpha
background
background_black
background_white
background_file
background,expand
background,strip_16
background,gray_to_rgb
background,bgr
background,gamma_bright
background,rgb_to_gray
alpha_png
alpha_png_linear
alpha_premultiplied
alpha_premultiplied_linear
alpha_optimized
alpha_broken
alpha_premultiplied,expand
alpha_premultiplied,gray_to_rgb
alpha_premultiplied,strip_16
alpha_broken,bgr
alpha_optimized,expand
user_invert
user_widen
user_first_channel
user_invert,expand
user_invert,gray_to_rgb
user_invert,strip_16
user_invert,bgr
user_first_channel,expand
user_widen,gray_1_2_4_to_8
gamma_bright,user_invert
gamma_bright,expand
gamma_bright,gray_to_rgb
gamma_bright,strip_alpha
gamma_dark,expand_16
gamma_dark,strip_16
gamma_steep,packing
gamma_bright,bgr,add_alpha
expand,strip_16
expand,expand_16
expand,gray_to_rgb
expand,strip_alpha
expand,bgr
expand,swap_alpha
expand,invert_alpha
gray_to_rgb,bgr
gray_to_rgb,add_alpha
gray_1_2_4_to_8,gray_to_rgb
packing,packswap
packing,invert_mono
strip_16,gray_to_rgb
scale_16,expand
expand_16,swap
expand_16,strip_alpha
filler,bgr
add_alpha,swap_alpha
add_alpha,invert_alpha
shift,gray_to_rgb
shift,packing
trns_to_alpha,strip_alpha
expand,gray_to_rgb,strip_16
expand,strip_16,add_alpha,bgr
gray_1_2_4_to_8,packing,invert_mono
expand,expand_16,swap,swap_alpha
palette_to_rgb,strip_alpha,bgr,filler
"

# Deliberately absent: background with expand_16.  The background has to be given at the depth the
# blend happens at, and a client asking to widen to sixteen bits has to supply a sixteen bit
# background.  This harness supplies eight bit values, so that pairing would compare a client mistake
# rather than a library behaviour — and the reference's answer to a mistake is not a specification.

# The same requests in the opposite order.  The result has to be identical to the forward form, and
# comparing both against the reference is what proves it for the reference too rather than only for
# us.
reversed="
strip_16,expand
expand_16,expand
gray_to_rgb,expand
strip_alpha,expand
bgr,gray_to_rgb
add_alpha,gray_to_rgb
packswap,packing
invert_mono,packing
expand,rgb_to_gray
gray_to_rgb,rgb_to_gray
expand,background
gray_to_rgb,background
gamma_bright,background
expand,alpha_premultiplied
gray_to_rgb,alpha_premultiplied
expand,user_invert
bgr,user_invert
expand,gamma_bright
gray_to_rgb,gamma_bright
strip_16,gamma_dark
strip_16,gray_to_rgb,expand
bgr,add_alpha,strip_16,expand
invert_mono,packing,gray_1_2_4_to_8
swap_alpha,swap,expand_16,expand
filler,bgr,strip_alpha,palette_to_rgb
"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
exempt=0
count=0

: > "$work/used"

for image in $images; do
    [ -f "$corpus/$image" ] || continue

    for combination in $combinations $reversed; do
        for mode in rows image; do
            count=$((count + 1))

            "$reference" "$corpus/$image" "$mode" "$combination" > "$work/reference" 2>&1 \
                || echo "exit $?" >> "$work/reference"
            "$ours" "$corpus/$image" "$mode" "$combination" > "$work/ours" 2>&1 \
                || echo "exit $?" >> "$work/ours"

            if ! diff -q "$work/reference" "$work/ours" > /dev/null; then
                if [ -n "$known" ] && [ -f "$known" ] \
                    && grep -q "^$image $combination " "$known"; then
                    echo "$image $combination" >> "$work/used"
                    exempt=$((exempt + 1))
                    continue
                fi

                failures=$((failures + 1))

                # Only the first few are printed in full; a broken transform fails on every image
                # it touches and the rest of the output would bury the useful part.
                if [ "$failures" -le 6 ]; then
                    echo "--- $image [$mode] $combination ---"
                    diff "$work/reference" "$work/ours" | head -12
                else
                    echo "--- $image [$mode] $combination differs ---"
                fi
            fi
        done
    done
done

if [ "$count" -eq 0 ]; then
    echo "no images found in $corpus" >&2
    exit 2
fi

# An exemption that no longer applies is worse than no exemption: it sits in the file looking like a
# considered decision while silently covering whatever regresses into its place.  So the file has to
# earn every line it holds.
stale=0

if [ -n "$known" ] && [ -f "$known" ]; then
    while read -r image combination rest; do
        case "$image" in ''|\#*) continue ;; esac
        [ -n "$combination" ] || continue

        if ! grep -qx "$image $combination" "$work/used"; then
            echo "stale exemption: $image $combination now matches the reference" >&2
            stale=$((stale + 1))
        fi
    done < "$known"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures of $count transformed decodes differed" >&2
    exit 1
fi

if [ "$stale" -ne 0 ]; then
    echo "$stale recorded differences no longer differ; remove them from $(basename "$known")" >&2
    exit 1
fi

if [ "$exempt" -ne 0 ]; then
    echo "$((count - exempt)) transformed decodes matched the reference," \
        "$exempt differ as recorded"
else
    echo "$count transformed decodes matched the reference"
fi
