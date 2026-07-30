// PngContext.swift - everything the decode owns
//
// This backs `png_struct`'s one opaque pointer.  The C structure keeps the plain
// data that the error and callback machinery touches; everything with a lifetime
// lives here.
//
// The division exists for one reason: a client may longjmp out of any callback we
// invoke, abandoning every Swift frame between that callback and the client's own
// jump target without running their cleanups.  Anything owned by such a frame
// would leak.  So the rule is that nothing is owned by a frame — every buffer
// hangs off this object, which the C structure holds and `png_destroy_read_struct`
// releases, whatever state the decode was left in.

/// The state of one image being read or written.
///
/// Not `Sendable` by design. The contract is libpng's: one structure per thread,
/// no sharing.
public final class PngContext {
    public let host: Host
    public let isReading: Bool

    /// The image geometry, once the header has been read.
    ///
    /// Held here as well as in the info structure because most of the reading API
    /// does not take one: `png_read_row` has only the control structure to work
    /// from, so the geometry it needs has to live on it.
    public private(set) var header: Header?

    /// The filter byte followed by one scanline.
    var rowBuffer = RawBuffer.empty

    /// The previous reconstructed scanline, which the upward-looking filters need.
    var previousRow = RawBuffer.empty

    /// Compressed bytes drawn from the current image data chunk.
    var inputBuffer = RawBuffer.empty

    /// Working space for reading a metadata chunk whole, or skipping past one.
    var scratch = RawBuffer.empty

    var inflater: InflateStream?

    let reader = SequentialReader()

    /// What the client declared through `png_set_sig_bytes`.
    public var signatureBytesConsumed = 0

    /// Whether the client asked for an interlaced image's passes to arrive as full-width
    /// rows rather than as the narrower rows each pass actually stores.
    ///
    /// Set by `png_set_interlace_handling`. With it, a client reading every pass into the
    /// same row buffers ends up with the whole picture; without it, the client is handed the
    /// subimages and has to place their pixels itself.
    public var spreadsInterlacedRows = false

    /// What the client has asked to be done to each row.
    ///
    /// Recorded as a set rather than acted on when requested, because the order the requests arrive
    /// in must not affect the result.
    public var transformFlags = TransformFlags()

    /// The value a filler channel is given, at sixteen bits; at eight only the low byte is used.
    public var fillerValue: UInt32 = 0

    /// Whether the filler channel goes after the colour rather than before it.
    public var fillerAfterColor = true

    /// How far to move each channel when the client asked for the shift.
    ///
    /// From the client rather than from the file: `png_set_shift` says how far, where the
    /// significant bits chunk only says what the file did.
    public var shiftBits: SignificantBits?

    /// The exponents a correction is computed from.
    ///
    /// The file's is taken from the image unless the client overrode it, which `png_set_gamma` does
    /// unconditionally — that is what makes a client's request deterministic whatever the file said.
    public var gamma = GammaState()

    /// How the colour conversion is weighted, and what to say about a pixel that had colour.
    public var rgbToGray = RgbToGrayState()

    /// The background to lay the image over, and how to read its samples.
    public var compose = ComposeState()

    /// Records that a pixel with colour reached the conversion.
    ///
    /// The running record, which `png_get_rgb_to_gray_status` reports.  Telling the client is separate
    /// and happens per row, from the reader.
    func noteColorDuringConversion() {
        self.rgbToGray.sawColor = true
    }

    /// The pipeline the requests resolve to, built once the header is known.
    var transforms: TransformProgram?

    /// Whether the client resolved the pipeline itself rather than leaving it to the first row.
    ///
    /// Worth distinguishing because it changes what a later call can still do: once the client has
    /// been told what its rows will look like, turning interlace handling on would change that
    /// answer, so asking for the whole image afterwards is worth a word of warning.
    private(set) var clientUpdatedInfo = false

    /// The shape a row has once the pipeline has run, which is what the client allocates from.
    ///
    /// Absent until the pipeline is built, before which the row is whatever the file stores.
    public private(set) var transformedShape: RowInfo?

    /// What the transforms need from the metadata, copied at the point the pipeline is built.
    ///
    /// Copied rather than referred to, and for a reason: most of the reading API is given only the
    /// control structure, so the info structure is not available when a row is transformed. Taking
    /// a snapshot also settles the lifetime question — a client that destroys its info structure
    /// mid-decode cannot leave the pipeline reading freed palette entries.
    var transformInputs = TransformInputs()

    /// Whether the file carried transparency, which several stages need to know.
    public private(set) var hasTransparency = false

    /// The info structure the header was read into.
    ///
    /// Held only until the pipeline is resolved, which is the one thing that needs it and which may
    /// happen either when the client asks or at the first row.  Cleared afterwards, so the decode
    /// does not depend on a structure the client is free to destroy.
    private var headerInfo: InfoStore?

    public init(host: Host, isReading: Bool) {
        self.host = host
        self.isReading = isReading
    }

    /// Releases everything this object owns.
    ///
    /// Called from the destructor rather than from `deinit`, so that the release
    /// order relative to freeing the C structure is explicit: the buffers were
    /// allocated through the client's allocator, which lives in that structure.
    ///
    /// This has to work from any state, including one a client jump left behind
    /// half way through a decode, which is why nothing here inspects how far the
    /// decode had got.
    public func release() {
        self.inflater?.release()
        self.inflater = nil

        for buffer in [self.rowBuffer, self.previousRow, self.inputBuffer, self.scratch] {
            buffer.deallocate(host: self.host)
        }

        self.rowBuffer = .empty
        self.previousRow = .empty
        self.inputBuffer = .empty
        self.scratch = .empty
    }

    /// Ensures `buffer` holds at least `count` bytes, replacing it if not.
    ///
    /// The order matters and is the reason this is a method here rather than one on
    /// the buffer. The new allocation happens first, while nothing is owned; then
    /// the property is replaced, which touches no client code; and only then is the
    /// old block released. So no access to the property is open while the client's
    /// allocator runs, and a jump out of it cannot leave one dangling.
    ///
    /// The previous contents are not preserved: every use of this replaces a buffer
    /// whose contents are already spent.
    func reserve(
        _ buffer: ReferenceWritableKeyPath<PngContext, RawBuffer>,
        _ count: Int
    ) throws {
        guard count > self[keyPath: buffer].count else { return }

        let fresh = try RawBuffer.allocate(count, host: self.host)
        let previous = self[keyPath: buffer]

        self[keyPath: buffer] = fresh
        previous.deallocate(host: self.host)
    }

    // -- the operations the boundary exposes ---------------------------------
    //
    // Each of these is what one published function does, minus the error
    // reporting: they throw, and the boundary turns that into the client's error
    // handler as the last thing it does.

    public func readInfo(into info: InfoStore) throws {
        try self.reader.readInfo(
            into: info,
            context: self,
            signatureBytesConsumed: self.signatureBytesConsumed
        )

        // Both structures describe the image from here on: the info structure for
        // the client's accessors, this one for the reading API.
        self.header = info.header
        self.headerInfo = info
    }

    public func startReadImage() throws {
        try self.reader.startRows(context: self)
    }

    /// Resolves the requested transforms and reports the shape a row will have.
    ///
    /// Separate from starting the decode because a client calls this to find out how much to
    /// allocate, which it has to know before any row is read.
    /// The background colour in the terms the row will be blended in.
    ///
    /// A client may give it in the file's terms — a palette index, or a value at a bit depth the row
    /// will be widened out of — or in the display's.  This settles which, because the blend itself has
    /// neither the palette nor the file's depth to hand.
    ///
    /// What it does not do is rescale a background the client said was already in the display's terms.
    /// A value out of range for the image's depth is the client's mistake, and guessing which scale it
    /// meant would turn a detectable error into a silent one.
    private func resolvedBackground(
        header: Header,
        info: InfoStore,
        gamma: GammaState
    ) -> ComposeBackground {
        var background = self.compose.color

        guard !self.compose.needsExpanding else {
            return self.corrected(self.expanded(background, header: header, info: info),
                                  gamma: gamma)
        }

        return self.corrected(background, gamma: gamma)
    }

    /// Takes the background into the two spaces a blend needs it in.
    ///
    /// Which exponent reaches each depends on the space the client said the colour was in.  A colour
    /// already in the display's terms needs the display's own exponent to become light, and needs no
    /// correction at all to be shown; one given in the file's terms is corrected exactly as the image
    /// is.  Using the image's exponent for a colour that was never in the file's space is the mistake
    /// this exists to avoid.
    private func corrected(_ color: Rgb16, gamma: GammaState) -> ComposeBackground {
        // Without a correction in force there is one space, and the colour is already in it.
        guard gamma.screenGamma > 0, gamma.fileGamma > 0 else {
            return ComposeBackground(screen: color, linear: color)
        }

        let toLight: FixedPoint?
        let toScreen: FixedPoint?

        switch self.compose.gammaCode {
        case .file:
            toLight = gamma.toLinearExponent
            toScreen = gamma.correctionExponent

        case .unique:
            var own = gamma
            own.fileGamma = self.compose.gamma
            toLight = own.toLinearExponent
            toScreen = own.correctionExponent

        case .screen, .unknown:
            // Already what the display should see, so nothing takes it there, and the display's own
            // exponent is what takes it to light.
            toLight = gamma.screenGamma
            toScreen = GammaState.one
        }

        func apply(_ exponent: FixedPoint?, to color: Rgb16) -> Rgb16 {
            guard let exponent, GammaState.isSignificant(exponent) else { return color }

            let table = GammaTable(exponent: exponent)
            var result = color

            result.red = UInt16(table.values[Int(color.red & 0xFF)])
            result.green = UInt16(table.values[Int(color.green & 0xFF)])
            result.blue = UInt16(table.values[Int(color.blue & 0xFF)])
            result.gray = UInt16(table.values[Int(color.gray & 0xFF)])

            return result
        }

        return ComposeBackground(
            screen: apply(toScreen, to: color),
            linear: apply(toLight, to: color)
        )
    }

    /// A background given in the file's terms, brought into the row's.
    private func expanded(_ color: Rgb16, header: Header, info: InfoStore) -> Rgb16 {
        var background = color

        if header.colorType.isIndexed {
            // An index rather than a colour, so the palette says what it means.
            let index = Int(background.index)

            guard index < info.palette.count else { return background }

            let entry = info.palette.elements[index]

            background.red = UInt16(entry.red)
            background.green = UInt16(entry.green)
            background.blue = UInt16(entry.blue)
            background.gray = UInt16(entry.red)
        } else if header.bitDepth < 8 {
            // Given at the file's depth, which the row will have been widened out of, so the value is
            // scaled into the range the row now uses rather than left where it was.
            let maximum = (1 << header.bitDepth) - 1
            let scaled = maximum > 0
                ? UInt16(Int(background.gray) * 255 / maximum)
                : background.gray

            background.gray = scaled
            background.red = scaled
            background.green = scaled
            background.blue = scaled
        }

        return background
    }

    /// Resolves the pipeline without the client having asked, for a client that set transforms and
    /// went straight to reading rows.
    func resolveTransforms() throws {
        guard let info = self.headerInfo else {
            throw Diagnostic("no image description to transform")
        }

        try self.updateInfo(info)
    }

    /// Resolves the pipeline at the client's request, recording that it was asked for.
    public func updateInfoForClient(_ info: InfoStore) throws {
        try self.updateInfo(info)
        self.clientUpdatedInfo = true
    }

    public func updateInfo(_ info: InfoStore) throws {
        guard let header = self.header else {
            throw Diagnostic("png_read_update_info called before png_read_info")
        }

        // The file's exponent comes from the image unless the client supplied one.
        var gamma = self.gamma

        if gamma.fileGamma == 0, info.isValid(InfoStore.Valid.gama) {
            gamma.fileGamma = info.gamma
        }

        // The background is resolved into the row's own terms before the pipeline is built, because
        // working that out needs the palette and the file's depth — which are here and not there.
        let background = self.resolvedBackground(header: header, info: info, gamma: gamma)

        let program = TransformProgram(
            flags: self.transformFlags,
            header: header,
            info: info,
            fillerValue: self.fillerValue,
            fillerAfterColor: self.fillerAfterColor,
            gamma: gamma,
            background: background
        )

        // The correction table is built before the snapshot, because for an indexed image it changes
        // what the snapshot should contain.
        var gammaTable: GammaTable?

        if let exponent = gamma.correctionExponent, GammaState.isSignificant(exponent) {
            gammaTable = GammaTable(exponent: exponent)
        }

        // An indexed image is corrected in its palette rather than in its rows, since that is where
        // its samples are.  The store's own palette is corrected, not just the copy the pipeline
        // reads: a client that asks for the palette back gets the corrected entries, which is what
        // the reference gives it and what makes the two consistent.
        // Not when the colour conversion is going to run: it corrects as it averages, so a palette
        // corrected here would have the curve applied to it twice.
        if let gammaTable, header.colorType.isIndexed, !program.colorConversionOwnsGamma {
            info.applyGammaToPalette(gammaTable)
        }

        // An indexed image is composited in its palette, once, and its rows left as indices.  This has
        // to happen before the snapshot below, which is what the row expansion reads from: a palette
        // changed afterwards would reach a client asking for the palette but not the rows built from it.
        // Read before anything below consumes it, since the pipeline was built against this answer.
        let hadTransparency = info.isValid(InfoStore.Valid.trns)

        if program.composes, header.colorType.isIndexed, hadTransparency {
            info.composePalette(
                background: background,
                toLinear: gammaTable == nil ? nil : GammaTable(exponent: gamma.toLinearExponent ?? 0),
                fromLinear: gammaTable == nil ? nil : GammaTable(exponent: gamma.fromLinearExponent ?? 0),
                corrected: gammaTable
            )
            info.consumeTransparency()
        }

        self.transformInputs = TransformInputs(info)
        self.hasTransparency = hadTransparency

        if let gammaTable {
            self.transformInputs.gammaTable = gammaTable
        }

        self.transformInputs.rgbToGray = self.rgbToGray

        // The pair that map to linear light and back, built only when something needs to average
        // samples and there is a curve to undo first.  They are built together: converting one way
        // without the other would leave the samples in the wrong space.
        if self.transformFlags.contains(.rgbToGray) || self.transformFlags.contains(.compose),
           let toLinear = gamma.toLinearExponent,
           let fromLinear = gamma.fromLinearExponent {
            self.transformInputs.toLinear = GammaTable(exponent: toLinear)
            self.transformInputs.fromLinear = GammaTable(exponent: fromLinear)

            if let combined = gamma.correctionExponent {
                self.transformInputs.linearExponents = (
                    toLinear: Double(toLinear) * 1e-5,
                    fromLinear: Double(fromLinear) * 1e-5,
                    corrected: Double(combined) * 1e-5
                )
            }
        }

        // What the client asked for wins over what the file recorded: png_set_shift says how far to
        // move the samples, while the chunk only says what was done to them originally.
        if let shiftBits = self.shiftBits {
            try TransformProgram.validateShift(shiftBits, header: header)
            self.transformInputs.significantBits = shiftBits
        }

        let shape = program.resultingShape(
            from: RowInfo(header),
            hasTransparency: info.isValid(InfoStore.Valid.trns)
        )

        self.transforms = program
        self.transformedShape = shape

        // The info structure now describes the rows the client will receive rather than the ones
        // the file holds, which is the whole point of the call: png_get_rowbytes and its
        // neighbours have to answer for what is about to be handed over.
        info.applyTransformedShape(shape)

        // The background a client supplied becomes the one the image describes.  Its validity is not
        // touched: an image that carried no background chunk still reports none, so this replaces an
        // answer rather than inventing one.
        if program.composes {
            // Not for an indexed image, which keeps whatever background chunk it carried.  Its own is
            // expressed as a palette index, and replacing that with a colour the client named in
            // another form would leave the two describing different things.
            if !header.colorType.isIndexed {
                info.background = self.compose.color
            }

        }

        // The transparency has become a channel, so there is no longer a table to report.  A client
        // that read one now would apply the transparency a second time.
        if program.consumesTransparency {
            info.consumeTransparency()
        }

        // Everything needed has been copied out, so the structure is not held any longer.
        self.headerInfo = nil
    }

    public func readRow(into destination: UnsafeMutablePointer<UInt8>?) throws {
        try self.reader.readRow(into: destination, context: self)
    }

    /// Decodes the whole image, resolving interlacing.
    public func readImage(
        rows: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>
    ) throws {
        try self.reader.readImage(rows: rows, context: self)
    }

    /// How many times a client has to read every row to receive the whole image.
    ///
    /// Seven for an interlaced image, one otherwise. Reported by
    /// `png_set_interlace_handling`, which is also how a client asks for the passes to be
    /// spread across full-width rows.
    public func enableInterlaceHandling() -> Int {
        guard let header = self.header, header.isInterlaced else { return 1 }

        self.spreadsInterlacedRows = true

        return Adam7.passCount
    }

    /// Which pass the next row belongs to, which `png_get_current_pass_number` reports.
    public var currentPass: UInt8 {
        UInt8(min(self.reader.pass, Adam7.passCount - 1))
    }

    public func readEnd(into info: InfoStore?) throws {
        try self.reader.readEnd(info: info, context: self)
    }

    /// The number of rows the image has, or zero before the header is read.
    public var height: Int {
        self.header?.height ?? 0
    }

    /// The row the next read will produce, which `png_get_current_row_number` reports.
    ///
    /// Which counter that is depends on how the client is reading: when the passes are being
    /// spread across full-width rows, a row means a row of the image, and otherwise it means a
    /// scanline of the current pass.
    public var currentRow: UInt32 {
        UInt32(self.spreadsInterlacedRows ? self.reader.imageRowIndex : self.reader.rowIndex)
    }
}
