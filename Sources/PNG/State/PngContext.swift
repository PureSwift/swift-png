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

    /// Eight bytes for staging a chunk's framing, and one row of working space for the filters.
    ///
    /// Buffers rather than locals for the reason every buffer here is one: the client's write callback
    /// may be jumped out of, and nothing owned by a frame would survive it.
    var writeStaging = RawBuffer.empty

    /// Where a text chunk's compressed form is built.
    ///
    /// Held by the context rather than by whichever function is writing, because that function hands
    /// the bytes to the client and a client is entitled not to come back: a buffer belonging to the
    /// frame would be released by code the departure skips, while this one is released when the
    /// structure is destroyed whatever happened.
    var textStaging = RawBuffer.empty
    var filterScratch = RawBuffer.empty

    /// Where a client's row is copied to be transformed, so that its own is left alone.
    var writeRowBuffer = RawBuffer.empty

    /// Where the deprecated timestamp accessor writes, since it returns a pointer rather than filling
    /// a caller's buffer.
    var timeText = RawBuffer.empty

    var inflater: InflateStream?

    // Made on first use rather than up front: a structure reads or writes, never both, and the
    // machinery for the direction not taken was two allocations paid by every context.
    private var readerStorage: SequentialReader?
    private var writerStorage: SequentialWriter?

    var reader: SequentialReader {
        if let reader = self.readerStorage { return reader }

        let reader = SequentialReader()
        self.readerStorage = reader
        return reader
    }

    var writer: SequentialWriter {
        if let writer = self.writerStorage { return writer }

        let writer = SequentialWriter()
        self.writerStorage = writer
        return writer
    }

    /// The state machine a progressive read runs on, made only when one is started.
    ///
    /// Absent for a sequential read, which is the ordinary case: the two are alternatives, and a
    /// structure that had both would be one that had not decided how it is being driven.
    var progressive: ProgressiveReader?

    /// Which filters the client will allow the encoder to choose between.
    public var filters: FilterMask = .all

    /// How the image data is to be compressed.
    public var compression = CompressionSettings()

    /// How text is to be compressed, which a client sets separately.
    ///
    /// Separately because the two are compressing different things: the image data is large and
    /// benefits from a large window, while a text chunk is usually a line or two, where the window
    /// costs memory it will never use.
    public var textCompression = CompressionSettings()

    /// A chunk writer over this context's host and staging buffer.
    ///
    /// Handed out as a value each time rather than kept, so the running check value lives on the
    /// caller's frame: a client jumping out of its own write callback abandons a frame, and a checksum
    /// is the one kind of state that costs nothing to abandon.
    var chunkWriter: ChunkWriter {
        ChunkWriter(
            host: self.host,
            staging: UnsafeMutableBufferPointer(
                start: self.writeStaging.bytes.baseAddress,
                count: self.writeStaging.count
            )
        )
    }

    /// The largest palette index the rows actually used.
    ///
    /// Tracked while the rows are read rather than worked out afterwards, because afterwards the rows
    /// are the client's and this library no longer has them.
    public private(set) var highestPaletteIndex = 0

    /// How many palette entries the rows are entitled to name.
    ///
    /// The file's count until something changes it, and one thing does: shortening the palette leaves
    /// rows entitled to fewer entries than the file's own chunk still describes.  So this is asked of
    /// the reading state rather than of the metadata, and a file whose indices were always inside its
    /// own palette can still be found to have run past the end of the client's.
    public var entitledPaletteCount = 0

    /// Records the largest index in a row of them.
    ///
    /// Given the row rather than one index at a time, because at fewer than eight bits an index is not
    /// a byte and unpacking it is this function's business rather than the caller's.
    public func notePaletteIndices(
        _ row: UnsafeBufferPointer<UInt8>,
        width: Int,
        bitDepth: Int
    ) {
        var largest = self.highestPaletteIndex

        if bitDepth == 8 {
            for pixel in 0 ..< min(width, row.count) {
                largest = max(largest, Int(row[pixel]))
            }
        } else {
            let perByte = 8 / bitDepth
            let mask = (1 << bitDepth) - 1

            for pixel in 0 ..< width {
                let byte = pixel / perByte
                guard byte < row.count else { break }

                let shift = 8 - bitDepth * (pixel % perByte + 1)
                largest = max(largest, (Int(row[byte]) >> shift) & mask)
            }
        }

        self.highestPaletteIndex = largest
    }

    /// What each of the library's own switches is set to, indexed by half the option number.
    ///
    /// Half, because only the even numbers are options: the odd ones are reserved for asking whether
    /// the same option is supported at all.  Eight of them, which is what the API defines room for.
    public var options = [Int32](repeating: 0, count: 8)

    /// Which extensions of a related format are allowed.
    public var mngFeatures: UInt32 = 0

    /// Whether to watch for a palette index the palette does not have.
    public var checksPaletteIndices = false

    /// Where in the file the library currently is, and which chunk it is in.
    ///
    /// For a client watching from inside its own read callback: the callback is handed a count of
    /// bytes and nothing else, so without this it cannot tell a chunk's header from its contents.
    ///
    /// Kept as the API's own bits rather than an enumeration of ours, because that is what a client
    /// compares against.
    public var ioState: UInt32 = 0
    public var ioChunkName = ChunkName(packed: 0)

    /// Records where the reader has got to.
    public func noteIO(_ location: UInt32, chunk: ChunkName? = nil) {
        // The operation half is settled once, by which way the structure was made; the location half
        // changes as the walk goes on.
        let operation: UInt32 = self.isReading ? 0x0001 : 0x0002

        self.ioState = operation | location

        if let chunk { self.ioChunkName = chunk }
    }

    /// What a checksum that does not match should mean, asked separately for the two kinds of chunk.
    ///
    /// Separately because the answers differ: a critical chunk with a bad checksum is a file to give
    /// up on, and an ancillary one is a chunk to drop.
    public var criticalCrcAction: CrcAction = .errorQuit
    public var ancillaryCrcAction: CrcAction = .warnDiscard

    /// What a request to fit the image into fewer colours produced, if one was made.
    ///
    /// The work happens when the request is made, not when the rows are read: the client passes a
    /// palette in and expects to find it shortened when the call returns.
    public var quantization = Quantization()

    /// What the client asked to be done with chunks this library does not know.
    public var unknownChunks = UnknownChunkPolicy()

    /// Whether the client installed a handler for them.
    ///
    /// Separate from the seam's own entry, which the C boundary always fills in: what matters is
    /// whether the *client* asked for one, since that is what says it cares about these chunks.
    public var hasUserChunkCallback = false

    /// The ceilings a decoder will not go past.
    public var limits = DecodeLimits()

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

    /// How the client wants colour and coverage arranged in the rows it receives.
    public var alphaMode: AlphaMode = .png

    /// Whether any arrangement has claimed the blend, which nothing gives back.
    ///
    /// Asking for the format's own arrangement after asking for another does not undo the first: it
    /// turns off the parts that encode, and leaves the blend against black where it was.  So a client
    /// that asks for premultiplied colour and then for the format's own gets colour multiplied by
    /// coverage and encoded for the display it named — which is neither of the two things it asked
    /// for, and is what the reference gives it.
    public var alphaModeComposes = false

    /// The arrangement the pipeline should actually apply.
    ///
    /// The format's own arrangement means "as the file has it" only while nothing has claimed the
    /// blend.  Once something has, it means the blend without either of the encodings.
    var effectiveAlphaMode: AlphaMode {
        guard self.alphaModeComposes else { return .png }

        return self.alphaMode == .png ? .premultiplied : self.alphaMode
    }

    /// What the client says its own transform will leave a row looking like.
    ///
    /// Zero means it did not say, in which case the row keeps the shape the library gave it.  The
    /// library cannot work this out for itself — the transform is the client's code — so the
    /// declaration is taken at its word, and a client that declares wrongly gets rows that do not
    /// match the size it was told.  That is the reference's bargain too.
    public var userTransformDepth = 0
    public var userTransformChannels = 0

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

        // Through the storage rather than the accessor, which would make a writer just to find it
        // has nothing to release.
        self.writerStorage?.deflater?.release()
        self.writerStorage?.deflater = nil

        // One call each rather than a loop over a listing of them: the listing would be an array,
        // allocated on every destruction to name buffers that are usually all empty.
        self.rowBuffer.deallocate(host: self.host)
        self.previousRow.deallocate(host: self.host)
        self.inputBuffer.deallocate(host: self.host)
        self.scratch.deallocate(host: self.host)
        self.writeStaging.deallocate(host: self.host)
        self.textStaging.deallocate(host: self.host)
        self.filterScratch.deallocate(host: self.host)
        self.writeRowBuffer.deallocate(host: self.host)
        self.timeText.deallocate(host: self.host)

        self.rowBuffer = .empty
        self.previousRow = .empty
        self.inputBuffer = .empty
        self.scratch = .empty
        self.writeStaging = .empty
        self.textStaging = .empty
        self.filterScratch = .empty
        self.writeRowBuffer = .empty
        self.timeText = .empty
    }

    /// The buffers `reserve` can grow, named so that reaching one is a switch rather
    /// than a key path: a key path is resolved through the runtime on every access,
    /// and this is called per chunk and per row.
    enum BufferSlot {
        case rowBuffer, previousRow, inputBuffer, scratch, writeStaging
        case textStaging, filterScratch, writeRowBuffer, timeText
    }

    private subscript(slot: BufferSlot) -> RawBuffer {
        get {
            switch slot {
            case .rowBuffer: self.rowBuffer
            case .previousRow: self.previousRow
            case .inputBuffer: self.inputBuffer
            case .scratch: self.scratch
            case .writeStaging: self.writeStaging
            case .textStaging: self.textStaging
            case .filterScratch: self.filterScratch
            case .writeRowBuffer: self.writeRowBuffer
            case .timeText: self.timeText
            }
        }
        set {
            switch slot {
            case .rowBuffer: self.rowBuffer = newValue
            case .previousRow: self.previousRow = newValue
            case .inputBuffer: self.inputBuffer = newValue
            case .scratch: self.scratch = newValue
            case .writeStaging: self.writeStaging = newValue
            case .textStaging: self.textStaging = newValue
            case .filterScratch: self.filterScratch = newValue
            case .writeRowBuffer: self.writeRowBuffer = newValue
            case .timeText: self.timeText = newValue
            }
        }
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
    func reserve(_ buffer: BufferSlot, _ count: Int) throws(Diagnostic) {
        guard count > self[buffer].count else { return }

        let fresh = try RawBuffer.allocate(count, host: self.host)
        let previous = self[buffer]

        self[buffer] = fresh
        previous.deallocate(host: self.host)
    }

    // -- the operations the boundary exposes ---------------------------------
    //
    // Each of these is what one published function does, minus the error
    // reporting: they throw, and the boundary turns that into the client's error
    // handler as the last thing it does.

    public func readInfo(into info: InfoStore) throws(Diagnostic) {
        try self.reader.readInfo(
            into: info,
            context: self,
            signatureBytesConsumed: self.signatureBytesConsumed
        )

        // Both structures describe the image from here on: the info structure for
        // the client's accessors, this one for the reading API.
        self.header = info.header
        self.headerInfo = info

        // A file that named its own gamma is believed over any default, and has to be recorded
        // before returning to the client — a client is free to call `png_set_alpha_mode` right
        // here, before ever calling `png_read_update_info`, and that call also defaults this same
        // field whenever it finds it unset. Recording the real value first is what keeps a default
        // from a client's own gamma-arrangement call from outrunning the file's own chunk and
        // winning by arriving second — updateInfo's later check of the same condition exists for a
        // client that never calls `png_set_alpha_mode` at all, not as the only place this can run.
        if self.gamma.fileGamma == 0, info.isValid(InfoStore.Valid.gama) {
            self.gamma.fileGamma = info.gamma
        }
    }

    public func startReadImage() throws(Diagnostic) {
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
                                  gamma: gamma,
                                  bitDepth: header.bitDepth)
        }

        // A background the client said was already at the output's depth is still not always at
        // the depth the *blend* happens at, because the blend runs before the depth changes.  The
        // reference moves the colour to the blend's own scale in exactly two combinations, and
        // this mirrors both: sixteen bit rows about to be narrowed blend against the colour
        // widened out to their scale, and eight bit rows about to be widened blend against it
        // narrowed — each with the reference's own arithmetic, a truncating multiply one way and
        // its rounding divide the other.
        if self.transformFlags.contains(.compose) {
            func rescale(_ value: inout UInt16) {
                if header.bitDepth == 16,
                   self.transformFlags.contains(.scale16) || self.transformFlags.contains(.strip16) {
                    value = value &* 257
                } else if header.bitDepth != 16, self.transformFlags.contains(.expand16) {
                    value = UInt16((UInt32(value) &* 255 &+ 32767) / 65535)
                }
            }

            rescale(&background.red)
            rescale(&background.green)
            rescale(&background.blue)
            rescale(&background.gray)
        }

        return self.corrected(background, gamma: gamma, bitDepth: header.bitDepth)
    }

    /// Takes the background into the two spaces a blend needs it in.
    ///
    /// Which exponent reaches each depends on the space the client said the colour was in.  A colour
    /// already in the display's terms needs the display's own exponent to become light, and needs no
    /// correction at all to be shown; one given in the file's terms is corrected exactly as the image
    /// is.  Using the image's exponent for a colour that was never in the file's space is the mistake
    /// this exists to avoid.
    private func corrected(
        _ color: Rgb16,
        gamma: GammaState,
        bitDepth: Int
    ) -> ComposeBackground {
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

        // The background is in the image's own scale, so the curve has to be applied in that scale
        // too: a sixteen bit background put through the eight bit table would come back a two hundred
        // and fifty fifth of itself, which is not a darker colour but a different one.
        func apply(_ exponent: FixedPoint?, to color: Rgb16) -> Rgb16 {
            guard let exponent, GammaState.isSignificant(exponent) else { return color }

            var result = color

            guard bitDepth < 16 else {
                let gamma = Double(exponent) * 1e-5

                result.red = GammaTable.correct16(color.red, gamma: gamma)
                result.green = GammaTable.correct16(color.green, gamma: gamma)
                result.blue = GammaTable.correct16(color.blue, gamma: gamma)
                result.gray = GammaTable.correct16(color.gray, gamma: gamma)

                return result
            }

            // The same arithmetic the eight bit table is built from, applied to the four samples
            // here rather than through a table: tabulating all two hundred and fifty six to read
            // four made every update of the description pay for a blend that mostly never happens.
            let gamma = Double(exponent) * 1e-5

            result.red = UInt16(GammaTable.correct8(UInt8(color.red & 0xFF), gamma: gamma))
            result.green = UInt16(GammaTable.correct8(UInt8(color.green & 0xFF), gamma: gamma))
            result.blue = UInt16(GammaTable.correct8(UInt8(color.blue & 0xFF), gamma: gamma))
            result.gray = UInt16(GammaTable.correct8(UInt8(color.gray & 0xFF), gamma: gamma))

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
    func resolveTransforms() throws(Diagnostic) {
        // A progressive read fills in the same structure by a different route, so either is the one
        // to resolve against.
        guard let info = self.headerInfo ?? self.headerInfoForProgressive else {
            throw Diagnostic("no image description to transform")
        }

        try self.updateInfo(info)
    }

    /// Resolves the pipeline at the client's request, recording that it was asked for.
    public func updateInfoForClient(_ info: InfoStore) throws(Diagnostic) {
        try self.updateInfo(info)
        self.clientUpdatedInfo = true
    }

    public func updateInfo(_ info: InfoStore) throws(Diagnostic) {
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
            background: background,
            alphaMode: self.effectiveAlphaMode,
            quantization: self.quantization
        )

        // The correction table is built before the snapshot, because for an indexed image it changes
        // what the snapshot should contain.
        var gammaTable: GammaTable?

        if let exponent = gamma.correctionExponent, GammaState.isSignificant(exponent) {
            gammaTable = GammaTable(exponent: exponent)
        }

        // The pair that take a sample to light and bring it back, together with the correction that is
        // the two composed.  Built whenever something is going to average or blend samples.
        //
        // Each of the three is gated on its own exponent rather than on the group's, and that is the
        // whole of the subtlety here.  A curve that undoes itself over the round trip composes to
        // nothing while each half still bends, so the halves are needed even though the correction is
        // not; and a half too slight to matter is left as the identity even when the other half bends,
        // because the reference does not put samples through a curve it has decided is no curve.
        //
        // The identity is a real table rather than an absence, so that the three always agree about
        // what space a sample is in.
        var blend: (toLinear: GammaTable, fromLinear: GammaTable, corrected: GammaTable)?
        var wideBlend: (toLinear: WideGammaTable, fromLinear: WideGammaTable, corrected: WideGammaTable)?
        var wideGamma: WideGammaTable?

        // The shift the reference's sixteen bit tables quantize their inputs by, and whether the
        // narrowing construction is the one in force — see WideGammaTable.  Zero for an eight bit
        // image, where no sixteen bit row ever exists to be corrected.
        let narrows = header.bitDepth == 16
            && (self.transformFlags.contains(.scale16) || self.transformFlags.contains(.strip16))
        let significantBits = header.colorType.hasColor
            ? max(info.significantBits.red, info.significantBits.green, info.significantBits.blue)
            : info.significantBits.gray
        let wideShift = header.bitDepth == 16
            ? WideGammaTable.shift(significantBits: Int(significantBits), narrows: narrows)
            : 0

        // One sixteen bit correction under the reference's rule: the narrowing construction when
        // the samples are to be narrowed, the direct one under a significant-bits shift, and the
        // exact computation — which is also the reference's full-precision table — with no shift
        // at all.  The exact case snaps an insignificant exponent to the identity the way the
        // eight bit tables do; the quantized constructions must not, because their insignificant
        // entries are the quantization itself, which is the reference's answer too.
        func wideCorrection(_ exponent: FixedPoint) -> WideGammaTable {
            guard wideShift > 0 else {
                return WideGammaTable(
                    exact: GammaState.isSignificant(exponent) ? exponent : GammaState.one
                )
            }

            return narrows
                ? WideGammaTable(narrowing: exponent, shift: wideShift)
                : WideGammaTable(direct: exponent, shift: wideShift)
        }

        if let exponent = gamma.correctionExponent, GammaState.isSignificant(exponent),
           header.bitDepth == 16 {
            wideGamma = wideCorrection(exponent)
        }

        if self.transformFlags.contains(.rgbToGray) || self.transformFlags.contains(.compose)
            || self.transformFlags.contains(.alphaMode),
           let toLinear = gamma.toLinearExponent,
           let fromLinear = gamma.fromLinearExponent {
            let combined = gamma.correctionExponent ?? GammaState.one

            func significant(_ exponent: FixedPoint) -> FixedPoint {
                GammaState.isSignificant(exponent) ? exponent : GammaState.one
            }

            if [toLinear, fromLinear, combined].contains(where: GammaState.isSignificant) {
                blend = (
                    GammaTable(exponent: significant(toLinear)),
                    GammaTable(exponent: significant(fromLinear)),
                    GammaTable(exponent: significant(combined))
                )

                if header.bitDepth == 16 {
                    // The two legs are always the direct construction — the narrowing one exists
                    // only for the combined table, since only a whole correction lands on the
                    // eight bit result directly.
                    wideBlend = (
                        toLinear: wideShift > 0
                            ? WideGammaTable(direct: toLinear, shift: wideShift)
                            : WideGammaTable(exact: significant(toLinear)),
                        fromLinear: wideShift > 0
                            ? WideGammaTable(direct: fromLinear, shift: wideShift)
                            : WideGammaTable(exact: significant(fromLinear)),
                        corrected: wideCorrection(combined)
                    )
                }
            }
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

        // Rearranging the alpha of an indexed image is the same operation against black, and differs in
        // one way only: the transparency is not consumed.  Compositing removes coverage from the image,
        // so the table has nothing left to say; this arrangement keeps it, and a client that goes on to
        // expand the palette gets the coverage as a channel alongside the colour it has been applied to.
        if program.arrangesAlpha, header.colorType.isIndexed, hadTransparency {
            info.composePalette(
                background: ComposeBackground(),
                toLinear: blend?.toLinear,
                fromLinear: blend?.fromLinear,
                corrected: blend?.corrected
            )
        }

        if program.composes, header.colorType.isIndexed, hadTransparency {
            info.composePalette(
                background: background,
                toLinear: blend?.toLinear,
                fromLinear: blend?.fromLinear,
                corrected: blend?.corrected
            )
            info.consumeTransparency()
        }

        // Three requests the reference cannot honour together: it corrects, it blends, and it averages
        // colour away, and each of the last two wants the correction for itself.  The client is told,
        // once, and the decode goes on — so this is a warning about a result rather than a refusal.
        //
        // Only when all three actually come into force.  An image with nothing to blend has had the
        // blend dropped, and a correction too slight to matter is no correction at all.
        if self.transformFlags.contains(.rgbToGray), program.composes || program.arrangesAlpha,
           blend != nil {
            self.host.warn("libpng does not support gamma+background+rgb_to_gray")
        }

        self.transformInputs = TransformInputs(info)
        self.hasTransparency = hadTransparency

        if let gammaTable {
            self.transformInputs.gammaTable = gammaTable
        }

        self.transformInputs.rgbToGray = self.rgbToGray
        self.transformInputs.quantization = self.quantization

        // The pair that map to linear light and back, built only when something needs to average
        // samples and there is a curve to undo first.  They are built together: converting one way
        // without the other would leave the samples in the wrong space.
        if let blend {
            self.transformInputs.toLinear = blend.toLinear
            self.transformInputs.fromLinear = blend.fromLinear
            self.transformInputs.blendCorrected = blend.corrected
            self.transformInputs.wideBlend = wideBlend
        }

        self.transformInputs.wideGamma = wideGamma

        // What the client asked for wins over what the file recorded: png_set_shift says how far to
        // move the samples, while the chunk only says what was done to them originally.
        if let shiftBits = self.shiftBits {
            try TransformProgram.validateShift(shiftBits, header: header)
            self.transformInputs.significantBits = shiftBits
        }

        var shape = program.resultingShape(
            from: RowInfo(header),
            hasTransparency: info.isValid(InfoStore.Valid.trns)
        )

        // The client's own transform has the last word on the shape, since it runs last.  Only over
        // the depth and the channel count: the reference leaves the colour type saying whatever it
        // said before, so a row can be reported as three channels of colour while carrying one.
        self.applyDeclaredUserShape(to: &shape)

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
                // As the display should see it, rather than as the client gave it.  A client that names
                // a colour in the file's terms is told what that colour turned out to be, which is the
                // only form the answer is useful in — it is the colour its transparent pixels now are.
                var reported = self.compose.color
                reported.red = background.screen.red
                reported.green = background.screen.green
                reported.blue = background.screen.blue
                reported.gray = background.screen.gray

                info.background = reported
            }

        } else if program.arrangesAlpha, !header.colorType.isIndexed {
            // The same replacement, for the same reason: multiplying colour by coverage is blending
            // against black, and the image now describes itself as laid over that.
            info.background = Rgb16()
        }

        // The transparency has become a channel, so there is no longer a table to report.  A client
        // that read one now would apply the transparency a second time.
        if program.consumesTransparency {
            info.consumeTransparency()
        }

        // Everything needed has been copied out, so the structure is not held any longer.
        self.headerInfo = nil
    }

    /// Applies what the client declared its own transform leaves behind.
    ///
    /// Shared by the shape the client is told about and the buffer the row is decoded into, which have
    /// to agree: the transform runs in that buffer, so it has to be big enough for what comes out.
    func applyDeclaredUserShape(to shape: inout RowInfo) {
        guard self.transformFlags.contains(.userTransform) else { return }

        if self.userTransformDepth != 0 {
            shape.bitDepth = self.userTransformDepth
        }

        if self.userTransformChannels != 0 {
            shape.channels = self.userTransformChannels
        }

        shape.resize()
    }

    /// Checks a shift request against the image it will be applied to.
    ///
    /// Passes silently when the header has not been read: there is nothing to check against yet, and
    /// the pipeline checks again when it is built.
    public func validateShift(_ bits: SignificantBits) throws(Diagnostic) {
        guard let header = self.header else { return }

        try TransformProgram.validateShift(bits, header: header)
    }

    // -- writing --------------------------------------------------------------

    /// Records the image the client is about to write, and emits the header for it.
    ///
    /// The fields are checked here rather than taken on trust, and the check is the reader's: an
    /// encoder that will not read back its own output is worse than one that refuses to write.
    public func writeHeader(_ fields: Header.Fields) throws(Diagnostic) {
        guard fields.problems.isEmpty else {
            throw Diagnostic("Invalid IHDR data")
        }

        let header = Header(fields)

        self.header = header
        try self.writer.writeHeader(fields, header, context: self)
    }

    /// Writes the eight bytes that begin a file, if they have not been written.
    public func writeSignature() throws(Diagnostic) {
        try self.writer.beginFile(context: self)
    }

    /// Writes the palette an indexed image cannot be read without.
    ///
    /// Only for an indexed image: a palette is meaningful for others as a suggestion, and this library
    /// does not invent one the client did not ask for.
    public func writePalette(_ info: InfoStore) throws(Diagnostic) {
        guard let header = self.header else { return }

        try self.writer.writeBeforePalette(info, context: self)

        // Only for an indexed image: a palette is meaningful for others as a suggestion, and this
        // library does not invent one the client did not ask for.
        if header.colorType.isIndexed {
            try self.writer.writePalette(info, context: self)
        }

        try self.writer.writeAfterPalette(info, context: self)
        try self.writer.writeUnknown(info, afterImageData: false, context: self)
        try self.writer.writeTextBeforeRows(info, context: self)
    }

    public func writeRow(_ row: UnsafePointer<UInt8>?) throws(Diagnostic) {
        guard let row else { throw Diagnostic("png_write_row given no row") }

        // Sized for what the client is handing over rather than for what the file stores: a client
        // that supplies a filler channel, or a byte per sample, hands over more than the row will be.
        let supplied = self.writer.transforms?.suppliedShape.rowBytes
            ?? self.header?.rowBytes
            ?? 0

        try self.writer.writeRow(
            UnsafeBufferPointer(start: row, count: supplied),
            context: self
        )
    }

    /// Writes every row of an image the client holds whole.
    public func writeImage(rows: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>) throws(Diagnostic) {
        guard let header = self.header else {
            throw Diagnostic("png_write_image called before png_write_info")
        }

        for index in 0 ..< header.height {
            try self.writeRow(rows[index])
        }
    }

    /// How often the output is to be flushed, in rows; zero for never.
    public var flushEveryRows = 0

    /// Starts a chunk the client will fill in itself.
    public func beginChunk(_ name: ChunkName, length: Int) throws(Diagnostic) {
        try self.writer.beginClientChunk(name, length: length, context: self)
    }

    public func writeChunkData(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.writer.writeClientChunkData(bytes, context: self)
    }

    public func endChunk() {
        self.writer.endClientChunk(context: self)
    }

    /// Empties the compressor and asks the caller to push whatever it is holding.
    public func flushOutput() throws(Diagnostic) {
        try self.writer.flush(context: self)
    }

    /// Space for the deprecated timestamp accessor's answer, which it hands back as a pointer.
    ///
    /// On the context because the answer has to outlive the call, and a client is entitled to hold it
    /// until the next one — which is exactly why the call is deprecated.
    public func timestampBuffer() throws(Diagnostic) -> UnsafeMutablePointer<CChar> {
        try self.reserve(.timeText, 32)

        return self.timeText.bytes.baseAddress!
            .withMemoryRebound(to: CChar.self, capacity: 32) { $0 }
    }

    /// Starts the decompressor over, for a client reusing the structure.
    ///
    /// Reports what the decompressor thought of the request, since that is what the call is defined to
    /// return; nothing else about the decode is disturbed.
    public func resetDecompression() -> Int {
        self.inflater?.release()
        self.inflater = nil

        do {
            self.inflater = try InflateStream()
            return 0
        } catch {
            return -4
        }
    }

    public func writeEnd(_ info: InfoStore?) throws(Diagnostic) {
        try self.writer.writeEnd(info, context: self)
    }

    /// Takes the header a progressive read has just parsed.
    ///
    /// The sequential reader does this as part of its own walk; a progressive read has no walk, so the
    /// state machine hands it over here.
    func adoptProgressiveHeader(_ header: Header, info: InfoStore) {
        self.header = header
        self.headerInfoForProgressive = info
    }

    /// The info structure a progressive read is filling in, held for the point where the pipeline is
    /// resolved.
    var headerInfoForProgressive: InfoStore?

    // -- reading what has arrived --------------------------------------------

    /// Hands the state machine everything that has arrived, and reports what it did not take.
    public func processData(_ bytes: UnsafeBufferPointer<UInt8>, info: InfoStore?) throws(Diagnostic) {
        let machine = self.progressive ?? ProgressiveReader()

        self.progressive = machine

        let consumed = try machine.process(bytes, context: self, info: info)

        self.unconsumedBytes = bytes.count - consumed
    }

    /// How much of the last push the client has to hand over again.
    public private(set) var unconsumedBytes = 0

    /// Stops the current push, from inside one of the client's own callbacks.
    public func pauseProcessing(saving: Bool) -> Int {
        self.progressive?.isPaused = true

        // What is left is what the client hands over again.  Saving it is the library's business
        // rather than the client's in the reference too, but the count is what the client is told.
        return self.unconsumedBytes
    }

    /// Counts off the rest of a chunk the client says it has thrown away.
    public func skipRemainingChunk() -> Int {
        self.progressive?.skipRest() ?? 0
    }

    /// Places a pass row into the image a client is assembling.
    public func combineRow(
        into destination: UnsafeMutablePointer<UInt8>,
        from source: UnsafePointer<UInt8>
    ) {
        guard let header = self.header else { return }

        let shape = self.transformedShape ?? RowInfo(header)
        let pass = self.progressive?.pass ?? 0

        guard header.isInterlaced, self.spreadsInterlacedRows else {
            // Nothing to place: the row is the image's own row, so this is a copy.
            destination.update(from: source, count: shape.rowBytes)
            return
        }

        // The pixels are placed at their transformed size rather than their stored one: by this point
        // the pipeline may have widened them, and the row the client is assembling is sized for the
        // result.
        let full = UnsafeMutableBufferPointer(start: destination, count: shape.rowBytes)
        let narrow = UnsafeBufferPointer(start: source, count: shape.rowBytes)

        for column in 0 ..< Adam7.width(ofPass: pass, imageWidth: header.width) {
            PixelCopy.copy(
                from: narrow,
                at: column,
                to: full,
                at: Adam7.imageColumn(ofPass: pass, passColumn: column),
                pixelDepth: shape.pixelDepth
            )
        }
    }

    public func readRow(into destination: UnsafeMutablePointer<UInt8>?) throws(Diagnostic) {
        try self.reader.readRow(into: destination, context: self)
    }

    /// Decodes the whole image, resolving interlacing.
    public func readImage(
        rows: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>
    ) throws(Diagnostic) {
        try self.reader.readImage(rows: rows, context: self)
    }

    /// How many times a client has to read every row to receive the whole image.
    ///
    /// Seven for an interlaced image, one otherwise. Reported by
    /// `png_set_interlace_handling`, which is also how a client asks for the passes to be
    /// spread across full-width rows.
    public func enableInterlaceHandling() -> Int {
        guard let header = self.header, header.isInterlaced else { return 1 }

        // The same call means two things, one per direction, and they are nearly opposites.  A reader
        // asking for this wants the narrow rows of each pass placed into full-width rows for it; a
        // writer asking for it is offering full-width rows and leaving the reduction to the library.
        // What they have in common is the count: seven calls per row either way.
        if self.isReading {
            self.spreadsInterlacedRows = true
        } else {
            self.writer.spreadsPasses = true
        }

        return Adam7.passCount
    }

    /// Which pass the next row belongs to, which `png_get_current_pass_number` reports.
    public var currentPass: UInt8 {
        UInt8(min(self.reader.pass, Adam7.passCount - 1))
    }

    public func readEnd(into info: InfoStore?) throws(Diagnostic) {
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
