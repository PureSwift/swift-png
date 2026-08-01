# swift-png

An implementation of PNG in Swift, built to be usable two ways.

**`PNG`** is a Swift library with a Swift API and no C dependencies.

**`libpng16`** is the same engine behind libpng's published C API, built so that a
program compiled for libpng links or loads it without being changed or rebuilt.
That includes the details substitution actually depends on: the complete exported
symbol set and nothing beyond it, the versioned library name, and the Mach-O
compatibility version or ELF symbol version that the dynamic loader checks.

Status: every published function this build's configuration exports is implemented — 256 of
256, the same count `png.h` and the reference build agree on once the functions gated out by
this build's `pnglibconf.h` (`png_set_strip_error_numbers` among them, behind
`PNG_ERROR_NUMBERS_SUPPORTED`, which neither build turns on) are set aside; a raw text search
of the header that skips those guards overcounts. Both reading and writing work, sequentially
and interlaced, both ways a client can ask for an interlaced image; every colour type, every
bit depth from 1 to 16, every filter. The control
structure lifecycle, the allocator and stream callbacks, and every metadata chunk with its
accessors all work: the palette and transparency, the colour and gamma chunks, the embedded
profile, the physical layout, the timestamp, the camera metadata, the high dynamic range
signalling, and all three text chunks. Every read transform works — the expansions, the depth
conversions, the channel rearrangements, the filler, the shift, gamma correction, the conversion
to greyscale, compositing against a background, alpha mode, and quantisation.

What is left is the convenience `png_image_*` API's shortcuts for the transforms that change
light rather than arrangement — colour-mapped output, discarding alpha onto a buffer with no
background named, discarding colour, and converting to or from a linear encoding — and honouring
a transform argument passed to `png_write_png` rather than refusing anything but the identity.
Each of those refuses outright and says why, rather than producing an answer that is nearly
right; the general read and write API these shortcuts sit in front of has no such gap.

## Building

The Swift library and the test suites:

```bash
swift test
```

The installable C library, which needs the Ninja generator because that is one of
the two generators CMake can compile Swift with:

```bash
cmake --preset release && cmake --build build/release && ctest --test-dir build/release
```

Two build options matter. `SPNG_USE_SYSTEM_ZLIB` (on by default) compresses with
zlib, matching what the reference build links against; turning it off uses the
Swift implementation instead. `SPNG_STATIC_STDLIB` links the Swift runtime into
the library, which is worth doing on platforms that do not ship one.

## Platforms without a C library underneath

`PNG` and the `LZ77` module it compresses through have no dependency on zlib, libc, or an
operating system, and compile under Embedded Swift for targets that have none of the three:
WebAssembly, and bare-metal ARM. Building `PNG` for one of these disables the
`SystemZlib` trait (`swift build --disable-default-traits ...`), which switches DEFLATE and
INFLATE to the from-scratch, zlib-compatible codec in `LZ77` — the same code path exercised by
`swift test --disable-default-traits` on every hosted platform, so it is not only ever tested on
targets that are otherwise hard to test at all.

- **`wasm32-unknown-wasip1`** builds via `swift build --swift-sdk swift-6.3.3-RELEASE_wasm-embedded`
  and is run for real, not just compiled: `Sources/wasm-smoke-test` is an encode-then-decode round
  trip executed under Wasmtime in CI.
- **ARM bare metal** (`aarch64-none-none-elf`, `armv7em-none-none-eabi`, `armv6m-none-none-eabi`,
  `arm64-apple-none-macho`) builds via `scripts/build_embedded.sh <triple>`, which drives `swiftc`
  directly since these triples have no SwiftPM SDK bundle. `armv7em-none-none-eabi` is also run for
  real, as bootable firmware under an emulated Cortex-M4F — see `Firmware/QEMU`. `arm64-apple-none-macho`
  has the same boot-and-verify firmware for real Apple Silicon hardware, under `Hypervisor.framework`
  — see `Firmware/Hypervisor` — kept out of CI (its own README says why) and run locally instead.

All of this is what `.github/workflows/embedded.yml` checks on every push.

## How it is put together

```
CPNG        the published C API, and the parts that have to be C:
            error dispatch and the jump boundary, allocation, callbacks
  PNGABI    one @c function per published entry point
    PNG     the engine: chunks, row pipeline, transforms, compression
```

Two decisions shape everything else.

**The control structures are split.** `png_struct` is opaque in the published ABI,
so its layout is ours to choose. It holds only plain data that the error and
callback machinery touches, plus a pointer to a Swift object that owns the codec
state. That division exists because a client may `longjmp` out of any callback we
invoke, abandoning Swift frames without running their cleanups; keeping the jump
machinery's world free of managed references is what makes that survivable.

**The engine throws; only the boundary jumps.** Nothing below the exported entry
points calls `png_error`. Failures propagate as thrown Swift errors, every engine
frame unwinds normally, and the exported function transfers control to the
client's handler as the last thing it does.

## Correctness

The C API's behaviour is not something to infer from documentation. Every
expectation in the conformance suite is checked against the reference
implementation as well as against this one, by compiling the same program twice
and linking it against each library. An expectation that only holds for us is a bug
in the test, and this arrangement is what catches it.

It has already paid for itself several times over. The reference clears the unused
bits at the end of a row narrower than a whole number of bytes, but only in the copy
it hands the client, still reconstructing the next row from the bits as stored. It
reports a bad header as one warning per fault followed by a single generic error,
rather than failing at the first. It passes the decompressor's own wording through
rather than summarising it. None of that is written down anywhere; all of it is what
clients actually observe.

The transforms are where the reference is least guessable, because a client asks for them in any
order and the library applies them in a fixed order of its own. So the comparison drives
combinations rather than one transform at a time, and drives several of them twice with the requests
reversed — the result has to be identical, and checking that against the reference proves it for the
reference too rather than only for us. That is 2640 decodes over 22 images in both read modes.

Discarding colour is a weighted sum in integer arithmetic, and the two depths round it differently:
the eight bit path truncates and the sixteen bit path adds a half first. Nothing suggests that
asymmetry and it shows on almost every pixel, so it was found by arithmetic rather than by reading —
computing both candidates for one pixel and seeing which the reference agreed with.

Compositing an image over a background is the same shape of problem and taught the same lesson twice.
The background lives in two spaces at once: a fully transparent pixel becomes it as the display should
see it, and a partly covered one is blended against it as light. Which exponent reaches each depends on
the space the client said the colour was in, not on the image's own curve — using the image's exponent
for a colour that was never in the file's space is the mistake that took longest to find. An indexed
image is composited in its palette, once, and its rows left as indices; a request to composite an image
with nothing transparent in it is dropped entirely, and dropping it has to take the implied palette
expansion with it.

Averaging samples at all is only meaningful on light levels, and a file's samples are not light
levels: they carry the file's own curve. So when a gamma correction is in force the conversion decodes
each sample to linear, averages there, and re-encodes — and the correction then belongs to the
conversion rather than to the separate gamma step, which would otherwise apply it twice. Four
consequences of that fall out of the comparison rather than out of the design. The sum rounds on this
path where the plain sum truncates. A pixel that was already grey skips the round trip and takes the
combined correction directly, which is a different answer because the trip through eight bit linear
loses precision. An indexed image's palette is left uncorrected, since the conversion will correct it
as it averages. And asking for the conversion suppresses the gamma step even on a greyscale image
where the conversion does not run — so a client asking for both on such an image gets no gamma at all,
which is peculiar, but is what clients see.

Gamma is the one place where agreeing to the last bit is both the point and straightforwardly
reachable, because the reference build computes it in double precision rather than through its
fixed-point logarithm path — so the arithmetic is reproducible rather than a reimplementation of an
approximation. The comparison then found the parts that are not arithmetic at all: an indexed image is
corrected in its palette, once, and its rows expanded from the corrected entries, so correcting the
rows as well double-corrects them; the palette a client reads back afterwards is the corrected one;
and samples narrower than a byte are corrected without being widened, by repeating each sample across
a byte, looking it up in the eight bit table, and keeping the top bits.

Almost every rule it found was one that could not have been guessed. The shift moves samples *down*
rather than up: it recovers the narrower values an image was made from rather than filling the depth,
so five significant bits in eight means shifting right by three. Asking for colour from a greyscale
image implies widening it first, and asking either that or for low-depth greyscale to be widened also
expands a palette — but neither turns a transparent colour into an alpha channel, while any expansion
at all makes the library stop reporting the transparency. Adding a filler channel happens after the
alpha swap rather than before, so a filler alpha is never moved to the front. Palette entries a
transparency table does not mention are opaque. And the shift amounts are checked against the image's
own depth even for an indexed image, where the plausible reading — that the palette's eight bit
samples are what matter — is wrong.

Interlacing turned up a contract that is easy to get wrong. A client that reads an interlaced
image row by row calls `png_set_interlace_handling`, is told there are seven passes, and then
sweeps every row of the image seven times — so most of those calls fall on rows the current
pass does not carry, and those consume nothing from the stream. An image small enough to have
empty passes runs out of data before it runs out of sweeps: a single pixel is carried entirely
by the first pass, so six of its seven sweeps have nothing to do at all, and refusing them
would break the documented loop.

The metadata chunks turned up more of the same. The significant-bits chunk does not report
zero for the channels it does not carry: a greyscale value is mirrored into the colour
channels, and an image without an alpha channel reports its own bit depth as its alpha
precision. A palette longer than the bit depth can address is truncated silently rather
than refused. A background value the image's depth could not express is rejected outright
rather than clamped, and an indexed one is resolved through the palette before being
reported. An embedded colour profile is refused unless it describes at least two tags —
which is a count, not a size, as a thousand-byte profile with one tag is still refused.

The damaged-file half of the corpus is also what verifies the jump discipline, and it found
a real defect: a client jumping out of its error handler used to leave a Swift exclusivity
access open, so the next call trapped. Reading a byte through a `mutating` method on a
struct held in a class property takes an exclusive access for the whole call, including the
part that runs the client's callback — so the engine's mutable state is held by reference,
and buffers are replaced rather than mutated in place.

The comparison runs in both directions. Decoding a file exercises the getters but never the
setters, since a decoded file reaches the info structure through the parsers; so a second
program sets every field and reads it back, and is compiled against each library the same
way. That is what checks the conversions in the setters — the mastering display's
chromaticity is stored at one scale and published at another, and only a round trip shows
that the two halves agree.

Where the reference does something this library should not copy, the case is listed with its reason
and the comparison reports it without failing: `Conformance/known-differences.txt` for decoding, and
`Conformance/known-transform-differences.txt` for the transforms. The decoding file has one entry, a
chunk the reference build refuses to read wherever it appears. The transform file has two kinds of
entry and keeps them apart on purpose. On the reference's side, it accepts a filler channel it cannot
honour on sub-byte samples, reports a row shape that cannot exist, and then fails mid-decode. On this
library's side there are three gaps: reversing sub-byte samples within a byte is applied to an
interlaced pass row rather than to the full-width row it is spread into, sixteen bit gamma is computed
exactly where the reference deliberately uses a coarser table, and the weighted sum that discards colour
is taken on encoded samples rather than on linear light. Unfinished work is labelled as unfinished rather
than filed alongside a decision.

The comparison also refuses to carry a recorded difference that no longer differs. An exemption that
has stopped applying is worse than none at all, because it sits in the file looking considered while
silently covering whatever regresses into its place — so the file has to earn every line it holds.

## Licensing

This implementation is under the license in `LICENSE`. The public headers are
libpng's own, vendored unchanged because they define the ABI being implemented;
`LICENSE.libpng` covers those.
