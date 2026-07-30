#!/usr/bin/env python3
"""Write the test corpus.

The images are generated rather than downloaded so that the suite has no network
dependency and so that the awkward cases are covered on purpose: sizes that make a
row end mid-byte, images narrower than a filter's reach, and each filter type
forced individually so that none of the five reconstruction paths goes untested.

Only the PNG writer here is trusted, and only to produce well-formed input; what
the two libraries make of it is what the comparison judges.
"""

import pathlib
import struct
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

SIGNATURE = b"\x89PNG\r\n\x1a\n"

GRAYSCALE = 0
RGB = 2
PALETTE = 3
GRAYSCALE_ALPHA = 4
RGBA = 6

CHANNELS = {GRAYSCALE: 1, RGB: 3, PALETTE: 1, GRAYSCALE_ALPHA: 2, RGBA: 4}


def chunk(name: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + name
        + payload
        + struct.pack(">I", zlib.crc32(name + payload) & 0xFFFF_FFFF)
    )


def paeth(left: int, above: int, above_left: int) -> int:
    estimate = left + above - above_left
    distances = (
        (abs(estimate - left), left),
        (abs(estimate - above), above),
        (abs(estimate - above_left), above_left),
    )
    # Ties resolve towards `left`, then `above`, which min() preserves because the
    # candidates are already in that order.
    return min(distances, key=lambda pair: pair[0])[1]


def filter_row(kind: int, row: bytes, previous: bytes, stride: int) -> bytes:
    out = bytearray(len(row))

    for index, value in enumerate(row):
        left = row[index - stride] if index >= stride else 0
        above = previous[index]
        above_left = previous[index - stride] if index >= stride else 0

        if kind == 0:
            prediction = 0
        elif kind == 1:
            prediction = left
        elif kind == 2:
            prediction = above
        elif kind == 3:
            prediction = (left + above) // 2
        else:
            prediction = paeth(left, above, above_left)

        out[index] = (value - prediction) & 0xFF

    return bytes(out)


def encode(
    path: pathlib.Path,
    width: int,
    height: int,
    bit_depth: int,
    color_type: int,
    rows: list[bytes],
    filter_kind: int,
    palette: bytes | None = None,
    before: bytes = b"",
    after_palette: bytes = b"",
    after: bytes = b"",
) -> None:
    """Writes one image, forcing every scanline to use `filter_kind`.

    `before` and `after` carry metadata chunks placed either side of the image data, since
    the format allows both and a decoder has to report either.  `after_palette` is for the
    chunks that refer into the palette and are only valid once it has been given.
    """
    stride = max(1, (CHANNELS[color_type] * bit_depth) // 8)
    row_bytes = (width * CHANNELS[color_type] * bit_depth + 7) // 8

    raw = bytearray()
    previous = bytes(row_bytes)

    for row in rows:
        assert len(row) == row_bytes, (len(row), row_bytes)
        raw.append(filter_kind)
        raw += filter_row(filter_kind, row, previous, stride)
        previous = row

    body = SIGNATURE
    body += chunk(
        b"IHDR",
        struct.pack(">IIBBBBB", width, height, bit_depth, color_type, 0, 0, 0),
    )

    body += before

    if palette is not None:
        body += chunk(b"PLTE", palette)

    body += after_palette
    body += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    body += after
    body += chunk(b"IEND", b"")

    path.write_bytes(body)


def sample_rows(width: int, height: int, channels: int, bit_depth: int) -> list[bytes]:
    """Values that vary along both axes and across channels.

    Anything constant would hide a defiltering mistake, since a wrong prediction
    added to a constant row often still gives the constant back.
    """
    row_bytes = (width * channels * bit_depth + 7) // 8
    rows = []

    for y in range(height):
        row = bytearray(row_bytes)
        for index in range(row_bytes):
            row[index] = (index * 37 + y * 91 + (index & 3) * 13) & 0xFF
        rows.append(bytes(row))

    return rows


def icc_profile() -> bytes:
    """A well-formed, empty colour profile.

    The reference checks a profile well past its length — the signature, the version, the
    device and connection spaces, the rendering intent, the tag count — and reports each
    fault it finds. So a payload of arbitrary bytes is rejected, and the happy path can
    only be tested with a header that is actually valid.

    It carries two tags, and that number is not arbitrary: the reference refuses a profile
    with fewer, whatever its size, so one tag reads as "too short" and two does not.
    """
    tags = [b"wtpt", b"rXYZ"]
    tag_data_offset = 132 + 12 * len(tags)
    tag_data = b"XYZ " + bytes(4) + struct.pack(">iii", 0x0000_F6D6, 0x0001_0000,
                                                0x0000_D32D)
    total = tag_data_offset + len(tag_data) * len(tags)

    header = bytearray(total)

    def put32(offset: int, value: int) -> None:
        header[offset:offset + 4] = struct.pack(">I", value)

    def sig(offset: int, text: bytes) -> None:
        header[offset:offset + 4] = text

    put32(0, total)           # the profile's own size
    sig(4, b"none")           # preferred colour management module
    put32(8, 0x0210_0000)     # version 2.1
    sig(12, b"mntr")          # device class: a display
    sig(16, b"RGB ")          # data colour space
    sig(20, b"XYZ ")          # profile connection space
    header[24:36] = struct.pack(">HHHHHH", 2026, 7, 29, 12, 0, 0)
    sig(36, b"acsp")          # the signature that marks this a profile at all
    sig(40, b"APPL")          # primary platform
    put32(64, 0)              # rendering intent: perceptual
    # The connection space illuminant, which is fixed for this profile version.
    header[68:80] = struct.pack(">iii", 0x0000_F6D6, 0x0001_0000, 0x0000_D32D)
    put32(128, len(tags))

    # The tag table: per tag, a signature, where its data sits, and how long it is.
    for index, name in enumerate(tags):
        entry = 132 + 12 * index
        offset = tag_data_offset + len(tag_data) * index

        sig(entry, name)
        put32(entry + 4, offset)
        put32(entry + 8, len(tag_data))
        header[offset:offset + len(tag_data)] = tag_data

    return bytes(header)


def write_metadata() -> list[pathlib.Path]:
    """Writes images carrying the optional chunks.

    One image per chunk, so that a disagreement points at a single chunk rather than at a
    file with twenty of them; then one carrying all of them at once, because chunks
    interact — the transparency table's length depends on the palette, and the significant
    bits depend on the colour type.
    """
    written = []

    def emit(name: str, **kwargs) -> None:
        path = CORPUS / f"meta-{name}.png"
        rows = sample_rows(6, 3, CHANNELS[kwargs.pop("color_type", RGB)], 8)
        encode(path, 6, 3, 8, kwargs.pop("ct", RGB), rows, 0, **kwargs)
        written.append(path)

    gama = chunk(b"gAMA", struct.pack(">I", 45455))
    chrm = chunk(b"cHRM", struct.pack(">8I", 31270, 32900, 64000, 33000, 30000, 60000,
                                     15000, 6000))
    srgb = chunk(b"sRGB", bytes([1]))
    sbit_rgb = chunk(b"sBIT", bytes([5, 6, 5]))
    phys = chunk(b"pHYs", struct.pack(">IIB", 3937, 3937, 1))
    phys_unspecified = chunk(b"pHYs", struct.pack(">IIB", 4, 9, 0))
    offs = chunk(b"oFFs", struct.pack(">iiB", -12, 34, 0))
    offs_microns = chunk(b"oFFs", struct.pack(">iiB", 1000, 2000, 1))
    time_ = chunk(b"tIME", struct.pack(">HBBBBB", 2026, 7, 29, 13, 45, 7))
    scal = chunk(b"sCAL", bytes([1]) + b"2.5" + b"\x00" + b"1.25")
    cicp = chunk(b"cICP", bytes([9, 16, 0, 1]))
    clli = chunk(b"cLLI", struct.pack(">II", 10_000_000, 4_000_000))
    mdcv = chunk(b"mDCV", struct.pack(">8HII", 17000, 8000, 34000, 16000, 13250, 34500,
                                     15635, 16450, 10_000_000, 5))
    exif = chunk(b"eXIf", b"MM\x00*\x00\x00\x00\x08")
    profile_body = icc_profile()
    profile = chunk(b"iCCP", b"a profile" + b"\x00" + b"\x00"
                    + zlib.compress(profile_body, 6))

    emit("gama", before=gama)
    emit("chrm", before=chrm)
    emit("srgb", before=srgb)
    emit("sbit", before=sbit_rgb)
    emit("phys", before=phys)
    emit("phys-unspecified", before=phys_unspecified)
    emit("offs", before=offs)
    emit("offs-microns", before=offs_microns)
    emit("time", before=time_)
    emit("scal", before=scal)
    emit("cicp", before=cicp)
    emit("clli", before=clli)
    emit("mdcv", before=mdcv)
    emit("exif", before=exif)
    emit("iccp", before=profile)

    # Metadata after the image data as well as before it.
    emit("trailing", after=time_ + exif)
    emit("both-sides", before=gama + chrm, after=time_)

    # All of them at once, to catch an interaction between chunks.
    emit("everything",
         before=gama + chrm + srgb + sbit_rgb + phys + offs + scal + cicp + clli + mdcv,
         after=time_ + exif)

    # Greyscale, whose significant bits and transparent colour have one channel rather
    # than three.
    gray_rows = sample_rows(6, 3, 1, 8)
    path = CORPUS / "meta-gray-sbit-trns.png"
    encode(path, 6, 3, 8, GRAYSCALE, gray_rows, 0,
           before=chunk(b"sBIT", bytes([4]))
                  + chunk(b"tRNS", struct.pack(">H", 128))
                  + chunk(b"bKGD", struct.pack(">H", 200)))
    written.append(path)

    # Colour, whose transparent colour and background have three channels.
    rgb_rows = sample_rows(6, 3, 3, 8)
    path = CORPUS / "meta-rgb-trns-bkgd.png"
    encode(path, 6, 3, 8, RGB, rgb_rows, 0,
           before=chunk(b"tRNS", struct.pack(">HHH", 10, 20, 30))
                  + chunk(b"bKGD", struct.pack(">HHH", 100, 200, 30)))
    written.append(path)

    # Indexed, where the transparency table and the histogram are sized by the palette.
    palette = b"".join(
        bytes(((i * 17) & 0xFF, (i * 31) & 0xFF, (i * 7) & 0xFF)) for i in range(6)
    )
    indexed_rows = [bytes((x + y) % 6 for x in range(6)) for y in range(3)]
    path = CORPUS / "meta-palette-trns-hist-bkgd.png"
    encode(path, 6, 3, 8, PALETTE, indexed_rows, 0, palette=palette,
           after_palette=chunk(b"tRNS", bytes([0, 64, 128, 255]))
                         + chunk(b"bKGD", bytes([3])))
    written.append(path)

    # The histogram on its own.  Listed in the known-differences file: the reference build
    # refuses this chunk wherever it is placed, so it cannot be compared against.
    path = CORPUS / "meta-palette-hist.png"
    encode(path, 6, 3, 8, PALETTE, indexed_rows, 0, palette=palette,
           after_palette=chunk(b"hIST", struct.pack(">6H", 9, 8, 7, 6, 5, 4)))
    written.append(path)

    # An indexed image's significant bits describe the palette's channels, not its index.
    path = CORPUS / "meta-palette-sbit.png"
    encode(path, 6, 3, 8, PALETTE, indexed_rows, 0, palette=palette,
           before=chunk(b"sBIT", bytes([5, 6, 5])))
    written.append(path)

    # Sixteen bit samples, where every background value is in range and the unmentioned
    # alpha precision defaults to a different number.
    deep_rows = sample_rows(6, 3, 3, 16)
    path = CORPUS / "meta-rgb16-sbit-bkgd.png"
    encode(path, 6, 3, 16, RGB, deep_rows, 0,
           before=chunk(b"sBIT", bytes([10, 11, 12]))
                  + chunk(b"bKGD", struct.pack(">HHH", 40000, 50000, 60000)))
    written.append(path)

    # An alpha channel, so the precision comes from the chunk rather than the default.
    rgba_rows = sample_rows(6, 3, 4, 8)
    path = CORPUS / "meta-rgba-sbit.png"
    encode(path, 6, 3, 8, RGBA, rgba_rows, 0, before=chunk(b"sBIT", bytes([5, 6, 7, 4])))
    written.append(path)

    # An unrecognised chunk, which has to be stepped over without disturbing anything.
    path = CORPUS / "meta-unknown-chunk.png"
    encode(path, 6, 3, 8, RGB, sample_rows(6, 3, 3, 8), 0,
           before=chunk(b"prVt", b"private payload") + gama)
    written.append(path)

    return written


def write_damaged() -> list[pathlib.Path]:
    """Writes files that a decoder has to reject.

    Agreeing about which files are bad, and saying the same thing about them, is as
    much a part of being a drop-in replacement as decoding the good ones.  These
    also exercise the path that matters most for memory: the client's error handler
    jumps out of a half-finished decode, and everything allocated so far still has
    to come back.
    """
    written = []
    rows = sample_rows(8, 4, CHANNELS[RGB], 8)

    def emit(name: str, body: bytes) -> None:
        path = CORPUS / f"bad-{name}.png"
        path.write_bytes(body)
        written.append(path)

    header = chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 4, 8, RGB, 0, 0, 0))

    raw = bytearray()
    previous = bytes(len(rows[0]))
    for row in rows:
        raw.append(0)
        raw += row
        previous = row
    data = zlib.compress(bytes(raw), 6)

    emit("signature", b"\x89PNX\r\n\x1a\n" + header)
    emit("empty", b"")
    emit("signature-only", SIGNATURE)

    # A header whose first chunk is not IHDR.
    emit("no-ihdr", SIGNATURE + chunk(b"IDAT", data))

    # Dimensions and encodings the format does not allow.
    emit("zero-width",
         SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 0, 4, 8, RGB, 0, 0, 0)))
    emit("zero-height",
         SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 0, 8, RGB, 0, 0, 0)))
    emit("bad-depth",
         SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 4, 3, RGB, 0, 0, 0)))
    emit("bad-color-type",
         SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 4, 8, 7, 0, 0, 0)))
    emit("depth-color-mismatch",
         SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 4, 1, RGB, 0, 0, 0)))
    emit("bad-compression",
         SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 4, 8, RGB, 1, 0, 0)))
    emit("bad-filter-method",
         SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 4, 8, RGB, 0, 1, 0)))
    emit("bad-interlace",
         SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 4, 8, RGB, 0, 0, 2)))

    # A checksum that does not match its payload.
    broken = bytearray(SIGNATURE + header)
    broken[-1] ^= 0xFF
    emit("ihdr-crc", bytes(broken))

    # No image data at all.
    emit("no-idat", SIGNATURE + header + chunk(b"IEND", b""))

    # Less image data than the dimensions call for.
    short = zlib.compress(bytes(raw)[: len(raw) // 3], 6)
    emit("short-idat", SIGNATURE + header + chunk(b"IDAT", short) + chunk(b"IEND", b""))

    # Image data that is not a valid compressed stream.
    emit("corrupt-zlib",
         SIGNATURE + header + chunk(b"IDAT", b"\x78\x9c" + b"\xff" * 32)
         + chunk(b"IEND", b""))

    # A scanline naming a filter that does not exist.
    bad_filter = bytearray()
    for row in rows:
        bad_filter.append(9)
        bad_filter += row
    emit("unknown-filter",
         SIGNATURE + header + chunk(b"IDAT", zlib.compress(bytes(bad_filter), 6))
         + chunk(b"IEND", b""))

    # A background the image's depth cannot express.
    gray_rows = sample_rows(8, 4, 1, 8)
    gray_header = chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 4, 8, GRAYSCALE, 0, 0, 0))
    gray_raw = b"".join(b"\x00" + row for row in gray_rows)
    emit("bkgd-out-of-range",
         SIGNATURE + gray_header + chunk(b"bKGD", struct.pack(">H", 900))
         + chunk(b"IDAT", zlib.compress(gray_raw, 6)) + chunk(b"IEND", b""))

    # A profile too short to hold its own header.
    emit("iccp-too-short",
         SIGNATURE + header
         + chunk(b"iCCP", b"n" + b"\x00\x00" + zlib.compress(b"short", 6))
         + chunk(b"IDAT", data) + chunk(b"IEND", b""))

    # Chunks that refer into a palette, placed before it.
    palette6 = b"".join(bytes(((i * 5) & 0xFF, i, i)) for i in range(6))
    indexed_header = chunk(b"IHDR", struct.pack(">IIBBBBB", 6, 3, 8, PALETTE, 0, 0, 0))
    indexed_raw = b"".join(
        b"\x00" + bytes((x + y) % 6 for x in range(6)) for y in range(3)
    )
    emit("trns-before-plte",
         SIGNATURE + indexed_header + chunk(b"tRNS", bytes([0, 64]))
         + chunk(b"PLTE", palette6)
         + chunk(b"IDAT", zlib.compress(indexed_raw, 6)) + chunk(b"IEND", b""))

    # Truncated part way through, at several points, since where the cut falls
    # decides which read fails.
    whole = SIGNATURE + header + chunk(b"IDAT", data) + chunk(b"IEND", b"")
    for fraction, label in ((0.25, "quarter"), (0.5, "half"), (0.9, "most")):
        emit(f"truncated-{label}", whole[: int(len(whole) * fraction)])

    return written


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: make_corpus.py <output-directory>")

    global CORPUS
    CORPUS = pathlib.Path(sys.argv[1])
    CORPUS.mkdir(parents=True, exist_ok=True)
    written = []

    # Every colour type this milestone decodes, at every filter, so none of the
    # five reconstruction paths is left untested.
    for color_type, name in ((GRAYSCALE, "gray"), (RGB, "rgb"), (RGBA, "rgba"),
                             (GRAYSCALE_ALPHA, "graya")):
        for filter_kind in range(5):
            width, height = 13, 7
            rows = sample_rows(width, height, CHANNELS[color_type], 8)
            path = CORPUS / f"{name}8-filter{filter_kind}.png"
            encode(path, width, height, 8, color_type, rows, filter_kind)
            written.append(path)

    # Sizes where the arithmetic is easiest to get wrong: a single pixel, a single
    # row, a single column, and a width narrower than a filter's reach.
    for width, height, label in ((1, 1, "1x1"), (1, 9, "1x9"), (9, 1, "9x1"),
                                 (2, 2, "2x2"), (17, 17, "17x17")):
        rows = sample_rows(width, height, CHANNELS[RGB], 8)
        path = CORPUS / f"rgb8-{label}.png"
        encode(path, width, height, 8, RGB, rows, 4)
        written.append(path)

    # Sixteen bit samples, where a filter steps back two bytes per channel.
    rows = sample_rows(11, 5, CHANNELS[RGB], 16)
    path = CORPUS / "rgb16-filter4.png"
    encode(path, 11, 5, 16, RGB, rows, 4)
    written.append(path)

    rows = sample_rows(11, 5, CHANNELS[GRAYSCALE], 16)
    path = CORPUS / "gray16-filter2.png"
    encode(path, 11, 5, 16, GRAYSCALE, rows, 2)
    written.append(path)

    # Depths below a byte, where a row ends part way through its last byte.  The
    # sample values deliberately set bits beyond the image width, so that whatever
    # the decoder does with them is visible.
    for bit_depth in (1, 2, 4):
        for width in (1, 3, 7, 13):
            rows = sample_rows(width, 5, 1, bit_depth)
            path = CORPUS / f"gray{bit_depth}-w{width}.png"
            encode(path, width, 5, bit_depth, GRAYSCALE, rows, 0)
            written.append(path)

    # The same, filtered.  These distinguish whether a decoder that discards the
    # bits past the width does so before or after the row becomes the reference for
    # the next one: with a filter that refers upwards, the two choices give
    # different pixels from the second row onwards.
    for bit_depth in (1, 2, 4):
        for filter_kind in (1, 2, 3, 4):
            width = 13
            rows = sample_rows(width, 5, 1, bit_depth)
            path = CORPUS / f"gray{bit_depth}-w13-filter{filter_kind}.png"
            encode(path, width, 5, bit_depth, GRAYSCALE, rows, filter_kind)
            written.append(path)

    # Indexed colour, whose rows are palette indices rather than samples.
    palette = b"".join(
        bytes(((index * 7) & 0xFF, (index * 13) & 0xFF, (index * 29) & 0xFF))
        for index in range(16)
    )
    for bit_depth in (1, 2, 4, 8):
        width = 9
        row_bytes = (width * bit_depth + 7) // 8
        rows = [
            bytes((index * 11 + y * 7) & 0xFF for index in range(row_bytes))
            for y in range(4)
        ]
        # Indices must exist in the palette, so the high bits are masked off for the
        # depth that can address more entries than the palette holds.
        if bit_depth == 8:
            rows = [bytes(value % 16 for value in row) for row in rows]
        path = CORPUS / f"palette{bit_depth}.png"
        encode(path, width, 4, bit_depth, PALETTE, rows, 0, palette=palette)
        written.append(path)

    written += write_metadata()
    written += write_damaged()

    print(f"wrote {len(written)} images to {CORPUS}")


if __name__ == "__main__":
    main()
