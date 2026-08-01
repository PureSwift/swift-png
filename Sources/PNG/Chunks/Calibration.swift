// Calibration.swift - what the samples of an image actually measure
//
// Most images are pictures, and a sample is a colour.  Some are measurements — a depth map, a scan, a
// field of temperatures — and for those a sample is a number on a scale that the file has to describe,
// because nothing else can.
//
// So this chunk says what the scale is: two sample values and what they correspond to, an equation
// relating the rest, the parameters that equation needs, and a name for the unit.  The equations are
// four, they are numbered, and the numbering is the format's.
//
// The parameters are held as text for the same reason the physical scale is: a calibration can span
// any range at all, and no fixed-point form the rest of the format uses would hold both a wavelength
// and a distance between stars.

/// What the samples of an image measure, when they measure something.
public struct Calibration {
    /// The four equations the format defines, by the numbers it gives them.
    public enum Equation: UInt8 {
        /// A straight line: the samples are the measurement, scaled and shifted.
        case linear = 0
        /// A curve that grows by a constant factor, as brightness and sound both do.
        case exponential = 1
        /// The same with an arbitrary base rather than the natural one.
        case arbitraryExponential = 2
        /// Two straight lines with a bend, for a scale that changes behaviour part way.
        case hyperbolic = 3

        /// How many parameters each equation needs, which the file must supply exactly.
        public var parameterCount: Int {
            switch self {
            case .linear: return 2
            case .exponential: return 3
            case .arbitraryExponential: return 3
            case .hyperbolic: return 4
            }
        }
    }

    /// What the calibration is for, which is the chunk's keyword.
    public var purpose = TextStorage()

    /// The two sample values the scale is pinned at.
    public var x0: Int32 = 0
    public var x1: Int32 = 0

    public var equation: UInt8 = 0

    /// What the measurement is in, as text: the format has no list of units to choose from.
    public var unit = TextStorage()

    /// The equation's parameters, as text.
    public var parameters: [TextStorage] = []

    /// The array of pointers `png_get_pCAL` hands back.
    ///
    /// Built when a client asks rather than kept in step with the strings, because it is a view of them
    /// rather than a second copy: what a client is given has to point at the same bytes it would get
    /// from any other route.
    public var parameterPointers = EscapingBuffer<UnsafeMutablePointer<CChar>?>()

    public init() {}

    public func deallocate(host: Host) {
        self.purpose.deallocate(host: host)
        self.unit.deallocate(host: host)

        for parameter in self.parameters {
            parameter.deallocate(host: host)
        }

        self.parameterPointers.deallocate(host: host)
    }
}

/// One palette a file suggests, for a decoder that has to reduce the image to fewer colours.
///
/// Not the palette an indexed image uses — this is advice, and a file may carry any number of these
/// alongside an image of any type.  Each entry carries a frequency as well as a colour, so a decoder
/// reducing the image knows which suggestions matter.
public struct SuggestedPalette {
    public var name = TextStorage()

    /// Eight or sixteen bits per sample, which changes what the entries mean rather than how they are
    /// held: they are widened to sixteen either way, and the depth is what says how to narrow them.
    public var depth: UInt8 = 8

    public var entries = EscapingBuffer<png_sPLT_entry_layout>()

    public init() {}

    public func deallocate(host: Host) {
        self.name.deallocate(host: host)
        self.entries.deallocate(host: host)
    }
}

/// One entry of a suggested palette, laid out as the API publishes it.
///
/// Declared here rather than imported, because this module does not import the C header — and the
/// layout is part of the published interface, so it is written out where a change to it is visible.
public struct png_sPLT_entry_layout {
    public var red: UInt16 = 0
    public var green: UInt16 = 0
    public var blue: UInt16 = 0
    public var alpha: UInt16 = 0
    public var frequency: UInt16 = 0

    public init() {}
}


/// One suggested palette, laid out as the API publishes it.
///
/// The same reasoning as the entry above: written out here because this module does not import the C
/// header, and because a change to a published layout should be visible where it is made.
public struct png_sPLT_layout {
    public var name: UnsafeMutablePointer<CChar>?
    public var depth: UInt8 = 0
    public var entries: UnsafeMutablePointer<png_sPLT_entry_layout>?
    public var nentries: Int32 = 0

    public init() {}
}
