#!/usr/bin/env python3
"""fuzz_transforms.py - decode with randomly drawn transform sets, both libraries, and diff.

The fixed matrix next door checks the combinations someone thought of.  This checks the ones
nobody did: it draws a handful of transforms at random, in a random order, and compares.

Two properties are under test at once, and the second is the reason the order is drawn as well as
the set.  A client asks for transforms one call at a time and in whatever order suits it, and the
library applies them in a fixed order of its own — so the same set asked for in two orders must give
the same image, and both must agree with the reference.

The images are the fixed matrix's, and deliberately so.  What is unexplored here is combinations and
orders, not images: the listed images already cover every shape a transform can care about, and it
is against those names that the known differences are recorded.

The pool a case draws from is derived rather than written down.  Any transform named in a recorded
difference for an image is left out of that image's pool: those cases are already accounted for in
the known-differences file, and a random draw that happened to include one would report a
disagreement that has already been examined.  Everything else is fair game.

Two draws are left out.  Only one transform of the client's own can be installed at a time, so a draw
naming two of them would install one and leave the other's declared row shape behind — a harness
mistake rather than a library one.  And one pairing is left out for the reason the fixed matrix leaves
it out: a background has to be given
at the depth the blend happens at, and a harness that fills it in before the transforms are resolved
cannot know that a request to widen the samples is coming.  A draw containing both would compare a
client's mistake rather than a library's behaviour.

The seed is an argument and every failure prints its case, so a disagreement found here can be
reproduced exactly — by this script with the same seed, or by hand with the printed combination.

usage: fuzz_transforms.py <ours> <reference> <corpus> [seed] [iterations]
"""

import pathlib
import random
import subprocess
import sys


def transform_names(binary: str) -> list[str]:
    """The transforms the harness understands, asked of the harness itself.

    Asked rather than listed here, so that a transform added to the harness is drawn from without
    anyone having to remember this file.
    """
    result = subprocess.run([binary, "--transforms"], capture_output=True, text=True)

    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


# Names that are the same transform asked for with different parameters.
#
# A difference recorded against one of them is a difference recorded against all: they take the same
# path through the library and differ only in the numbers they carry.  Without this the random draw
# would keep rediscovering a recorded difference through a sibling name.
FAMILIES = [
    ("rgb_to_gray", "rgb_to_gray_warn", "rgb_to_gray_weighted"),
    ("alpha_png", "alpha_png_linear", "alpha_premultiplied", "alpha_premultiplied_linear",
     "alpha_optimized", "alpha_broken"),
    ("gamma_none", "gamma_bright", "gamma_dark", "gamma_slight", "gamma_steep", "gamma_shallow"),
    ("background", "background_black", "background_white", "background_file"),
    ("filler", "filler_before", "add_alpha"),
    ("user_invert", "user_widen", "user_first_channel"),
]


def relatives(name: str) -> set[str]:
    """Every name that stands or falls with this one."""
    for family in FAMILIES:
        if name in family:
            return set(family)

    return {name}


def recorded_differences(path: pathlib.Path) -> dict[str, set[str]]:
    """Which transforms are already known to differ, per image.

    The file records combinations; this takes them apart, because a combination that differs makes
    every transform in it suspect for that image.
    """
    excluded: dict[str, set[str]] = {}

    if not path.is_file():
        return excluded

    for line in path.read_text().splitlines():
        line = line.strip()

        if not line or line.startswith("#"):
            continue

        fields = line.split()

        if len(fields) < 2:
            continue

        image, combination = fields[0], fields[1]

        for name in combination.split(","):
            excluded.setdefault(image, set()).update(relatives(name))

    return excluded


def decode(binary: str, image: pathlib.Path, mode: str, combination: str) -> str:
    result = subprocess.run(
        [binary, str(image), mode, combination],
        capture_output=True,
        text=True,
    )

    return result.stdout + result.stderr + f"exit {result.returncode}\n"


def main() -> None:
    if len(sys.argv) < 4:
        sys.exit("usage: fuzz_transforms.py <ours> <reference> <corpus> [seed] [iterations]")

    ours, reference = sys.argv[1], sys.argv[2]
    corpus = pathlib.Path(sys.argv[3])
    seed = int(sys.argv[4]) if len(sys.argv) > 4 else 20260730
    iterations = int(sys.argv[5]) if len(sys.argv) > 5 else 400

    listing = pathlib.Path(__file__).resolve().parent.parent / "Conformance"
    images = [
        corpus / name
        for name in (
            line.split("#")[0].strip()
            for line in (listing / "transform-images.txt").read_text().splitlines()
        )
        if name and (corpus / name).is_file()
    ]

    if not images:
        sys.exit(f"none of the listed images are in {corpus}")

    names = transform_names(ours)

    if not names:
        sys.exit(f"{ours} listed no transforms")

    excluded = recorded_differences(listing / "known-transform-differences.txt")

    rng = random.Random(seed)
    failures = 0
    skipped = 0

    for case in range(iterations):
        image = rng.choice(images)
        pool = [name for name in names if name not in excluded.get(image.name, set())]

        if not pool:
            skipped += 1
            continue

        drawn = rng.sample(pool, min(rng.randint(1, 4), len(pool)))

        # See above.
        if "expand_16" in drawn and any(name.startswith("background") for name in drawn):
            skipped += 1
            continue

        if sum(1 for name in drawn if name.startswith("user_")) > 1:
            skipped += 1
            continue

        combination = ",".join(drawn)
        mode = rng.choice(["rows", "image"])

        if decode(reference, image, mode, combination) == decode(ours, image, mode, combination):
            continue

        failures += 1

        if failures <= 6:
            print(f"--- {image.name} [{mode}] {combination} differs ---", file=sys.stderr)
            print(f"    reproduce: pngdump {image} {mode} {combination}", file=sys.stderr)
        elif failures == 7:
            print("--- further differences not printed ---", file=sys.stderr)

    if failures:
        print(
            f"{failures} of {iterations} random transform sets differed (seed {seed})",
            file=sys.stderr,
        )
        sys.exit(1)

    print(
        f"{iterations - skipped} random transform sets matched the reference (seed {seed})"
        + (f", {skipped} images had nothing left to draw from" if skipped else "")
    )


if __name__ == "__main__":
    main()
