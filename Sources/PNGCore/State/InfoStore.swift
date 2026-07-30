// InfoStore.swift - what the client reads back about the image
//
// This backs `png_info`.  It holds what the header and the metadata chunks said,
// which is what the accessor functions report.
//
// The distinction that matters here is between values and payloads.  A value like
// the width is copied out to the client and can live as an ordinary Swift
// property.  A payload like the palette is exposed as a pointer the client may
// hold, and may even take ownership of, so it has to be allocated through the
// client's own allocator; those land in a later milestone, and this file grows a
// `RawBuffer` per payload when they do.

/// The image description a client reads through the `png_get_` accessors.
public final class InfoStore {
    /// Present once the header has been parsed. Accessors report zero until then,
    /// which is what a client that asks too early sees.
    public var header: Header?

    /// Which optional chunks were present, as the bits `png_get_valid` reports.
    public var validChunks: UInt32 = 0

    public init() {}

    /// Clears everything, as `png_info_init_3` does for a reused structure.
    public func reset() {
        self.header = nil
        self.validChunks = 0
    }

    // The geometry accessors report zero rather than failing when the header has
    // not been read, matching what the reference implementation does for a client
    // that asks before png_read_info.

    public var width: UInt32 { UInt32(self.header?.width ?? 0) }
    public var height: UInt32 { UInt32(self.header?.height ?? 0) }
    public var bitDepth: UInt8 { UInt8(self.header?.bitDepth ?? 0) }
    public var colorType: UInt8 { self.header?.colorType.rawValue ?? 0 }
    public var channels: UInt8 { UInt8(self.header?.channels ?? 0) }
    public var interlaceType: UInt8 { (self.header?.isInterlaced ?? false) ? 1 : 0 }

    /// Bytes in a row as the client will receive it.
    ///
    /// Equal to the stored row size until transforms are configured, at which
    /// point `png_read_update_info` recomputes it.
    public var rowBytes: Int { self.header?.rowBytes ?? 0 }

    public var pixelDepth: UInt8 { UInt8(self.header?.pixelDepth ?? 0) }
}
