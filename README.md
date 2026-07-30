# swift-png

An implementation of PNG in Swift, built to be usable two ways.

**`PNG`** is a Swift library with a Swift API and no C dependencies.

**`libpng16`** is the same engine behind libpng's published C API, built so that a
program compiled for libpng links or loads it without being changed or rebuilt.
That includes the details substitution actually depends on: the complete exported
symbol set and nothing beyond it, the versioned library name, and the Mach-O
compatibility version or ELF symbol version that the dynamic loader checks.

Status: the C surface is complete as a set of symbols, and the build, install and
conformance machinery is in place. Most functions currently report that they are
not implemented; they are being filled in against a differential test suite.

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
and linking it against each library. An expectation that only holds for us is a
bug in the test, and this arrangement is what catches it — already, on details
like the exact bytes `png_get_header_version` returns.

## Licensing

This implementation is under the license in `LICENSE`. The public headers are
libpng's own, vendored unchanged because they define the ABI being implemented;
`LICENSE.libpng` covers those.
