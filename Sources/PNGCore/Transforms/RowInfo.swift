// RowInfo.swift - what a row looks like at one point in the pipeline
//
// A transform changes the shape of a row, not just its contents: unpacking a palette turns one
// byte per pixel into three, stripping alpha removes a channel, expanding to sixteen bits
// doubles every sample.  So each stage needs to know the shape it is given and declare the shape
// it produces, and this is that description.
//
// Channels are tracked separately from the colour type, and that is not redundancy.  Adding a
// filler channel to an RGB row gives four channels while the row is still RGB — the extra
// channel is padding rather than alpha, and a client that asked for a filler is told the row
// still has no alpha.  Deriving the count from the colour type would lose that distinction.

/// The shape of a row, matching the structure a user transform callback is handed.
public struct RowInfo: Sendable {
    public var width: Int
    public var bitDepth: Int

    /// The colour arrangement, which says what the channels mean rather than how many there are.
    public var colorType: ColorType

    /// How many samples each pixel actually holds.
    ///
    /// Usually what the colour type implies, but not always: a filler channel adds one without
    /// making the row an alpha row.
    public var channels: Int

    public var pixelDepth: Int
    public var rowBytes: Int

    public init(width: Int, bitDepth: Int, colorType: ColorType, channels: Int) {
        self.width = width
        self.bitDepth = bitDepth
        self.colorType = colorType
        self.channels = channels
        self.pixelDepth = channels * bitDepth
        self.rowBytes = Header.rowBytes(width: width, pixelDepth: channels * bitDepth)
    }

    /// The shape of a row as the file stores it.
    public init(_ header: Header) {
        self.init(
            width: header.width,
            bitDepth: header.bitDepth,
            colorType: header.colorType,
            channels: header.channels
        )
    }

    /// The shape of one pass's row, which is narrower than the image's.
    public init(_ header: Header, pass: Int) {
        self.init(
            width: Adam7.width(ofPass: pass, imageWidth: header.width),
            bitDepth: header.bitDepth,
            colorType: header.colorType,
            channels: header.channels
        )
    }

    /// Recomputes the sizes after a change to the depth or the channel count.
    ///
    /// Called by every transform that changes either, so that no stage has to remember to keep
    /// the derived numbers in step.
    public mutating func resize() {
        self.pixelDepth = self.channels * self.bitDepth
        self.rowBytes = Header.rowBytes(width: self.width, pixelDepth: self.pixelDepth)
    }

    /// The largest value a sample can hold at this depth.
    public var maximumSample: Int {
        (1 << self.bitDepth) - 1
    }
}
