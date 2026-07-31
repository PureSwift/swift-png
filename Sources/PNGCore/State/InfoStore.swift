// InfoStore.swift - what the client reads back about the image
//
// This backs `png_info`.  It holds what the header and the metadata chunks said, which
// is what the accessor functions report.
//
// The distinction that runs through it is between values and payloads.  A value like
// the width or the gamma is copied out to the client and lives as an ordinary Swift
// property.  A payload like the palette is reported as a pointer the client may hold,
// and may take ownership of, so it lives in memory from the client's allocator and is
// released here only while this library still owns it.
//
// Which chunks were present is tracked separately from their contents, in the same bit
// set the API exposes.  A chunk can legitimately carry values that are indistinguishable
// from the defaults, so "was it there" cannot be inferred from what it said.

/// The image description a client reads through the `png_get_` accessors.
public final class InfoStore {
    /// Where payloads are allocated from.
    ///
    /// Held because the memory has to come from the client's allocator, which lives on
    /// the control structure this info structure was created from.
    public let host: Host

    /// Present once the header has been parsed. Accessors report zero until then, which
    /// is what a client that asks too early sees.
    public var header: Header?

    /// Which optional chunks were present, as the bits `png_get_valid` reports.
    public var validChunks: UInt32 = 0

    // -- values ---------------------------------------------------------------

    public var gamma: FixedPoint = 0
    public var chromaticity = Chromaticity()
    public var srgbIntent: UInt8 = 0
    public var significantBits = SignificantBits()
    public var physicalDimensions = PhysicalDimensions()
    public var offset = ImageOffset()
    public var timestamp = Timestamp()
    public var codePoints = CodingIndependentCodePoints()
    public var contentLightLevel = ContentLightLevel()
    public var masteringDisplay = MasteringDisplayColorVolume()

    /// The background colour, in whatever form the image's colour type calls for: a
    /// palette index for an indexed image, channel values otherwise.
    public var background = Rgb16()

    /// How many entries the transparency table holds, for an indexed image.
    public var transparentCount = 0

    /// The transparent colour for a non-indexed image.
    public var transparentColor = Rgb16()

    /// How the profile was compressed. Only one method is defined.
    public var profileCompression: UInt8 = 0


    // -- payloads -------------------------------------------------------------

    public var palette = EscapingBuffer<Rgb8>()

    /// One alpha value per palette entry, for an indexed image.
    public var transparentAlpha = EscapingBuffer<UInt8>()

    /// One frequency per palette entry.
    public var histogram = EscapingBuffer<UInt16>()

    public var profileName = TextStorage()
    public var profile = EscapingBuffer<UInt8>()

    public var exif = EscapingBuffer<UInt8>()

    public var scale = PhysicalScale()

    /// The text entries, in the order they were found.
    ///
    /// A Swift array is safe here even though a client may jump out of a callback: it is
    /// owned by this object rather than by a frame, and growing it uses Swift's allocator,
    /// which cannot transfer control to the client.
    public var textEntries: [TextEntry] = []

    /// The scale as numbers, when the strings it is stored as are numbers at all.
    ///
    /// Absent for a chunk holding something that is not a number, which a file can carry: the accessors
    /// that hand back strings give it to the client unread, and the ones that hand back numbers say
    /// there is nothing to give.
    public var scaleAsNumbers: (width: Double, height: Double)? {
        guard let width = AsciiNumbers.number(from: self.scale.width.bytes),
              let height = AsciiNumbers.number(from: self.scale.height.bytes) else {
            return nil
        }

        return (width, height)
    }

    /// The eight bytes the file began with, kept as they were read.
    ///
    /// Kept whether or not they were right: a client asking what it saw is usually asking because
    /// something went wrong.
    public var signature = (UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                            UInt8(0), UInt8(0), UInt8(0), UInt8(0))

    /// Rows this library allocated, which it therefore has to release.
    ///
    /// Distinct from the pointer below: a client that hands over its own rows keeps them, and a client
    /// that asks the library to read a whole image at once does not.  Holding the two separately is
    /// what makes releasing the right ones possible.
    var ownedRows: RawBuffer = .empty
    var ownedRowCount = 0
    var ownedRowBytes = 0

    /// The rows a client has handed over, for the calls that write or read a whole image at once.
    ///
    /// Not owned: the client allocated them and the client frees them.  Held as the pointer it gave
    /// rather than copied, because `png_get_rows` has to hand back the same pointer.
    public var rows: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?

    /// Storage for the tables the boundary builds in the published structures' layouts.
    ///
    /// Several accessors report a pointer to a structure rather than copying values out, and
    /// those structures are declared in the public header, which this module deliberately
    /// cannot see. So the boundary builds them and these hold them, since they have to live
    /// as long as the pointers handed out of them.
    ///
    /// One slot per field, and not one shared buffer: a client may call two of these
    /// accessors and hold both pointers, and a shared buffer would have the second call
    /// overwrite the first client's data.
    var exportSlots = [RawBuffer](repeating: .empty, count: ExportSlot.count)

    public init(host: Host) {
        self.host = host
    }

    /// Releases every payload, then clears everything.
    ///
    /// Has to work from any state, including one a client jump left half built.
    public func release() {
        self.releaseText()

        for slot in self.exportSlots {
            slot.deallocate(host: self.host)
        }
        self.exportSlots = [RawBuffer](repeating: .empty, count: ExportSlot.count)

        self.releaseOwnedRows()
        self.palette.deallocate(host: self.host)
        self.transparentAlpha.deallocate(host: self.host)
        self.histogram.deallocate(host: self.host)
        self.profile.deallocate(host: self.host)
        self.exif.deallocate(host: self.host)
        self.profileName.deallocate(host: self.host)
        self.scale.width.deallocate(host: self.host)
        self.scale.height.deallocate(host: self.host)

        self.palette = EscapingBuffer()
        self.transparentAlpha = EscapingBuffer()
        self.histogram = EscapingBuffer()
        self.profile = EscapingBuffer()
        self.exif = EscapingBuffer()
        self.profileName = TextStorage()
        self.scale = PhysicalScale()
    }

    /// Clears everything, as `png_info_init_3` does for a reused structure.
    public func reset() {
        self.release()

        self.header = nil
        self.transformedShape = nil
        self.validChunks = 0
        self.gamma = 0
        self.chromaticity = Chromaticity()
        self.srgbIntent = 0
        self.significantBits = SignificantBits()
        self.physicalDimensions = PhysicalDimensions()
        self.offset = ImageOffset()
        self.timestamp = Timestamp()
        self.codePoints = CodingIndependentCodePoints()
        self.contentLightLevel = ContentLightLevel()
        self.masteringDisplay = MasteringDisplayColorVolume()
        self.background = Rgb16()
        self.transparentCount = 0
        self.transparencyConsumed = false
        self.transparentColor = Rgb16()
        self.profileCompression = 0
    }

    /// Which reported structure a slot holds.
    ///
    /// Named rather than counted, so that adding an accessor cannot accidentally reuse
    /// another one's storage.
    public enum ExportSlot: Int, Sendable {
        case significantBits
        case timestamp
        case transparentColor
        case background
        case text

        static let count = 5
    }

    /// Makes room for a table in the published layout, whose element size only the boundary
    /// module knows.
    ///
    /// Reallocated rather than grown in place, and the old table released only after the new
    /// one exists, so that a failure leaves the previous one intact.
    public func reserveExportTable(
        _ slot: ExportSlot,
        byteCount: Int
    ) throws -> UnsafeMutableRawPointer? {
        guard byteCount > 0 else { return nil }

        if self.exportSlots[slot.rawValue].count < byteCount {
            let fresh = try RawBuffer.allocate(byteCount, host: self.host)
            let previous = self.exportSlots[slot.rawValue]

            self.exportSlots[slot.rawValue] = fresh
            previous.deallocate(host: self.host)
        }

        self.exportSlots[slot.rawValue].zero()

        return self.exportSlots[slot.rawValue].base
    }

    /// Records that a chunk was present.
    public func markValid(_ flag: UInt32) {
        self.validChunks |= flag
    }

    public func isValid(_ flag: UInt32) -> Bool {
        self.validChunks & flag != 0
    }

    public func markInvalid(_ flag: UInt32) {
        self.validChunks &= ~flag
    }

    /// The shape the accessors report, once the transforms have been resolved.
    ///
    /// Until then they report what the file stores. After `png_read_update_info` they report what
    /// the client will actually receive, which is what it allocates from.
    public private(set) var transformedShape: RowInfo?

    /// Records the shape rows will have after the transforms.
    public func applyTransformedShape(_ shape: RowInfo) {
        self.transformedShape = shape
    }

    /// Corrects the palette for gamma, in place.
    ///
    /// The entries a client reads back are the corrected ones, because an indexed image's samples are
    /// its palette: correcting a copy and leaving this one alone would have the client's own reading
    /// of the image disagree with the rows it was handed.
    public func applyGammaToPalette(_ table: GammaTable) {
        Transform.gammaPalette(self.palette.elements, table: table)
    }

    /// Lays the palette over a background, using the transparency table for coverage.
    public func composePalette(
        background: ComposeBackground,
        toLinear: GammaTable? = nil,
        fromLinear: GammaTable? = nil,
        corrected: GammaTable? = nil
    ) {
        Transform.composePalette(
            self.palette.elements,
            alphas: UnsafeBufferPointer(self.transparentAlpha.elements),
            background: background,
            toLinear: toLinear,
            fromLinear: fromLinear,
            corrected: corrected
        )
    }

    /// Whether the transparency has been turned into an alpha channel.
    ///
    /// Recorded rather than inferred from the count, which is zero for a non-indexed image whether
    /// anything has happened to it or not.
    public private(set) var transparencyConsumed = false

    /// Notes that the transparency has been folded into an alpha channel.
    ///
    /// The chunk stays marked present and the transparent colour is still reported: what changes is
    /// the count, which is how a client tells there is nothing left to apply.
    public func consumeTransparency() {
        self.transparencyConsumed = true
        self.transparentCount = 0
    }

    // -- derived geometry -----------------------------------------------------
    //
    // These report zero rather than failing when the header has not been read,
    // matching what the reference does for a client that asks before png_read_info.

    public var width: UInt32 { UInt32(self.header?.width ?? 0) }
    public var height: UInt32 { UInt32(self.header?.height ?? 0) }
    public var bitDepth: UInt8 {
        UInt8(self.transformedShape?.bitDepth ?? self.header?.bitDepth ?? 0)
    }
    public var colorType: UInt8 {
        self.transformedShape?.colorType.rawValue ?? self.header?.colorType.rawValue ?? 0
    }
    public var channels: UInt8 {
        UInt8(self.transformedShape?.channels ?? self.header?.channels ?? 0)
    }
    public var interlaceType: UInt8 { (self.header?.isInterlaced ?? false) ? 1 : 0 }

    /// Bytes in a row as the client will receive it.
    ///
    /// Equal to the stored row size until transforms are configured, at which point
    /// `png_read_update_info` recomputes it.
    public var rowBytes: Int {
        self.transformedShape?.rowBytes ?? self.header?.rowBytes ?? 0
    }

    public var pixelDepth: UInt8 {
        UInt8(self.transformedShape?.pixelDepth ?? self.header?.pixelDepth ?? 0)
    }
}

/// A palette entry: three eight bit channels, laid out to match the published
/// structure so that the array can be handed to a client directly.
public struct Rgb8: Sendable {
    public var red: UInt8 = 0
    public var green: UInt8 = 0
    public var blue: UInt8 = 0

    public init() {}

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// A colour at the widest depth the format uses, with a palette index alongside.
///
/// One type covers the background and the transparent colour because the format stores
/// both this way: sixteen bits per channel whatever the image's own depth, plus an index
/// for when the image is indexed.
public struct Rgb16: Sendable {
    public var index: UInt8 = 0
    public var red: UInt16 = 0
    public var green: UInt16 = 0
    public var blue: UInt16 = 0
    public var gray: UInt16 = 0

    public init() {}
}


extension InfoStore {
    /// The signature bytes, addressed rather than copied.
    ///
    /// The tuple lives in this object, so its address is good for as long as the object is.
    public func signatureBytes() -> UnsafePointer<UInt8> {
        withUnsafePointer(to: &self.signature) {
            UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self)
        }
    }

    /// Allocates one row per scanline, for the calls that read a whole image at once.
    ///
    /// One allocation for the rows and one for the pointers to them, rather than one per row: a client
    /// that frees them itself frees the array, and the reference's own arrangement is the same.
    public func allocateRows(rowBytes: Int) throws {
        guard let header = self.header, header.height > 0, rowBytes > 0 else { return }

        self.releaseOwnedRows()

        let pointerSize = MemoryLayout<UnsafeMutablePointer<UInt8>?>.stride
        let buffer = try RawBuffer.allocate(
            header.height * pointerSize + header.height * rowBytes,
            host: self.host
        )

        let base = buffer.bytes.baseAddress!
        let table = UnsafeMutableRawPointer(base)
            .assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self)
        let pixels = base + header.height * pointerSize

        for row in 0 ..< header.height {
            table[row] = pixels + row * rowBytes
        }

        // Cleared, because a client is entitled to look at a row the decode never reached — a
        // truncated file leaves some of these untouched, and untouched must mean blank rather than
        // whatever the allocator had lying about.
        pixels.update(repeating: 0, count: header.height * rowBytes)

        self.ownedRows = buffer
        self.ownedRowCount = header.height
        self.ownedRowBytes = rowBytes
        self.rows = table
    }

    public func releaseOwnedRows() {
        guard !self.ownedRows.isEmpty else { return }

        let buffer = self.ownedRows

        self.ownedRows = .empty
        self.ownedRowCount = 0
        self.ownedRowBytes = 0
        self.rows = nil

        buffer.deallocate(host: self.host)
    }
}
