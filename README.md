# swift-png

An implementation of PNG in Swift, built to be usable two ways.

**`PNG`** is a Swift library with a Swift API and no C dependencies.

**`libpng16`** is the same engine behind libpng's published C API, built so that a
program compiled for libpng links or loads it without being changed or rebuilt.
That includes the details substitution actually depends on: the complete exported
symbol set and nothing beyond it, the versioned library name, and the Mach-O
compatibility version or ELF symbol version that the dynamic loader checks.

Status: 129 of the 256 published functions are implemented, and the rest report that they
are not rather than answering wrongly. What works today is reading a non-interlaced image
sequentially — every colour type, every bit depth from 1 to 16, every filter — along with
the control structure lifecycle, the allocator and stream callbacks, and every metadata
chunk with its accessors: the palette and transparency, the colour and gamma chunks, the
embedded profile, the physical layout, the timestamp, the camera metadata, the high dynamic
range signalling, and all three text chunks. Interlaced images decode too, both ways a client can
ask for them, and twenty of the read transforms work — the expansions, the depth conversions, the
channel rearrangements, the filler and the shift. Gamma, compositing and the remaining transforms
are still to come, as is writing.

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

## How it is put together

```
CPNG          the published C API, and the parts that have to be C:
              error dispatch and the jump boundary, allocation, callbacks
  PNGABI      one @c function per published entry point
    PNGCore   the engine: chunks, row pipeline, transforms, compression
      PNG     the Swift API
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
entry and keeps them apart on purpose — the reference accepting a filler it cannot honour and then
failing mid-decode, and one gap of this library's own, where reversing sub-byte samples within a byte
is applied to an interlaced pass row rather than to the full-width row it is spread into. Unfinished
work is labelled as unfinished rather than filed alongside a decision.

## Licensing

This implementation is under the license in `LICENSE`. The public headers are
libpng's own, vendored unchanged because they define the ABI being implemented;
`LICENSE.libpng` covers those.
