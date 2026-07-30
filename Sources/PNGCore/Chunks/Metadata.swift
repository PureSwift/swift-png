// Metadata.swift - the optional chunks, as values
//
// These are the chunks a decoder may ignore and still produce an image: how the file
// was gamma encoded, what its primaries were, how large a pixel is meant to be, what
// text came with it.  Each is a small value type here, and the accessors in the
// boundary module copy out of them.
//
// Two conventions run through all of it, both inherited from the API being
// implemented.  Real numbers are stored as integers scaled by 100000, because the
// format stores them that way and a client can ask for either the scaled integer or a
// converted double; keeping the integer means the two answers cannot disagree. And
// nothing is validated more strictly than the reference validates it, because a file
// the reference reads has to be a file this reads.

/// A rational stored the way the format stores it: scaled by 100000.
///
/// Kept as the integer rather than converted on the way in, because a client may ask
/// for the scaled value and expect exactly what the file said.
public typealias FixedPoint = Int32

/// The scale the format applies to the rationals it stores.
public let fixedPointScale: Double = 100_000

/// The white point and primaries, as eight scaled rationals.
public struct Chromaticity: Sendable {
    public var whiteX: FixedPoint = 0
    public var whiteY: FixedPoint = 0
    public var redX: FixedPoint = 0
    public var redY: FixedPoint = 0
    public var greenX: FixedPoint = 0
    public var greenY: FixedPoint = 0
    public var blueX: FixedPoint = 0
    public var blueY: FixedPoint = 0

    public init() {}
}

/// The intended size of a pixel, as a resolution and the unit it is expressed in.
public struct PhysicalDimensions: Sendable {
    public var pixelsPerUnitX: UInt32 = 0
    public var pixelsPerUnitY: UInt32 = 0
    /// 0 for an unspecified unit, 1 for metres.
    public var unit: UInt8 = 0

    public init() {}
}

/// Where the image sits on a page or a screen.
public struct ImageOffset: Sendable {
    public var x: Int32 = 0
    public var y: Int32 = 0
    /// 0 for pixels, 1 for micrometres.
    public var unit: UInt8 = 0

    public init() {}
}

/// The physical scale of the image, stored as decimal strings.
///
/// The strings are kept rather than parsed because the format allows a precision that
/// no fixed binary type holds, and a client can ask for them verbatim.
public struct PhysicalScale {
    /// 1 for metres, 2 for radians.
    public var unit: UInt8 = 0
    public var width = TextStorage()
    public var height = TextStorage()

    public init() {}
}

/// How many bits of each channel were significant before the image was widened to its
/// stored depth.
public struct SignificantBits: Sendable {
    public var red: UInt8 = 0
    public var green: UInt8 = 0
    public var blue: UInt8 = 0
    public var gray: UInt8 = 0
    public var alpha: UInt8 = 0

    public init() {}
}

/// A time, as the format records it: always in universal time, to the second.
public struct Timestamp: Sendable {
    public var year: UInt16 = 0
    public var month: UInt8 = 0
    public var day: UInt8 = 0
    public var hour: UInt8 = 0
    public var minute: UInt8 = 0
    public var second: UInt8 = 0

    public init() {}
}

/// The coding parameters of the content, as identifiers into published registries.
///
/// Carried through without interpretation: the values name entries in tables this
/// library does not need to understand to pass them on.
public struct CodingIndependentCodePoints: Sendable {
    public var colorPrimaries: UInt8 = 0
    public var transferFunction: UInt8 = 0
    public var matrixCoefficients: UInt8 = 0
    public var videoFullRangeFlag: UInt8 = 0

    public init() {}
}

/// The light levels the content was mastered for.
public struct ContentLightLevel: Sendable {
    /// Scaled by 10000, as the chunk stores it.
    public var maxContentLightLevel: UInt32 = 0
    public var maxFrameAverageLightLevel: UInt32 = 0

    public init() {}
}

/// The display the content was mastered on.
public struct MasteringDisplayColorVolume: Sendable {
    /// Chromaticity scaled by 50000, which is what this chunk uses rather than the
    /// 100000 the older colour chunks use.
    public var redX: UInt16 = 0
    public var redY: UInt16 = 0
    public var greenX: UInt16 = 0
    public var greenY: UInt16 = 0
    public var blueX: UInt16 = 0
    public var blueY: UInt16 = 0
    public var whiteX: UInt16 = 0
    public var whiteY: UInt16 = 0
    /// Luminance scaled by 10000.
    public var maxLuminance: UInt32 = 0
    public var minLuminance: UInt32 = 0

    public init() {}
}
