#!/usr/bin/env python3
"""fuzz_files.py - break corpus images in random ways and check both libraries agree

The error corpus is written by hand, so it holds the faults someone thought of.  This holds the ones
nobody did: a byte changed in the middle of a chunk, a length that no longer matches, a checksum that
no longer covers what follows it, a file that stops early or runs on.

What is compared is everything a client sees — the rows, the metadata, the warnings, and whether the
read failed at all.  A drop-in replacement has to agree about broken files as much as about whole
ones, and disagreeing about which files are broken is the most visible way to fail.

The seed is fixed, so a failure here is one anyone can reproduce by running the same command.  A file
that reads differently is kept, under a name saying which image it came from, so that the case can be
looked at on its own afterwards.

Not part of the suite yet, because it does not pass yet.  At the last run two hundred and six of two
hundred and forty broken files read the same way; of the rest, twenty four first part on an error line
and ten on a warning.  Each one it finds is a fault to fix or a difference to record rather than a
reason to loosen this, and it joins the suite when it is clean.

What it is pointing at next: a byte changed inside the image data.  The reference calls that a
checksum that does not match, and this library says the image was given more data than it needed —
both are true, and the question is which is noticed first.  The surplus is found here while the rows
are still being decompressed, and the chunk's checksum is not looked at until the chunk ends; the
reference reaches the checksum first.  Where exactly it does that is worth establishing by probing
before anything is moved, since the same remark is already known to be right on its own when the
checksum is sound.

usage: fuzz_files.py <ours> <reference> <corpus> [rounds]
"""

import collections
import pathlib
import random
import struct
import subprocess
import sys
import tempfile
import zlib


def chunks(data):
    """Walks a file's chunks, yielding (offset, length, name) for each."""
    offset = 8
    while offset + 8 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        name = data[offset + 4:offset + 8]
        yield offset, length, name
        offset += 12 + length
        if name == b"IEND":
            break


def mutate(data, rng):
    """One broken copy of a file, and what was done to it."""
    kind = rng.choice([
        "byte", "byte", "byte", "length", "checksum", "truncate", "extend", "name",
    ])
    out = bytearray(data)

    if kind == "byte":
        # Anywhere after the signature, since the signature has its own comparison.
        at = rng.randrange(8, len(out))
        out[at] ^= 1 << rng.randrange(8)
        return bytes(out), f"byte {at}"

    listed = list(chunks(data))

    if not listed:
        return bytes(out), "nothing to break"

    offset, length, name = rng.choice(listed)

    if kind == "length":
        # A length that disagrees with what follows it, which is the fault a reader has to survive
        # without reading past the end of the file.
        changed = max(0, length + rng.choice([-1, 1, -length, 0x10000]))
        out[offset:offset + 4] = struct.pack(">I", changed & 0xFFFFFFFF)
        return bytes(out), f"{name.decode('latin-1')} length {length} to {changed}"

    if kind == "checksum":
        at = offset + 8 + length
        if at + 4 <= len(out):
            out[at] ^= 0xFF
        return bytes(out), f"{name.decode('latin-1')} checksum"

    if kind == "name":
        # A chunk that becomes one nothing knows, or one that means something else.
        at = offset + 4
        out[at] ^= 0x20          # the case bit, which is what says whether a chunk may be ignored
        return bytes(out), f"{name.decode('latin-1')} case"

    if kind == "truncate":
        at = rng.randrange(8, len(out))
        return bytes(out[:at]), f"cut at {at}"

    # extend
    extra = bytes(rng.randrange(256) for _ in range(rng.randrange(1, 32)))
    return bytes(out) + extra, f"{len(extra)} bytes added"


def differing_line(theirs, mine, text):
    """The first line where the two answers part company, from whichever is being shown."""
    left, right = theirs.splitlines(), mine.splitlines()
    lines = text.splitlines()

    for index in range(max(len(left), len(right))):
        a = left[index] if index < len(left) else "<nothing>"
        b = right[index] if index < len(right) else "<nothing>"

        if a != b:
            return lines[index] if index < len(lines) else "<nothing>"

    return "<the same>"


def first_difference(theirs, mine):
    """A short name for what kind of difference this is, so the tail can be counted by kind."""
    line = differing_line(theirs, mine, theirs)

    for word in ("error", "warning", "exit", "row", "ihdr", "geometry"):
        if line.startswith(word):
            return word

    return line.split()[0] if line.split() else "empty"


def run(program, path, mode):
    try:
        finished = subprocess.run(
            [program, str(path), mode],
            capture_output=True, timeout=20,
        )
    except subprocess.TimeoutExpired:
        return "timed out"

    return finished.stdout.decode("latin-1") + finished.stderr.decode("latin-1") \
        + f"\nexit {finished.returncode}\n"


def main():
    if len(sys.argv) < 4:
        sys.exit("usage: fuzz_files.py <ours> <reference> <corpus> [rounds]")

    ours, reference, corpus = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
    rounds = int(sys.argv[4]) if len(sys.argv) > 4 else 400

    rng = random.Random(20240607)
    sources = sorted(p for p in corpus.glob("*.png"))

    if not sources:
        sys.exit(f"no images in {corpus}")

    differed = 0
    checked = 0
    kinds = collections.Counter()

    with tempfile.TemporaryDirectory() as work:
        broken = pathlib.Path(work) / "broken.png"

        for round_number in range(rounds):
            source = sources[round_number % len(sources)]
            data, description = mutate(source.read_bytes(), rng)
            broken.write_bytes(data)

            for mode in ("rows", "image"):
                checked += 1
                theirs = run(reference, broken, mode)
                mine = run(ours, broken, mode)

                if theirs == mine:
                    continue

                differed += 1

                kinds[first_difference(theirs, mine)] += 1

                if differed <= 4:
                    print(f"--- {source.name}, {description}, read by {mode} ---")

                    for side, text in (("reference", theirs), ("ours", mine)):
                        line = differing_line(theirs, mine, text)
                        print(f"    {side:9s} {line}")

                    keep = pathlib.Path(f"fuzz-{source.name}")
                    keep.write_bytes(data)
                    print(f"    kept as {keep}")

    print(f"{checked - differed}/{checked} broken files read the same way")

    for kind, count in kinds.most_common():
        print(f"    {count:4d} first differ on a line beginning {kind!r}")

    return 1 if differed else 0


if __name__ == "__main__":
    sys.exit(main())
