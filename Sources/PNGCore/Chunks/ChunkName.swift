// ChunkName.swift - the four-byte chunk type code
//
// A chunk's type is four ASCII letters whose cases carry meaning: each letter's
// fifth bit is a property flag.  Keeping the code packed into a single integer
// makes comparison and dispatch cheap, and lets the property bits be read
// directly rather than tracked separately.

/// The type code of a PNG chunk.
public struct ChunkName: Hashable, Sendable {
    /// The four bytes in stream order, packed big-endian.
    public let packed: UInt32

    public init(packed: UInt32) {
        self.packed = packed
    }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        self.packed = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    /// The bytes in stream order.
    public var bytes: (UInt8, UInt8, UInt8, UInt8) {
        (
            UInt8(truncatingIfNeeded: self.packed >> 24),
            UInt8(truncatingIfNeeded: self.packed >> 16),
            UInt8(truncatingIfNeeded: self.packed >> 8),
            UInt8(truncatingIfNeeded: self.packed)
        )
    }

    /// Whether a decoder may skip this chunk without losing required
    /// information. Encoded as a lowercase first letter.
    public var isAncillary: Bool {
        self.packed & 0x2000_0000 != 0
    }

    /// Whether all four bytes are letters, which is what a chunk type is made of.
    ///
    /// Asked of every chunk as its header arrives.  The four bits that give a chunk its properties
    /// are the case bits of its letters, so a byte outside the alphabet does not describe a chunk
    /// this library could reason about even to ignore it.
    public var isWellFormed: Bool {
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8(truncatingIfNeeded: self.packed >> UInt32(shift))

            let isLetter = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)

            if !isLetter { return false }
        }

        return true
    }

    /// Whether the chunk type is registered in the specification, as opposed to
    /// application-private. Encoded as a lowercase second letter.
    public var isPrivate: Bool {
        self.packed & 0x0020_0000 != 0
    }

    /// Reserved by the specification; an uppercase third letter is required, so
    /// a lowercase one marks a stream written to a later revision than this
    /// library implements.
    public var isReserved: Bool {
        self.packed & 0x0000_2000 != 0
    }

    /// Whether an editor that does not understand this chunk may still copy it
    /// into a rewritten file whose critical chunks changed. Encoded as a
    /// lowercase fourth letter.
    public var isSafeToCopy: Bool {
        self.packed & 0x0000_0020 != 0
    }
}

extension ChunkName {
    // Critical chunks.
    public static let ihdr = Self(0x49, 0x48, 0x44, 0x52)
    public static let plte = Self(0x50, 0x4C, 0x54, 0x45)
    public static let idat = Self(0x49, 0x44, 0x41, 0x54)
    public static let iend = Self(0x49, 0x45, 0x4E, 0x44)

    // Transparency and colour.
    public static let trns = Self(0x74, 0x52, 0x4E, 0x53)
    public static let gama = Self(0x67, 0x41, 0x4D, 0x41)
    public static let chrm = Self(0x63, 0x48, 0x52, 0x4D)
    public static let srgb = Self(0x73, 0x52, 0x47, 0x42)
    public static let iccp = Self(0x69, 0x43, 0x43, 0x50)
    public static let sbit = Self(0x73, 0x42, 0x49, 0x54)
    public static let bkgd = Self(0x62, 0x4B, 0x47, 0x44)
    public static let hist = Self(0x68, 0x49, 0x53, 0x54)
    public static let splt = Self(0x73, 0x50, 0x4C, 0x54)

    // High dynamic range signalling.
    public static let cicp = Self(0x63, 0x49, 0x43, 0x50)
    public static let clli = Self(0x63, 0x4C, 0x4C, 0x49)
    public static let mdcv = Self(0x6D, 0x44, 0x43, 0x56)

    // Text.
    public static let text = Self(0x74, 0x45, 0x58, 0x74)
    public static let ztxt = Self(0x7A, 0x54, 0x58, 0x74)
    public static let itxt = Self(0x69, 0x54, 0x58, 0x74)

    // Physical layout and miscellany.
    public static let phys = Self(0x70, 0x48, 0x59, 0x73)
    public static let offs = Self(0x6F, 0x46, 0x46, 0x73)
    public static let pcal = Self(0x70, 0x43, 0x41, 0x4C)
    public static let scal = Self(0x73, 0x43, 0x41, 0x4C)
    public static let time = Self(0x74, 0x49, 0x4D, 0x45)
    public static let exif = Self(0x65, 0x58, 0x49, 0x66)
}
