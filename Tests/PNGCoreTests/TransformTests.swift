import Testing

@testable import PNGCore

/// These check two things the differential comparison cannot check directly.
///
/// That the shape `png_read_update_info` promises is the shape the pipeline actually produces —
/// the promise is made before any row is read, from a separate walk over the same step list, and a
/// disagreement would have a client allocate the wrong amount. And that the order the client asked
/// in never reaches the result.
@Suite("Transform pipeline")
struct TransformTests {
    private func header(
        width: Int = 8,
        depth: UInt8 = 8,
        colorType: UInt8 = 2,
        interlaced: Bool = false
    ) -> Header {
        Header(
            Header.Fields(
                width: UInt32(width),
                height: 4,
                bitDepth: depth,
                colorType: colorType,
                compressionMethod: 0,
                filterMethod: 0,
                interlaceMethod: interlaced ? 1 : 0
            )
        )
    }

    private func store(_ header: Header, transparency: Bool = false) -> InfoStore {
        let store = InfoStore(host: MetadataTests.makeHost(reportingTo: MetadataTests.Ledger()))
        store.header = header

        if transparency {
            store.markValid(InfoStore.Valid.trns)
        }

        return store
    }

    private func program(
        _ flags: TransformFlags,
        _ header: Header,
        transparency: Bool = false
    ) -> TransformProgram {
        TransformProgram(
            flags: flags,
            header: header,
            info: self.store(header, transparency: transparency),
            fillerValue: 0x8080,
            fillerAfterColor: true
        )
    }

    /// Runs the pipeline over a row of the given shape and reports the shape it came out with.
    private func run(
        _ program: TransformProgram,
        from start: RowInfo,
        capacity: Int,
        inputs: TransformInputs = TransformInputs()
    ) -> RowInfo {
        var shape = start
        var bytes = [UInt8](repeating: 0x5A, count: capacity)

        bytes.withUnsafeMutableBufferPointer { row in
            program.apply(to: row, info: &shape, inputs: inputs)
        }

        return shape
    }

    /// The promise and the result are computed by different code — one walks the steps over a shape,
    /// the other over bytes — so agreeing is a real check rather than a tautology.
    @Test("Promises the shape it produces")
    func promiseMatchesResult() {
        let cases: [(TransformFlags, UInt8, UInt8)] = [
            ([.strip16], 16, 2),
            ([.scale16], 16, 2),
            ([.expand16], 8, 2),
            ([.grayToRgb], 8, 0),
            ([.grayToRgb], 16, 0),
            ([.stripAlpha], 8, 6),
            ([.stripAlpha], 16, 4),
            ([.packing], 4, 0),
            ([.packing], 1, 0),
            ([.filler], 8, 2),
            ([.addAlpha], 8, 0),
            ([.expandGrayTo8], 2, 0),
            ([.expand16, .grayToRgb], 8, 0),
            ([.strip16, .grayToRgb, .addAlpha], 16, 0),
            ([.packing, .grayToRgb], 4, 0),
        ]

        for (flags, depth, colorType) in cases {
            let header = self.header(depth: depth, colorType: colorType)
            let program = self.program(flags, header)
            let start = RowInfo(header)

            let promised = program.resultingShape(from: start, hasTransparency: false)
            let capacity = program.maximumRowBytes(from: start, hasTransparency: false)
            let produced = self.run(program, from: start, capacity: capacity + 8)

            #expect(
                promised.rowBytes == produced.rowBytes,
                "row size for \(flags) at depth \(depth) type \(colorType)"
            )
            #expect(promised.channels == produced.channels, "channels for \(flags)")
            #expect(promised.bitDepth == produced.bitDepth, "depth for \(flags)")
            #expect(
                promised.colorType == produced.colorType,
                "colour type for \(flags)"
            )
        }
    }

    /// The buffer is one allocation for the whole pipeline, so it has to hold the largest shape the
    /// row passes through — which is not always the first or the last.
    @Test("Sizes for the largest shape, not the last")
    func sizesForThePeak() {
        // Expanding a palette to colour with alpha and then narrowing back: the middle is the widest
        // point, and a buffer sized for either end would be too small.
        let header = self.header(width: 8, depth: 1, colorType: 3)
        let program = self.program([.expand, .expandTransparency, .stripAlpha], header, transparency: true)
        let start = RowInfo(header)

        let peak = program.maximumRowBytes(from: start, hasTransparency: true)
        let final = program.resultingShape(from: start, hasTransparency: true)

        #expect(peak > start.rowBytes, "the row grows")
        #expect(peak > final.rowBytes, "and shrinks again, so the peak is in the middle")
        // Eight pixels of four channels.
        #expect(peak == 32)
    }

    /// A client may call the setters in any order, and the result must not show it.
    @Test("Ignores the order the transforms were asked for")
    func ignoresRequestOrder() {
        let header = self.header(width: 8, depth: 16, colorType: 0)

        // The same set, built up in two orders.  The flags are a set, so this checks that nothing
        // downstream reintroduces an order dependency.
        let forward: TransformFlags = [.strip16, .grayToRgb, .addAlpha, .bgr]
        var reverse = TransformFlags()
        for flag in [TransformFlags.bgr, .addAlpha, .grayToRgb, .strip16] {
            reverse.insert(flag)
        }

        let first = self.program(forward, header)
        let second = self.program(reverse, header)

        #expect(first.steps.count == second.steps.count)

        let start = RowInfo(header)
        let a = first.resultingShape(from: start, hasTransparency: false)
        let b = second.resultingShape(from: start, hasTransparency: false)

        #expect(a.rowBytes == b.rowBytes)
        #expect(a.channels == b.channels)
        #expect(a.colorType == b.colorType)
    }

    /// Requests that contradict each other have to resolve the same way whichever arrived first,
    /// since the set they land in remembers no order.
    @Test("Resolves contradictory requests one way")
    func resolvesContradictions() {
        let header = self.header(depth: 16, colorType: 2)

        // Both narrowings at once: the scaling one wins.
        let both = TransformFlags([.strip16, .scale16]).resolved(for: header, hasTransparency: false)
        #expect(both.contains(.scale16))
        #expect(!both.contains(.strip16))

        // Narrowing and widening at once: the narrowing wins.
        let opposed = TransformFlags([.strip16, .expand16])
            .resolved(for: header, hasTransparency: false)
        #expect(opposed.contains(.strip16))
        #expect(!opposed.contains(.expand16))
    }

    /// Widening a low-depth greyscale image scales the samples rather than merely unpacking them, so
    /// the brightest value stays the brightest.
    @Test("Scales low-depth greyscale into the full range")
    func scalesGrayToFullRange() {
        for (depth, expected) in [(1, [0, 0xFF]), (2, [0, 0x55, 0xAA, 0xFF]),
                                  (4, [0, 0x11, 0x88, 0xFF])] {
            let samples: [Int] = depth == 4 ? [0, 1, 8, 15] : Array(0 ..< (1 << depth))
            let perByte = 8 / depth

            var packed = [UInt8](repeating: 0, count: 8)
            for (index, value) in samples.enumerated() {
                let shift = (perByte - 1 - index % perByte) * depth
                packed[index / perByte] |= UInt8(value << shift)
            }

            var shape = RowInfo(
                width: samples.count,
                bitDepth: depth,
                colorType: .grayscale,
                channels: 1
            )

            packed.withUnsafeMutableBufferPointer { row in
                Transform.grayTo8(row, &shape)
            }

            #expect(Array(packed[0 ..< samples.count]) == expected.map(UInt8.init),
                    "depth \(depth)")
            #expect(shape.bitDepth == 8)
        }
    }

    /// Unpacking is not the same as widening: the values are spread out but not scaled, so a two bit
    /// sample of 3 becomes a byte of 3 rather than of 255.
    @Test("Unpacks without scaling")
    func unpacksWithoutScaling() {
        var packed: [UInt8] = [0b11_10_01_00, 0, 0, 0]
        var shape = RowInfo(width: 4, bitDepth: 2, colorType: .grayscale, channels: 1)

        packed.withUnsafeMutableBufferPointer { row in
            Transform.packing(row, &shape)
        }

        #expect(Array(packed[0 ..< 4]) == [3, 2, 1, 0])
        #expect(shape.bitDepth == 8)
    }

    /// The two ways of narrowing sixteen bit samples differ, and the difference is the point of
    /// having both: one keeps the top of the range intact, the other compresses it.
    @Test("Narrows sixteen bit samples two different ways")
    func narrowsTwoWays() {
        // 0xFFFF becomes 0xFF either way, since the top of one range has to reach the top of the
        // other.  Everywhere else they can differ, and the cases below are chosen where they do.
        for (high, low, stripped, scaled) in [(0xFF, 0xFF, 0xFF, 0xFF),
                                              (0xFF, 0x00, 0xFF, 0xFE),
                                              (0x00, 0xFF, 0x00, 0x01),
                                              (0x01, 0x00, 0x01, 0x01),
                                              (0x80, 0x80, 0x80, 0x80)] {
            var bytes = [UInt8(high), UInt8(low), 0, 0]
            var shape = RowInfo(width: 1, bitDepth: 16, colorType: .grayscale, channels: 1)

            bytes.withUnsafeMutableBufferPointer { row in
                Transform.strip16(row, &shape)
            }
            #expect(bytes[0] == UInt8(stripped), "stripping \(high),\(low)")

            var other = [UInt8(high), UInt8(low), 0, 0]
            var otherShape = RowInfo(width: 1, bitDepth: 16, colorType: .grayscale, channels: 1)

            other.withUnsafeMutableBufferPointer { row in
                Transform.scale16(row, &otherShape)
            }
            #expect(other[0] == UInt8(scaled), "scaling \(high),\(low)")
        }
    }

    /// Widening repeats the byte rather than shifting it, so the full range maps to the full range
    /// and a round trip through both is lossless.
    @Test("Widens eight bit samples losslessly")
    func widensLosslessly() {
        for value in [0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF] as [UInt8] {
            var bytes = [value, 0, 0, 0]
            var shape = RowInfo(width: 1, bitDepth: 8, colorType: .grayscale, channels: 1)

            bytes.withUnsafeMutableBufferPointer { row in
                Transform.expand16(row, &shape)
            }

            #expect(bytes[0] == value)
            #expect(bytes[1] == value)

            // And back again, unchanged.
            bytes.withUnsafeMutableBufferPointer { row in
                Transform.strip16(row, &shape)
            }

            #expect(bytes[0] == value, "round trip of \(value)")
        }
    }

    /// The shift recovers the narrower values the image was made from, which means moving samples
    /// down rather than up.
    @Test("Moves samples down to recover the original range")
    func recoversOriginalRange() {
        var bytes: [UInt8] = [0x32, 0x64, 0x96, 0xF8]
        var shape = RowInfo(width: 4, bitDepth: 8, colorType: .grayscale, channels: 1)

        var bits = SignificantBits()
        bits.gray = 4

        bytes.withUnsafeMutableBufferPointer { row in
            Transform.shift(row, &shape, significant: bits)
        }

        // Four significant bits in eight, so each sample moves down by four.
        #expect(bytes == [0x03, 0x06, 0x09, 0x0F])
    }

    /// A row of palette indices has nothing for the shift to act on, and the amounts describe the
    /// palette's samples rather than the indices.
    @Test("Leaves palette indices unshifted")
    func leavesIndicesAlone() {
        var bytes: [UInt8] = [1, 2, 3, 4]
        var shape = RowInfo(width: 4, bitDepth: 8, colorType: .palette, channels: 1)

        var bits = SignificantBits()
        bits.red = 4
        bits.green = 4
        bits.blue = 4

        bytes.withUnsafeMutableBufferPointer { row in
            Transform.shift(row, &shape, significant: bits)
        }

        #expect(bytes == [1, 2, 3, 4])
    }

    /// The shift amounts have to fit the image, or the samples would be moved out of existence.
    @Test("Refuses shift amounts wider than the samples")
    func refusesImpossibleShift() {
        var bits = SignificantBits()
        bits.gray = 4

        // Four significant bits in a four bit image is nothing to do, but is valid.
        #expect(throws: Never.self) {
            try TransformProgram.validateShift(bits, header: self.header(depth: 4, colorType: 0))
        }

        // Four in a two bit image is not.
        #expect(throws: Diagnostic.self) {
            try TransformProgram.validateShift(bits, header: self.header(depth: 2, colorType: 0))
        }

        // Nor is nothing at all.
        var none = SignificantBits()
        none.gray = 0
        #expect(throws: Diagnostic.self) {
            try TransformProgram.validateShift(none, header: self.header(depth: 8, colorType: 0))
        }
    }

    /// Palette entries the transparency table does not mention are opaque, which is the format's
    /// rule and easy to get backwards.
    @Test("Treats unmentioned palette entries as opaque")
    func unmentionedEntriesAreOpaque() {
        let palette = [
            Rgb8(red: 10, green: 20, blue: 30),
            Rgb8(red: 40, green: 50, blue: 60),
            Rgb8(red: 70, green: 80, blue: 90),
        ]
        // A table for the first entry only.
        let alpha: [UInt8] = [0x11]

        var bytes: [UInt8] = [0, 1, 2] + [UInt8](repeating: 0, count: 16)
        var shape = RowInfo(width: 3, bitDepth: 8, colorType: .palette, channels: 1)

        bytes.withUnsafeMutableBufferPointer { row in
            palette.withUnsafeBufferPointer { entries in
                alpha.withUnsafeBufferPointer { table in
                    Transform.paletteToRgb(row, &shape, palette: entries, alpha: table)
                }
            }
        }

        #expect(Array(bytes[0 ..< 4]) == [10, 20, 30, 0x11])
        #expect(Array(bytes[4 ..< 8]) == [40, 50, 60, 0xFF], "past the table, so opaque")
        #expect(Array(bytes[8 ..< 12]) == [70, 80, 90, 0xFF])
        #expect(shape.colorType == .rgba)
    }
}

/// Gamma is the one place where agreeing with the reference to the last bit is both the point and
/// achievable: the correction is a power function over 256 possible inputs, so the table can be
/// checked exhaustively rather than sampled.
@Suite("Gamma correction")
struct GammaTests {
    private func state(screen: Double, file: Double) -> GammaState {
        var state = GammaState()
        state.screenGamma = FixedPoint((screen * 100_000).rounded())
        state.fileGamma = FixedPoint((file * 100_000).rounded())
        return state
    }

    /// A file encoded for the display it is shown on needs no correction, and this is the case that
    /// has to come out as nothing rather than as nearly nothing.
    @Test("Leaves matched exponents alone")
    func matchedExponentsDoNothing() {
        let matched = self.state(screen: 2.2, file: 1.0 / 2.2)

        #expect(!matched.isWorthApplying, "1/2.2 shown at 2.2 is already correct")

        // And the exponent it computes is one, to within the rounding of the fixed-point scale.
        let exponent = matched.correctionExponent
        #expect(exponent != nil)
        #expect(abs((exponent ?? 0) - GammaState.one) <= 2)
    }

    /// A correction small enough that the reference declines to apply it has to be declined here too:
    /// applying it would move samples the reference leaves alone.
    @Test("Declines a correction below the threshold")
    func declinesSmallCorrections() {
        // Just inside the threshold: 1/1.02 is about 0.98, and the threshold is 0.05.
        #expect(!self.state(screen: 1.0, file: 1.0 / 1.02).isWorthApplying)

        // Just outside it.
        #expect(self.state(screen: 1.0, file: 1.0 / 1.2).isWorthApplying)

        // The threshold is on the composed exponent, not on either one alone: two large gammas that
        // cancel are not worth applying.
        #expect(!self.state(screen: 4.0, file: 1.0 / 4.0).isWorthApplying)
    }

    @Test("Reports nothing to do when the client has not said what its display expects")
    func needsAScreenGamma() {
        var state = GammaState()
        state.fileGamma = 45455

        #expect(state.correctionExponent == nil)
        #expect(!state.isWorthApplying)
    }

    /// The ends of the range are fixed points of the curve, and a correction that moved them would be
    /// visible as a shift in the black or white level.
    @Test("Keeps black black and white white")
    func preservesTheEnds() {
        for exponent in [45455, 220000, 100000, 400000, 25000] as [FixedPoint] {
            let table = GammaTable(exponent: exponent)

            #expect(table.values[0] == 0, "black at \(exponent)")
            #expect(table.values[255] == 255, "white at \(exponent)")
        }
    }

    /// The curve is monotonic, so the table has to be too: a client using it as a lookup would
    /// otherwise see brighter inputs come out darker.
    @Test("Produces a table that never goes backwards")
    func tableIsMonotonic() {
        for exponent in [45455, 220000, 400000, 25000, 90000, 110000] as [FixedPoint] {
            let table = GammaTable(exponent: exponent)

            for value in 1 ..< 256 {
                #expect(
                    table.values[value] >= table.values[value - 1],
                    "entry \(value) at exponent \(exponent)"
                )
            }
        }
    }

    /// The rounding is stated rather than left to a cast, and this is what that means: a value whose
    /// exact answer ends in a half goes up, not down.
    @Test("Rounds rather than truncates")
    func roundsHalvesUp() {
        // An exponent of one is the identity, so every entry has to come back unchanged — which only
        // holds if the rounding is right, since pow() will not return exact integers throughout.
        let identity = GammaTable(exponent: GammaState.one)

        for value in 0 ..< 256 {
            #expect(identity.values[value] == UInt8(value), "identity at \(value)")
        }
    }

    /// Widening a sub-byte sample for correction repeats its bits rather than shifting them, so the
    /// top of the narrow range lands on the top of the wide one.
    @Test("Corrects sub-byte samples through the full range")
    func correctsSubByteThroughFullRange() {
        // Brightening: a two bit 3 is white and stays white; a two bit 1 moves up.
        let table = GammaTable(exponent: 45455)

        // 3 repeated across a byte is 255, which the table leaves alone, so it comes back as 3.
        #expect(table.values[Int(UInt8(3) &* 0x55)] >> 6 == 3)

        // 0 stays 0.
        #expect(table.values[0] >> 6 == 0)

        // 1 repeated is 0x55, which brightening moves up, so it comes back as 1 or 2 rather than
        // lower.
        #expect(table.values[0x55] >> 6 >= 1)
    }
}

/// The weighted sum is integer arithmetic, and the two depths round it differently — which is the
/// kind of detail that is invisible until something compares byte for byte.
@Suite("Discarding colour")
struct RgbToGrayTests {
    private func convert(
        _ pixels: [UInt8],
        width: Int,
        colorType: ColorType,
        channels: Int,
        weights: RgbToGrayState = RgbToGrayState()
    ) -> (bytes: [UInt8], shape: RowInfo, sawColor: Bool) {
        var bytes = pixels + [UInt8](repeating: 0, count: 16)
        var shape = RowInfo(width: width, bitDepth: 8, colorType: colorType, channels: channels)
        var sawColor = false

        bytes.withUnsafeMutableBufferPointer { row in
            sawColor = Transform.rgbToGray(row, &shape, weights: weights)
        }

        return (bytes, shape, sawColor)
    }

    /// The weights are not an even split, and using one would be visibly wrong: green carries most of
    /// the brightness a viewer perceives.
    @Test("Weights green most heavily")
    func weightsGreenMost() {
        let weights = RgbToGrayState()

        #expect(weights.green > weights.red)
        #expect(weights.red > weights.blue)
        // The three have to account for the whole, or the conversion would change the brightness.
        #expect(weights.red + weights.green + weights.blue == 32768)

        // Pure green is brighter than pure red, which is brighter than pure blue.
        let green = self.convert([0, 255, 0], width: 1, colorType: .rgb, channels: 3)
        let red = self.convert([255, 0, 0], width: 1, colorType: .rgb, channels: 3)
        let blue = self.convert([0, 0, 255], width: 1, colorType: .rgb, channels: 3)

        #expect(green.bytes[0] > red.bytes[0])
        #expect(red.bytes[0] > blue.bytes[0])
    }

    /// A grey pixel has to survive the conversion unchanged, or a greyscale image passed through it
    /// would drift.
    @Test("Leaves an already grey pixel alone")
    func greyIsAFixedPoint() {
        for value in [0, 1, 64, 127, 128, 200, 254, 255] as [UInt8] {
            let result = self.convert([value, value, value], width: 1,
                                      colorType: .rgb, channels: 3)

            #expect(result.bytes[0] == value, "grey \(value)")
            #expect(!result.sawColor, "and is not reported as coloured")
        }
    }

    @Test("Notices a pixel that had colour")
    func noticesColor() {
        #expect(self.convert([10, 20, 30], width: 1, colorType: .rgb, channels: 3).sawColor)
        #expect(self.convert([10, 10, 11], width: 1, colorType: .rgb, channels: 3).sawColor)
        #expect(!self.convert([10, 10, 10], width: 1, colorType: .rgb, channels: 3).sawColor)

        // Across a row: one coloured pixel among grey ones is enough.
        let row = self.convert([5, 5, 5, 9, 9, 9, 1, 2, 3], width: 3,
                               colorType: .rgb, channels: 3)
        #expect(row.sawColor)
    }

    @Test("Keeps the alpha channel and drops the colour")
    func keepsAlpha() {
        let result = self.convert([10, 20, 30, 200], width: 1, colorType: .rgba, channels: 4)

        #expect(result.shape.colorType == .grayscaleAlpha)
        #expect(result.shape.channels == 2)
        #expect(result.bytes[1] == 200, "alpha carried through untouched")
    }

    /// The eight bit path truncates.  It is checked against a sum computed here rather than against a
    /// value the implementation produced, since the rounding is the whole point.
    @Test("Truncates the eight bit sum")
    func truncatesAtEightBits() {
        let weights = RgbToGrayState()

        for (r, g, b) in [(0, 50, 100), (150, 148, 198), (248, 42, 40), (1, 1, 2)] {
            let expected = (Int(weights.red) * r + Int(weights.green) * g
                + Int(weights.blue) * b) >> 15

            let result = self.convert([UInt8(r), UInt8(g), UInt8(b)], width: 1,
                                      colorType: .rgb, channels: 3)

            #expect(result.bytes[0] == UInt8(expected), "(\(r),\(g),\(b))")
        }
    }

    /// A weight of zero for two channels makes the third the whole answer, which is the clearest
    /// possible check that the weights are applied where they are meant to be.
    @Test("Applies the client's own weights")
    func honoursCustomWeights() {
        var onlyRed = RgbToGrayState()
        onlyRed.red = 32768
        onlyRed.green = 0

        let result = self.convert([200, 10, 20], width: 1, colorType: .rgb, channels: 3,
                                  weights: onlyRed)

        #expect(onlyRed.blue == 0)
        #expect(result.bytes[0] == 200)
    }

    /// Nothing to convert means nothing changed, including the shape a client was promised.
    @Test("Declines a row with no colour to discard")
    func declinesGreyscaleRows() {
        var bytes: [UInt8] = [1, 2, 3, 4]
        var shape = RowInfo(width: 4, bitDepth: 8, colorType: .grayscale, channels: 1)

        let sawColor = bytes.withUnsafeMutableBufferPointer { row in
            Transform.rgbToGray(row, &shape, weights: RgbToGrayState())
        }

        #expect(!sawColor)
        #expect(bytes == [1, 2, 3, 4])
        #expect(shape.channels == 1)
        #expect(shape.colorType == .grayscale)
    }
}

/// Averaging samples is only meaningful on light levels, so anything that averages has to go through
/// linear first. These check that the round trip is a round trip, and that the two ends of the range
/// survive it.
@Suite("Linear light")
struct LinearLightTests {
    private func state(screen: Double, file: Double) -> GammaState {
        var state = GammaState()
        state.screenGamma = FixedPoint((screen * 100_000).rounded())
        state.fileGamma = FixedPoint((file * 100_000).rounded())
        return state
    }

    /// Decoding to linear and re-encoding for the same curve has to come back where it started, or
    /// every average would drift.
    @Test("Round trips through linear")
    func roundTripsThroughLinear() {
        // A file and a display with the same curve: to linear and back is the identity.
        let state = self.state(screen: 2.2, file: 1.0 / 2.2)

        let toLinear = GammaTable(exponent: state.toLinearExponent ?? 0)
        let fromLinear = GammaTable(exponent: state.fromLinearExponent ?? 0)

        // Not every value survives exactly — the intermediate is eight bits, so the curve loses
        // resolution at the dark end — but the ends must, and the middle must stay close.
        #expect(fromLinear.values[Int(toLinear.values[0])] == 0)
        #expect(fromLinear.values[Int(toLinear.values[255])] == 255)

        for value in [64, 128, 192, 254] {
            let round = Int(fromLinear.values[Int(toLinear.values[value])])
            #expect(abs(round - value) <= 2, "\(value) came back as \(round)")
        }
    }

    /// The two exponents are reciprocals of the two gammas, not of their product — that is the whole
    /// difference between correcting once and decomposing the correction into two halves.
    @Test("Derives the two halves of the correction")
    func derivesBothHalves() {
        let state = self.state(screen: 2.2, file: 1.0 / 2.2)

        // A file encoded at 1/2.2 decodes to linear by raising to 2.2.
        #expect(abs((state.toLinearExponent ?? 0) - 220_000) <= 5)

        // And a display expecting 2.2 wants the result raised to 1/2.2.
        #expect(abs((state.fromLinearExponent ?? 0) - 45_455) <= 5)

        // The two composed are the single correction, which for this pair is nothing at all.
        #expect(!state.isWorthApplying)
    }

    @Test("Reports no halves when there is no correction to decompose")
    func needsBothGammas() {
        var onlyFile = GammaState()
        onlyFile.fileGamma = 45455

        #expect(onlyFile.toLinearExponent != nil)
        #expect(onlyFile.fromLinearExponent == nil, "no display curve was given")
    }

    /// An already grey pixel takes the combined correction directly rather than making the trip
    /// through linear, and the two are not the same: the trip loses precision at eight bits.
    @Test("Sends a grey pixel by the direct path")
    func greyTakesTheDirectPath() {
        let state = self.state(screen: 2.2, file: 1.0)

        let toLinear = GammaTable(exponent: state.toLinearExponent ?? 0)
        let fromLinear = GammaTable(exponent: state.fromLinearExponent ?? 0)
        let corrected = GammaTable(exponent: state.correctionExponent ?? 0)

        var bytes: [UInt8] = [40, 40, 40] + [UInt8](repeating: 0, count: 8)
        var shape = RowInfo(width: 1, bitDepth: 8, colorType: .rgb, channels: 3)

        _ = bytes.withUnsafeMutableBufferPointer { row in
            Transform.rgbToGray(
                row,
                &shape,
                weights: RgbToGrayState(),
                toLinear: toLinear,
                fromLinear: fromLinear,
                corrected: corrected
            )
        }

        #expect(bytes[0] == corrected.values[40], "the direct correction, not the round trip")
    }
}

/// Compositing has three arithmetic details worth pinning down: the divisor, the two spaces the
/// background lives in, and the shortcuts at the ends of the coverage range.
@Suite("Compositing")
struct ComposeTests {
    private func background(_ r: Int, _ g: Int, _ b: Int) -> ComposeBackground {
        var color = Rgb16()
        color.red = UInt16(r)
        color.green = UInt16(g)
        color.blue = UInt16(b)
        color.gray = UInt16(r)

        // Without a correction in force the two spaces are the same.
        return ComposeBackground(screen: color, linear: color)
    }

    private func compose(
        _ pixels: [UInt8],
        width: Int,
        colorType: ColorType,
        channels: Int,
        background: ComposeBackground
    ) -> (bytes: [UInt8], shape: RowInfo) {
        var bytes = pixels + [UInt8](repeating: 0, count: 8)
        var shape = RowInfo(width: width, bitDepth: 8, colorType: colorType, channels: channels)

        bytes.withUnsafeMutableBufferPointer { row in
            Transform.compose(row, &shape, background: background)
        }

        return (bytes, shape)
    }

    /// The divisor is 255 rather than 256, because coverage runs from nothing to fully opaque
    /// inclusive.  Dividing by 256 would leave a fully opaque pixel a shade short of itself, which is
    /// what this checks.
    @Test("Leaves a fully opaque pixel exactly as it was")
    func opaqueIsExact() {
        for value in [0, 1, 127, 128, 254, 255] as [UInt8] {
            let result = self.compose(
                [value, value, value, 255],
                width: 1,
                colorType: .rgba,
                channels: 4,
                background: self.background(200, 100, 50)
            )

            #expect(result.bytes[0] == value, "opaque \(value)")
        }
    }

    @Test("Replaces a fully transparent pixel with the background")
    func transparentIsBackground() {
        let result = self.compose(
            [10, 20, 30, 0],
            width: 1,
            colorType: .rgba,
            channels: 4,
            background: self.background(200, 100, 50)
        )

        #expect(Array(result.bytes[0 ..< 3]) == [200, 100, 50])
    }

    @Test("Drops the alpha channel")
    func dropsAlpha() {
        let rgba = self.compose(
            [10, 20, 30, 128],
            width: 1,
            colorType: .rgba,
            channels: 4,
            background: self.background(0, 0, 0)
        )

        #expect(rgba.shape.colorType == .rgb)
        #expect(rgba.shape.channels == 3)

        let gray = self.compose(
            [10, 128],
            width: 1,
            colorType: .grayscaleAlpha,
            channels: 2,
            background: self.background(0, 0, 0)
        )

        #expect(gray.shape.colorType == .grayscale)
        #expect(gray.shape.channels == 1)
    }

    /// Half coverage of black over white should land in the middle, and the two ends must not drift:
    /// this is the check that catches an off-by-one divisor.
    @Test("Blends the middle of the range")
    func blendsTheMiddle() {
        let result = self.compose(
            [0, 0, 0, 128],
            width: 1,
            colorType: .rgba,
            channels: 4,
            background: self.background(255, 255, 255)
        )

        // 255 * 127 / 255 = 127.
        #expect(result.bytes[0] == 127)
    }

    /// Coverage is monotonic: more of the foreground can never move the result away from it.
    @Test("Moves steadily from the background to the foreground")
    func isMonotonic() {
        var previous = 256

        for alpha in stride(from: 0, through: 255, by: 5) {
            let result = self.compose(
                [0, 0, 0, UInt8(alpha)],
                width: 1,
                colorType: .rgba,
                channels: 4,
                background: self.background(255, 255, 255)
            )

            let value = Int(result.bytes[0])
            #expect(value <= previous, "coverage \(alpha) gave \(value) after \(previous)")
            previous = value
        }

        #expect(previous == 0, "full coverage of black is black")
    }

    /// A palette is composited in place, and entries the transparency table does not reach keep their
    /// colour.
    @Test("Composites a palette and leaves unmentioned entries alone")
    func compositesPalette() {
        var palette = [
            Rgb8(red: 0, green: 0, blue: 0),
            Rgb8(red: 17, green: 31, blue: 7),
            Rgb8(red: 90, green: 90, blue: 90),
        ]
        let alphas: [UInt8] = [0, 64]

        palette.withUnsafeMutableBufferPointer { entries in
            alphas.withUnsafeBufferPointer { table in
                Transform.composePalette(
                    entries,
                    alphas: table,
                    background: self.background(128, 64, 192)
                )
            }
        }

        // Fully transparent, so it becomes the background.
        #expect(palette[0].red == 128)
        #expect(palette[0].green == 64)
        #expect(palette[0].blue == 192)

        // Quarter coverage: 17*64 + 128*191, over 255.
        #expect(palette[1].red == 100)
        #expect(palette[1].green == 56)
        #expect(palette[1].blue == 146)

        // Past the table, so opaque and unchanged.
        #expect(palette[2].red == 90)
        #expect(palette[2].blue == 90)
    }
}
