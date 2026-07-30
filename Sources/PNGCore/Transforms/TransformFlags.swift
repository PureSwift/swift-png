// TransformFlags.swift - what the client asked for
//
// A client requests transforms one call at a time and in whatever order suits it, then the
// library applies them in a fixed order of its own.  So the requests are recorded as a set here
// and resolved later; the order the calls arrived in is not kept, because it does not matter.
//
// The bit values are this library's own.  They live behind an opaque structure and no client can
// see them, so what has to match the reference is which combinations mean what — not the numbers.
// Those rules are the interesting part and they are written down in `resolve`.

/// The transforms a client has asked for.
public struct TransformFlags: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Palette entries become colours, and low-depth greyscale becomes eight bit.
    public static let expand = Self(rawValue: 1 << 0)

    /// A transparent colour or palette alpha becomes a real alpha channel.
    public static let expandTransparency = Self(rawValue: 1 << 1)

    /// Greyscale below eight bits becomes eight bit, without touching a palette.
    public static let expandGrayTo8 = Self(rawValue: 1 << 2)

    public static let stripAlpha = Self(rawValue: 1 << 3)
    public static let grayToRgb = Self(rawValue: 1 << 4)

    /// Sixteen bit samples become eight bit by taking the high byte.
    public static let strip16 = Self(rawValue: 1 << 5)

    /// Sixteen bit samples become eight bit by scaling, which is not the same as taking the high
    /// byte and is why both exist.
    public static let scale16 = Self(rawValue: 1 << 6)

    /// Eight bit samples become sixteen bit.
    public static let expand16 = Self(rawValue: 1 << 7)

    /// Samples narrower than a byte are spread one to a byte.
    public static let packing = Self(rawValue: 1 << 8)

    /// The order of sub-byte samples within a byte is reversed.
    public static let packSwap = Self(rawValue: 1 << 9)

    public static let bgr = Self(rawValue: 1 << 10)

    /// The two bytes of each sixteen bit sample are exchanged.
    public static let swapBytes = Self(rawValue: 1 << 11)

    /// Alpha moves from after the colour to before it.
    public static let swapAlpha = Self(rawValue: 1 << 12)

    /// Alpha is stored as transparency rather than opacity.
    public static let invertAlpha = Self(rawValue: 1 << 13)

    /// Greyscale is inverted, so that zero is white.
    public static let invertMono = Self(rawValue: 1 << 14)

    /// A channel of constant value is added.
    public static let filler = Self(rawValue: 1 << 15)

    /// As the filler, but the added channel counts as alpha.
    public static let addAlpha = Self(rawValue: 1 << 16)

    /// Samples are shifted up to occupy the full depth, undoing a narrower original range.
    public static let shift = Self(rawValue: 1 << 17)

    /// Samples are corrected between the file's encoding curve and the display's.
    public static let gamma = Self(rawValue: 1 << 18)

    /// Three colour channels are collapsed into one.
    public static let rgbToGray = Self(rawValue: 1 << 19)

    /// Resolves the requests against the image, adding what one request implies.
    ///
    /// This exists because the requests are not independent.  Asking for the transparency to
    /// become alpha requires the palette to be expanded first, since a palette row has nowhere to
    /// put an alpha channel; and asking to expand an image with no palette and eight bit samples
    /// is asking for nothing at all.  Resolving here rather than at each call site means the
    /// answer does not depend on the order the client called in.
    func resolved(for header: Header, hasTransparency: Bool) -> Self {
        var flags = self

        // Expanding covers separate jobs, and which of them apply depends on the image.
        //
        // Note what is *not* here: expanding does not by itself turn a transparent colour into a
        // channel.  For an indexed image it does, because the palette's alpha comes out with the
        // colours and there is nowhere to leave it; for anything else the transparency stays a
        // transparency unless the client asked otherwise.  That distinction is why asking for colour
        // from a greyscale image leaves an image with a transparent colour still reporting one.
        if flags.contains(.expand) {
            if header.colorType.isIndexed {
                flags.insert(.expandTransparency)
            }

            if header.colorType == .grayscale, header.bitDepth < 8 {
                flags.insert(.expandGrayTo8)
            }
        }

        // Turning a transparent colour into a channel needs somewhere to put it, which a palette
        // row does not have until it has been expanded.
        if flags.contains(.expandTransparency), header.colorType.isIndexed {
            flags.insert(.expand)
        }

        // An image with no transparency to expand has nothing to do here, and leaving the request
        // set would add an opaque channel the client did not ask for.
        if !hasTransparency, !header.colorType.isIndexed {
            flags.remove(.expandTransparency)
        }

        // Discarding colour from an indexed image means expanding the palette first: the colour is in
        // the palette, and an index is not something to take a weighted sum of.  Only for an indexed
        // image, though — a low-depth greyscale one has no colour to discard, so it is left alone
        // rather than widened.
        if flags.contains(.rgbToGray), header.colorType.isIndexed {
            flags.insert(.expand)
        }

        // Asking for colour from a low-depth greyscale image implies widening it first: the
        // format has no sub-byte colour, so the request cannot be honoured any other way.
        if flags.contains(.grayToRgb), header.colorType == .grayscale, header.bitDepth < 8 {
            flags.insert(.expandGrayTo8)
        }

        // Two ways of narrowing sixteen bit samples, and a client that asked for both gets the
        // more accurate one, since that is the reference's precedence.
        if flags.contains(.scale16) {
            flags.remove(.strip16)
        }

        // Widening and narrowing at once is contradictory; the narrowing was asked for second in
        // spirit, and the reference resolves it by dropping the widening.
        if flags.contains(.strip16) || flags.contains(.scale16) {
            flags.remove(.expand16)
        }

        return flags
    }
}
