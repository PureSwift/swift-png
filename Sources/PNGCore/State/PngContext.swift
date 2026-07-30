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
    }

    public func startReadImage() throws {
        try self.reader.startRows(context: self)
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
