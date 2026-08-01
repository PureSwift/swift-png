// TransformProgram.swift - the order the transforms run in
//
// The order here is the single most important thing in this file, and it is not the order a client
// asked for them in.  It is fixed, and it has to be: expanding a palette before stripping alpha
// gives a different picture from stripping first, and two clients making the same requests in
// different orders must get the same image.
//
// The order below is the reference's.  Some of it is forced — a palette has to become colours
// before anything can rearrange those colours — and some of it is simply a choice that has been
// made and now has to be matched.  The cases where it is a choice are the ones worth noting, and
// they are noted.
//
// Applying and measuring go through the same list.  A client needs the finished row size before
// any row is read, so the program is walked once over a shape alone, with no bytes, to find both
// the final size and the largest size the row passes through.

/// The transforms to apply to each row, in the order they run.
struct TransformProgram {
    /// One stage of the pipeline.
    ///
    /// A case per transform rather than a closure per transform, because the list is walked twice —
    /// once for real and once to measure — and a closure that captured a row could not be.
    enum Step {
        case expandPalette
        case expandGrayTo8
        case expandTransparency
        case stripAlpha
        case rgbToGray
        case grayToRgb
        case compose(background: ComposeBackground)
        case alphaMode(AlphaMode)
        case composeTransparentColor
        case encodeAlpha
        case scale16
        case strip16
        case expand16
        case quantize
        case invertMono
        case invertAlpha
        case shift
        case gamma(exponent: FixedPoint)
        case packing
        case bgr
        case packSwap
        case filler(value: UInt32, afterColor: Bool, countsAsAlpha: Bool)
        case swapAlpha
        case swapBytes
    }

    private(set) var steps: [Step] = []

    /// Whether the colour conversion has taken charge of the gamma correction.
    ///
    /// Set by the request alone, not by whether the conversion will actually do anything, and that is
    /// the reference's behaviour rather than a simplification: asking to discard colour moves the
    /// correction inside that conversion, and on an image with no colour to discard the conversion does
    /// not run and nothing is corrected at all. A client that asks for both on a greyscale image gets
    /// no gamma — which is peculiar, but it is what clients see.
    ///
    /// It also settles what happens to a palette. An indexed image is normally corrected in its
    /// palette, but when the conversion is going to correct as it averages, correcting the palette
    /// first would apply the curve twice.
    private(set) var colorConversionOwnsGamma = false

    /// Whether the image is laid over a background, and so ends with no alpha channel.
    private(set) var composes = false

    /// Whether a row step rearranges the colour and coverage out of the format's own arrangement.
    ///
    /// The narrower of the two questions, and the one that decides the gamma: a step that leaves the
    /// samples as light, or premultiplied, takes the correction over, because a correction afterwards
    /// would be correcting the wrong thing.
    private(set) var rearrangesAlpha = false

    /// Whether the arrangement the client asked for stands at all.
    ///
    /// Broader than the row step, because the request outlives the rows.  An indexed image is
    /// rearranged in its palette and its rows are left as indices; an image whose transparency is
    /// still a chunk has nothing in its rows to multiply yet.  In both cases the image is now
    /// described as laid over black, which is what the client is told when it asks for the background.
    private(set) var arrangesAlpha = false

    /// Whether the fitting will turn rows of colour into rows of indices.
    ///
    /// Which the shape depends on, and which the request alone does not settle: a client that asked
    /// only for the palette to be shortened has no table to fit colours with, so its rows of colour
    /// stay colour.
    private let quantizesToIndices: Bool

    /// Whether the samples within a byte have been reversed.
    ///
    /// Which matters to one thing outside the pipeline: the bits past the end of a row are at the top
    /// of the last byte rather than the bottom once this has run.
    private(set) var swapsPackedSamples = false

    /// Whether the file's transparency has been dealt with, so that nothing is left to report.
    ///
    /// Broader than "became an alpha channel", and deliberately so, because that is what the
    /// reference does: asking for any expansion at all settles the transparency, whether or not a
    /// channel came out of it.  A client that asked for colour from a greyscale image is told the
    /// transparency is gone even though the row has no alpha — the expansion is taken as the moment
    /// the file's transparency stopped being the client's business.
    ///
    /// Stripping alpha settles it too, by discarding it.
    private(set) var consumesTransparency = false

    /// Builds the pipeline from what the client asked for.
    ///
    /// The sequence of `insert` calls below *is* the canonical order; nothing later reorders them.
    init(
        flags requested: TransformFlags,
        header: Header,
        info: InfoStore,
        fillerValue: UInt32,
        fillerAfterColor: Bool,
        gamma: GammaState = GammaState(),
        background: ComposeBackground = ComposeBackground(),
        alphaMode: AlphaMode = .png,
        quantization: Quantization = Quantization()
    ) {
        self.quantizesToIndices = !quantization.lookup.isEmpty

        let hasTransparency = info.isValid(InfoStore.Valid.trns)
        let flags = requested.resolved(for: header, hasTransparency: hasTransparency)

        // Expansion comes first because everything else works on samples, and until this has run an
        // indexed row holds indices rather than samples.
        if flags.contains(.expand), header.colorType.isIndexed {
            self.steps.append(.expandPalette)
        }

        // Any expansion settles the transparency, and so does discarding the alpha.
        if hasTransparency, flags.contains(.expand) || flags.contains(.stripAlpha) {
            self.consumesTransparency = true
        }

        if flags.contains(.expandGrayTo8) {
            self.steps.append(.expandGrayTo8)
        }

        // Only for a non-indexed image: an indexed one gets its alpha from the palette during the
        // expansion above, so there is nothing left to derive here.
        if flags.contains(.expandTransparency), !header.colorType.isIndexed, hasTransparency {
            self.steps.append(.expandTransparency)
            self.consumesTransparency = true
        }


        // Before the reverse conversion, so that a client asking for both ends up with colour: the
        // two are not opposites that cancel, they are stages that compose.
        if flags.contains(.rgbToGray) {
            self.steps.append(.rgbToGray)
        }

        if flags.contains(.grayToRgb) {
            self.steps.append(.grayToRgb)
        }

        // Only when there is something to blend.  An image with neither an alpha channel nor a
        // transparent colour has nothing the background could show through, and the reference drops the
        // request rather than carrying it — which matters beyond the blend itself, because a request
        // still standing would take the gamma correction with it and leave such an image uncorrected.
        if flags.contains(.compose), header.colorType.hasAlpha || hasTransparency {
            self.steps.append(.compose(background: background))
            self.composes = true
        }

        // After compositing, which is the other thing that can consume an alpha channel: a row laid
        // over a background has none left to rearrange, so the two never both apply.
        //
        // And only when the row will actually have coverage in it.  An image that is opaque throughout
        // has nothing to multiply its colour by, and one whose transparency is still a chunk the client
        // did not ask to expand has nothing there either — in both cases the request is dropped, which
        // leaves the ordinary gamma correction in place, and that is the whole of what such an image
        // gets.
        //
        // An indexed image is rearranged in its palette, for the same reason it is corrected and
        // composited there: its rows hold indices, which name colours rather than being them.  So the
        // arrangement is recorded, for the caller that owns the palette, and no row step is added.
        if flags.contains(.alphaMode), alphaMode != .png, !self.composes,
           header.colorType.hasAlpha || hasTransparency {
            self.arrangesAlpha = true

            // The row step, which is a narrower question than whether the request stands.  An image
            // whose transparency is still a chunk the client did not ask to expand has no coverage in
            // its rows to multiply by, so nothing happens to them — and the ordinary gamma correction
            // is left in place, which is then the whole of what such an image gets.
            if !header.colorType.isIndexed,
               header.colorType.hasAlpha || flags.contains(.expandTransparency) {
                self.steps.append(.alphaMode(alphaMode))
                self.rearrangesAlpha = true
            }

            // A row that still holds a transparent colour rather than a channel.  Nothing here is
            // partial, so there is nothing to multiply — but the blend still stands, which means it
            // rather than the gamma step is what corrects the samples that survive.
            if !header.colorType.isIndexed, !header.colorType.hasAlpha,
               hasTransparency, !flags.contains(.expandTransparency), header.bitDepth >= 8 {
                self.steps.append(.composeTransparentColor)
                self.rearrangesAlpha = true
            }

            // The one part of the arrangement an indexed image cannot do in its palette.  Multiplying
            // colour by coverage belongs there, since that is where the colour is; putting the coverage
            // itself through the display's curve belongs to the row, because that is where the coverage
            // ends up once the palette has been expanded.
            if header.colorType.isIndexed, alphaMode == .broken,
               flags.contains(.expand), hasTransparency {
                self.steps.append(.encodeAlpha)
            }
        }

        // After everything that reads the coverage, and that is the whole reason it is here rather than
        // near the top where it would save work.  A client that asks for premultiplied colour and then
        // for the alpha to be dropped wants colour that has been multiplied by a coverage it will never
        // see — so the coverage has to survive until it has been used.
        //
        // Compositing has already consumed it, so this finds nothing left to strip in that case.
        if flags.contains(.stripAlpha) {
            self.steps.append(.stripAlpha)
        }

        // After the channel arrangement is settled and before the depth changes: the correction is
        // defined on the samples as the file encoded them, so narrowing them first would correct
        // values that had already lost precision.
        //
        // Not for an indexed image, and this is the one place the distinction bites.  Such an image is
        // corrected in its palette, once, and the rows are then expanded from the corrected entries —
        // so a row step here would correct the same samples a second time.
        // Nor when the colour conversion is going to run: with a gamma in force that conversion
        // corrects as it goes, having gone through linear to do the averaging, so a step here would
        // correct the same samples twice.
        // Compositing corrects as it blends, for the same reason the colour conversion does, so it
        // takes the correction over in the same way.
        // Rearranging the alpha leaves the samples as light or premultiplied rather than corrected for
        // a display, so a correction afterwards would be correcting the wrong thing.
        // The rearrangement of an indexed image happens in its palette and corrects it on the way, so
        // it takes the correction over there even though no row step was added.
        self.colorConversionOwnsGamma = flags.contains(.rgbToGray)
            || self.composes
            || self.rearrangesAlpha
            || (self.arrangesAlpha && header.colorType.isIndexed)

        if flags.contains(.gamma), !header.colorType.isIndexed,
           !self.colorConversionOwnsGamma,
           let exponent = gamma.correctionExponent, GammaState.isSignificant(exponent) {
            self.steps.append(.gamma(exponent: exponent))
        }

        // Narrowing before widening, and the two narrowings are mutually exclusive by the time the
        // flags have been resolved.
        if flags.contains(.scale16) {
            self.steps.append(.scale16)
        }

        if flags.contains(.strip16) {
            self.steps.append(.strip16)
        }

        // After the narrowing, because the fitting works on eight bit samples and a sixteen bit row
        // that has not been narrowed is a row it will leave alone; and before the widening, for the
        // same reason from the other side.  A client that asks for both gets indices widened back out
        // to sixteen bits, which is peculiar and is what the reference does.
        if flags.contains(.quantize) {
            self.steps.append(.quantize)
        }

        if flags.contains(.expand16) {
            self.steps.append(.expand16)
        }

        // Inverting greyscale before it is packed out to bytes, because at one bit per pixel the
        // whole byte inverts at once and afterwards it would not.
        if flags.contains(.invertMono) {
            self.steps.append(.invertMono)
        }

        if flags.contains(.invertAlpha) {
            self.steps.append(.invertAlpha)
        }

        // The shift undoes a narrower original range, so it runs while the samples are still at the
        // depth that range was expressed in.
        if flags.contains(.shift) {
            self.steps.append(.shift)
        }

        if flags.contains(.packing) {
            self.steps.append(.packing)
        }

        if flags.contains(.bgr) {
            self.steps.append(.bgr)
        }

        // After the packing, since a row that has been spread one sample to a byte has no shared
        // bytes left to reorder within.
        if flags.contains(.packSwap) {
            self.steps.append(.packSwap)
            self.swapsPackedSamples = true
        }

        // Before the filler, not after, and this is observable: a client that asks for both gets an
        // added alpha channel that is *not* moved to the front.  The swap applies to the alpha the
        // image already had, and a row that had none has nothing to swap.
        if flags.contains(.swapAlpha) {
            self.steps.append(.swapAlpha)
        }

        if flags.contains(.filler) || flags.contains(.addAlpha) {
            self.steps.append(
                .filler(
                    value: fillerValue,
                    afterColor: fillerAfterColor,
                    countsAsAlpha: flags.contains(.addAlpha)
                )
            )
        }

        // Last of all: it reorders bytes within a sample, and every stage above reads samples
        // rather than bytes.
        if flags.contains(.swapBytes) {
            self.steps.append(.swapBytes)
        }

        // A step that reshapes the row declines by shape alone, and the shapes are all known now —
        // `advance` walks them with the same guards the kernels use.  One that declines here would
        // decline on every row, so it is dropped, and an image none of the requests apply to gets
        // the same empty pipeline the reference resolves for it rather than paying a guard per
        // step per row.
        var shape = RowInfo(header)
        self.steps = self.steps.filter { step in
            self.advance(&shape, through: step, hasTransparency: hasTransparency)
                || !Self.reshapes(step)
        }
    }

    /// Whether a step is one whose work is exactly its change to the row's shape.
    ///
    /// The others are never pruned.  Most read more than the shape, so whether they have work can
    /// only be known at the row; the fitting is the odd one out, reshaping rows of colour but also
    /// remapping rows that are already indices, which changes no shape and is still work.
    private static func reshapes(_ step: Step) -> Bool {
        switch step {
        case .composeTransparentColor, .encodeAlpha, .alphaMode, .invertMono, .invertAlpha,
             .shift, .gamma, .bgr, .packSwap, .swapAlpha, .swapBytes, .quantize:
            false
        default:
            true
        }
    }

    var isEmpty: Bool { self.steps.isEmpty }

    /// Checks the shift amounts against the image.
    ///
    /// A shift of nothing is meaningless and a shift wider than the samples would discard them
    /// entirely, so both are refused.  The check is here rather than in the setter because it needs
    /// the image, which the setter may be called before.
    ///
    /// The limit is the image's own depth in every case, indexed images included.  That is worth
    /// stating because the plausible alternative is wrong: an indexed image's samples live in its
    /// palette and are eight bit, but what the reference checks against is the depth of the indices.
    static func validateShift(_ bits: SignificantBits, header: Header) throws {
        let limit = header.bitDepth

        var required: [UInt8] = []

        if header.colorType.isIndexed || header.colorType.hasColor {
            required += [bits.red, bits.green, bits.blue]
        } else {
            required.append(bits.gray)
        }

        if header.colorType.hasAlpha {
            required.append(bits.alpha)
        }

        for value in required where value < 1 || Int(value) > limit {
            throw Diagnostic("png_set_shift: invalid shift values")
        }
    }

    /// What the pipeline noticed while running, which the caller may want to report.
    struct Observations {
        /// Whether a pixel with colour reached the conversion to greyscale.
        var sawColor = false
    }

    /// Runs the pipeline over one row.
    ///
    /// Returns what it noticed rather than recording it anywhere: this runs per row and per pass, and
    /// what to do about an observation — warn, fail, or keep count — belongs to the caller.
    @discardableResult
    func apply(
        to row: UnsafeMutableBufferPointer<UInt8>,
        info: inout RowInfo,
        inputs: TransformInputs
    ) -> Observations {
        var observations = Observations()

        for step in self.steps {
            switch step {
            case .expandPalette:
                inputs.palette.withUnsafeBufferPointer { palette in
                    inputs.paletteAlpha.withUnsafeBufferPointer { alpha in
                        Transform.paletteToRgb(row, &info, palette: palette, alpha: alpha)
                    }
                }

            case .expandGrayTo8:
                Transform.grayTo8(row, &info)

            case .expandTransparency:
                Transform.transparencyToAlpha(row, &info, transparent: inputs.transparentColor)

            case .stripAlpha:
                Transform.stripAlpha(row, &info)

            case .rgbToGray:
                if Transform.rgbToGray(
                    row,
                    &info,
                    weights: inputs.rgbToGray,
                    toLinear: inputs.toLinear,
                    fromLinear: inputs.fromLinear,
                    corrected: inputs.gammaTable,
                    exponents: inputs.linearExponents
                ) {
                    observations.sawColor = true
                }

            case .grayToRgb:
                Transform.grayToRgb(row, &info)

            case .composeTransparentColor:
                Transform.composeTransparentColor(
                    row,
                    info,
                    transparent: inputs.transparentColor,
                    background: ComposeBackground(),
                    corrected: inputs.blendCorrected
                )

            case .encodeAlpha:
                Transform.encodeAlpha(row, info, table: inputs.fromLinear)

            case let .alphaMode(mode):
                Transform.alphaMode(
                    row,
                    info,
                    mode: mode,
                    toLinear: inputs.toLinear,
                    fromLinear: inputs.fromLinear,
                    corrected: inputs.blendCorrected,
                    exponents: inputs.linearExponents
                )

            case let .compose(background):
                Transform.compose(
                    row,
                    &info,
                    background: background,
                    toLinear: inputs.toLinear,
                    fromLinear: inputs.fromLinear,
                    corrected: inputs.blendCorrected,
                    exponents: inputs.linearExponents
                )

            case .scale16:
                Transform.scale16(row, &info)

            case .strip16:
                Transform.strip16(row, &info)

            case .expand16:
                Transform.expand16(row, &info)

            case .quantize:
                Transform.quantize(row, &info, inputs.quantization)

            case .invertMono:
                Transform.invertMono(row, info)

            case .invertAlpha:
                Transform.invertAlpha(row, info)

            case .shift:
                Transform.shift(row, &info, significant: inputs.significantBits)

            case let .gamma(exponent):
                Transform.gamma(row, info, table: inputs.gammaTable, exponent: exponent)

            case .packing:
                Transform.packing(row, &info)

            case .bgr:
                Transform.bgr(row, info)

            case .packSwap:
                Transform.packSwap(row, info)

            case let .filler(value, afterColor, countsAsAlpha):
                Transform.filler(
                    row,
                    &info,
                    value: value,
                    afterColor: afterColor,
                    countsAsAlpha: countsAsAlpha
                )

            case .swapAlpha:
                Transform.swapAlpha(row, info)

            case .swapBytes:
                Transform.swapBytes(row, info)
            }
        }

        return observations
    }

    /// The shape a row ends up with, worked out without decoding anything.
    ///
    /// This is what `png_read_update_info` reports and what a client allocates from, so it has to
    /// agree exactly with what `apply` produces. It does so by walking the same list and applying
    /// each step's effect on the shape — the effects are declared once, in `advance`, and both
    /// paths read them from there.
    func resultingShape(from start: RowInfo, hasTransparency: Bool) -> RowInfo {
        var info = start

        for step in self.steps {
            self.advance(&info, through: step, hasTransparency: hasTransparency)
        }

        return info
    }

    /// The largest a row becomes at any point, which is what the buffer has to hold.
    ///
    /// Not simply the larger of the first and last shapes: a pipeline can widen a row and narrow it
    /// again, and the buffer still has to survive the middle.
    func maximumRowBytes(from start: RowInfo, hasTransparency: Bool) -> Int {
        var info = start
        var largest = info.rowBytes

        for step in self.steps {
            self.advance(&info, through: step, hasTransparency: hasTransparency)
            largest = max(largest, info.rowBytes)
        }

        return largest
    }

    /// How one step changes a row's shape.
    ///
    /// The conditions here mirror the guards in the kernels, because a step that declines to run
    /// must not be reported as having changed the shape.
    ///
    /// Says whether the step ran, which is what lets the pipeline prune the ones that never will.
    @discardableResult
    private func advance(
        _ info: inout RowInfo,
        through step: Step,
        hasTransparency: Bool
    ) -> Bool {
        switch step {
        case .expandPalette:
            guard info.colorType.isIndexed else { return false }
            info.colorType = hasTransparency ? .rgba : .rgb
            info.channels = hasTransparency ? 4 : 3
            info.bitDepth = 8
            info.resize()
            return true

        case .expandGrayTo8:
            guard info.colorType == .grayscale, info.bitDepth < 8 else { return false }
            info.bitDepth = 8
            info.resize()
            return true

        case .expandTransparency:
            guard !info.colorType.hasAlpha, !info.colorType.isIndexed, info.bitDepth >= 8 else {
                return false
            }
            info.colorType = info.colorType.hasColor ? .rgba : .grayscaleAlpha
            info.channels += 1
            info.resize()
            return true

        case .stripAlpha:
            guard info.colorType.hasAlpha, info.bitDepth >= 8 else { return false }
            info.colorType = info.colorType.hasColor ? .rgb : .grayscale
            info.channels -= 1
            info.resize()
            return true

        case .rgbToGray:
            guard info.colorType.hasColor, !info.colorType.isIndexed, info.bitDepth >= 8 else {
                return false
            }
            let hadAlpha = info.colorType.hasAlpha
            info.colorType = hadAlpha ? .grayscaleAlpha : .grayscale
            info.channels = hadAlpha ? 2 : 1
            info.resize()
            return true

        case .compose:
            guard info.colorType.hasAlpha, info.bitDepth >= 8 else { return false }
            info.colorType = info.colorType.hasColor ? .rgb : .grayscale
            info.channels -= 1
            info.resize()
            return true

        case .grayToRgb:
            guard !info.colorType.hasColor, info.bitDepth >= 8 else { return false }
            let hadAlpha = info.colorType.hasAlpha
            info.colorType = hadAlpha ? .rgba : .rgb
            info.channels = hadAlpha ? 4 : 3
            info.resize()
            return true

        case .scale16, .strip16:
            guard info.bitDepth == 16 else { return false }
            info.bitDepth = 8
            info.resize()
            return true

        case .expand16:
            guard info.bitDepth == 8 else { return false }
            info.bitDepth = 16
            info.resize()
            return true

        case .quantize:
            guard self.quantizesToIndices, info.bitDepth == 8,
                  info.colorType == .rgb || info.colorType == .rgba else { return false }
            info.colorType = .palette
            info.channels = 1
            info.resize()
            return true

        case .packing:
            guard info.bitDepth < 8 else { return false }
            info.bitDepth = 8
            info.resize()
            return true

        case let .filler(_, _, countsAsAlpha):
            guard info.bitDepth >= 8, !info.colorType.hasAlpha, !info.colorType.isIndexed,
                  info.channels < 4
            else { return false }
            info.channels += 1
            if countsAsAlpha {
                info.colorType = info.colorType.hasColor ? .rgba : .grayscaleAlpha
            }
            info.resize()
            return true

        case .composeTransparentColor,
             .encodeAlpha,
             .alphaMode, .invertMono, .invertAlpha, .shift, .gamma, .bgr, .packSwap, .swapAlpha,
             .swapBytes:
            // These rearrange bytes without changing the shape.
            return false
        }
    }
}
