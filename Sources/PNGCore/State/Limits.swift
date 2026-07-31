// Limits.swift - what a decoder will not attempt
//
// A file says how large its image is and how much it has to say about itself.  A decoder that believes
// both without limit is a decoder that can be asked to allocate anything, which for a decoder reading
// files it did not make is not a theoretical worry.
//
// The defaults are the reference's, and they are generous rather than safe: they are large enough that
// no ordinary file meets them and small enough that a made-up one cannot ask for everything.

/// The ceilings a decode will not go past.
public struct DecodeLimits: Sendable {
    /// The largest image a decoder will attempt, in pixels.
    public var width: UInt32 = 1_000_000
    public var height: UInt32 = 1_000_000

    /// How many ancillary chunks may be kept.
    ///
    /// Zero means no limit, which is what a client says when it would rather have everything than be
    /// protected from a file that has too much to say.
    public var chunkCache: UInt32 = 1000

    /// The largest any one chunk may be, in bytes.
    ///
    /// A different risk from the count: a thousand small chunks and one enormous one are both ways of
    /// asking a decoder for more memory than it should give.
    public var chunkBytes = 8_000_000

    public init() {}
}
