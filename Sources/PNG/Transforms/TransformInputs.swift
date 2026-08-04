// TransformInputs.swift - what the transforms need from the metadata
//
// Most of the reading API is given only the control structure: `png_read_row` has no info
// structure to consult, so anything the transforms need from the metadata has to be somewhere the
// control structure can reach.
//
// Copied rather than referred to.  That is what the reference does, and it settles a lifetime
// question as well: a client is free to destroy its info structure and carry on reading rows, and
// a pipeline holding pointers into that structure's palette would then be reading freed memory.
//
// The copies are small — a palette is at most 256 entries — and they are taken once, when the
// pipeline is resolved, rather than per row.

/// A snapshot of the metadata the transforms read.
struct TransformInputs {
    /// The palette, for expanding indices into colours.
    var palette: [Rgb8] = []

    /// One alpha per palette entry, when the file carried them.
    var paletteAlpha: [UInt8] = []

    /// The colour to treat as fully transparent, for a non-indexed image.
    var transparentColor = Rgb16()

    /// How many bits of each channel were significant, for the shift.
    var significantBits = SignificantBits()

    /// The correction table, exhaustive over eight bit samples.
    ///
    /// Built once when the pipeline is resolved rather than per row, which is what makes the
    /// correction cheap enough to be a lookup at all.
    var gammaTable = GammaTable(exponent: GammaState.one)

    /// The weights the colour conversion uses.
    var rgbToGray = RgbToGrayState()

    /// The pair that map to linear light and back, when a correction is in force.
    ///
    /// Present together or not at all: converting one way without the other would leave the samples in
    /// the wrong space. Absent when the client set no gamma, in which case a weighted sum is taken on
    /// the samples as they are — which is what the reference does too, since without a curve to undo
    /// there is nothing to undo.
    var toLinear: GammaTable?
    var fromLinear: GammaTable?

    /// The two composed, for the pixels a blend leaves alone.
    ///
    /// Distinct from the ordinary correction table, which is absent when the correction does nothing.
    /// A blend needs this one present even then, so that a pixel it does not blend comes out in the same
    /// space as the pixels it does.
    var blendCorrected: GammaTable?

    /// The tables a request to fit the image into fewer colours left behind.
    ///
    /// Built when the request was made rather than when the pipeline was resolved, because the client
    /// hands over the palette to work from at that moment and is free to change it afterwards.
    var quantization = Quantization()

    /// The same three curves for sixteen bit samples, answered the way the reference's segmented
    /// tables answer them — exactly when no shift is in force, and through the quantized
    /// constructions when one is.  See `WideGammaTable` for the two constructions and where the
    /// shift comes from.
    var wideBlend: (toLinear: WideGammaTable, fromLinear: WideGammaTable, corrected: WideGammaTable)?

    /// The plain correction for sixteen bit rows, under the same rule.
    var wideGamma: WideGammaTable?


    init() {}

    init(_ info: InfoStore) {
        if !info.palette.isEmpty {
            self.palette = Array(info.palette.elements)
        }

        // The count rather than the validity bit: a transparency that has already been dealt with —
        // folded into a channel, or blended into the palette — leaves the bit set and the count at
        // zero, and using it again would apply it twice.
        if info.transparentCount > 0, !info.transparentAlpha.isEmpty {
            self.paletteAlpha = Array(info.transparentAlpha.elements)
        }

        self.transparentColor = info.transparentColor
        self.significantBits = info.significantBits
    }
}
