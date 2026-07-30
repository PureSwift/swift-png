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


    init() {}

    init(_ info: InfoStore) {
        if !info.palette.isEmpty {
            self.palette = Array(info.palette.elements)
        }

        if info.isValid(InfoStore.Valid.trns), !info.transparentAlpha.isEmpty {
            self.paletteAlpha = Array(info.transparentAlpha.elements)
        }

        self.transparentColor = info.transparentColor
        self.significantBits = info.significantBits
    }
}
