// Header.swift - the image header, and the geometry everything derives from
//
// IHDR is thirteen bytes, but almost every later decision depends on them: how
// many channels a pixel has, how many bytes a row occupies, how many bytes to
// step back when undoing a filter.  Deriving those once here, at parse time,
// keeps the rest of the engine from recomputing them and disagreeing.

/// How samples are arranged in a pixel.
public struct ColorType: Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let grayscale = Self(rawValue: 0)
    public static let rgb = Self(rawValue: 2)
    public static let palette = Self(rawValue: 3)
    public static let grayscaleAlpha = Self(rawValue: 4)
    public static let rgba = Self(rawValue: 6)

    /// The two flag bits the specification defines, which is why the values are
    /// 0, 2, 3, 4 and 6 rather than consecutive.
    public var hasColor: Bool { self.rawValue & 2 != 0 }
    public var hasAlpha: Bool { self.rawValue & 4 != 0 }
    public var isIndexed: Bool { self.rawValue & 1 != 0 }

    /// Samples per pixel as stored in the file, before any transform.
    public var channels: Int {
        if self.isIndexed { return 1 }
        return (self.hasColor ? 3 : 1) + (self.hasAlpha ? 1 : 0)
    }

    /// Whether the specification permits this depth with this arrangement.
    ///
    /// The rules are not uniform: a palette index is at most 8 bits because it
    /// indexes a table of at most 256 entries, and anything with a colour or alpha
    /// channel starts at 8 because sub-byte samples are only defined for single
    /// channel greyscale.
    func permits(bitDepth: Int) -> Bool {
        switch self {
        case .grayscale: return [1, 2, 4, 8, 16].contains(bitDepth)
        case .palette: return [1, 2, 4, 8].contains(bitDepth)
        case .rgb, .grayscaleAlpha, .rgba: return bitDepth == 8 || bitDepth == 16
        default: return false
        }
    }
}

/// The contents of IHDR, with the geometry the rest of the engine needs.
public struct Header: Sendable {
    public let width: Int
    public let height: Int
    public let bitDepth: Int
    public let colorType: ColorType
    public let isInterlaced: Bool

    /// Bits per pixel as stored, which is what row sizes are computed from.
    public let pixelDepth: Int

    /// Bytes in one unfiltered scanline of the full image width, excluding the
    /// filter byte that precedes it in the stream.
    public let rowBytes: Int

    /// How far back a filter refers, in bytes: one pixel, or one byte when a pixel
    /// is narrower than that.
    public let filterStride: Int

    /// Keeps only the bits of a row's last byte that belong to the image, or nil
    /// when a row fills its last byte exactly.
    ///
    /// A row narrower than a whole number of bytes leaves spare low bits at the
    /// end, and the format says nothing about what an encoder puts there.  The
    /// reference implementation clears them before handing the row over, so that a
    /// client sees the same bytes whatever the encoder happened to write, and this
    /// matches that.
    ///
    /// Only the row given to the client is masked. Reconstruction still refers to
    /// the unmasked bytes, because that is what the encoder's filter was computed
    /// against.
    public let trailingBitMask: UInt8?

    public var channels: Int { self.colorType.channels }

    /// The largest image dimension this library will accept.
    ///
    /// The specification allows up to 2^31 - 1, but a stream claiming that would
    /// have us allocate rows no machine can hold, so it is refused early. The
    /// limit matches the reference build's default.
    public static let dimensionLimit: UInt32 = 1_000_000

    /// The header's fields as stored, before any judgement about whether they are
    /// usable.
    ///
    /// Separated from the validated form because a bad header is reported one
    /// problem at a time, so the fields have to be readable before they are known to
    /// be good.
    public struct Fields {
        public let width: UInt32
        public let height: UInt32
        public let bitDepth: UInt8
        public let colorType: UInt8
        public let compressionMethod: UInt8
        public let filterMethod: UInt8
        public let interlaceMethod: UInt8

        /// Builds the fields directly, for a client describing an image rather than a
        /// stream carrying one.
        public init(
            width: UInt32,
            height: UInt32,
            bitDepth: UInt8,
            colorType: UInt8,
            compressionMethod: UInt8,
            filterMethod: UInt8,
            interlaceMethod: UInt8
        ) {
            self.width = width
            self.height = height
            self.bitDepth = bitDepth
            self.colorType = colorType
            self.compressionMethod = compressionMethod
            self.filterMethod = filterMethod
            self.interlaceMethod = interlaceMethod
        }

        /// Reads the thirteen byte payload.
        ///
        /// Throws only when the payload is not thirteen bytes; anything wrong with
        /// the values themselves is reported through ``problems``.
        public init(parsing payload: UnsafeBufferPointer<UInt8>) throws {
            guard payload.count == 13 else {
                throw Diagnostic("Invalid IHDR data")
            }

            var reader = ByteReader(payload)

            self.width = try reader.readUInt32()
            self.height = try reader.readUInt32()
            self.bitDepth = try reader.readUInt8()
            self.colorType = try reader.readUInt8()
            self.compressionMethod = try reader.readUInt8()
            self.filterMethod = try reader.readUInt8()
            self.interlaceMethod = try reader.readUInt8()
        }

        /// Everything wrong with these fields.
        ///
        /// Empty for a header that can be decoded.
        public var problems: Problems {
            var problems: Problems = []

            // Zero is not a degenerate image but an unusable one: no scanline to
            // decode, and no buffer size to allocate.
            if self.width == 0 { problems.insert(.zeroWidth) }
            if self.height == 0 { problems.insert(.zeroHeight) }

            if self.width > Header.dimensionLimit || self.height > Header.dimensionLimit {
                problems.insert(.oversized)
            }

            let depthIsValid = [1, 2, 4, 8, 16].contains(Int(self.bitDepth))
            if !depthIsValid { problems.insert(.badBitDepth) }

            let colorType = ColorType(rawValue: self.colorType)
            let colorTypeIsValid = [0, 2, 3, 4, 6].contains(Int(self.colorType))

            if !colorTypeIsValid {
                problems.insert(.badColorType)
            } else if !colorType.permits(bitDepth: Int(self.bitDepth)) {
                // Only asked when the colour type itself makes sense, since the pair
                // is what is valid or not.
                problems.insert(.badCombination)
            }

            // One method is defined for each of these, so anything else was written
            // to a specification this library does not implement.
            if self.compressionMethod != 0 { problems.insert(.badCompressionMethod) }
            if self.filterMethod != 0 { problems.insert(.badFilterMethod) }
            if self.interlaceMethod > 1 { problems.insert(.badInterlaceMethod) }

            return problems
        }
    }

    /// Derives the geometry from fields already known to be valid.
    public init(_ fields: Fields) {
        self.width = Int(fields.width)
        self.height = Int(fields.height)
        self.bitDepth = Int(fields.bitDepth)
        self.colorType = ColorType(rawValue: fields.colorType)
        self.isInterlaced = fields.interlaceMethod == 1

        let pixelDepth = self.colorType.channels * self.bitDepth
        self.pixelDepth = pixelDepth
        self.rowBytes = Self.rowBytes(width: self.width, pixelDepth: pixelDepth)
        self.filterStride = max(1, pixelDepth / 8)

        let bitsUsedInLastByte = (self.width * pixelDepth) % 8
        self.trailingBitMask = bitsUsedInLastByte == 0
            ? nil
            : UInt8(truncatingIfNeeded: 0xFF << (8 - bitsUsedInLastByte))
    }

    /// Bytes needed for `width` pixels at `pixelDepth` bits each.
    ///
    /// Rounded up, because a row that ends mid-byte still occupies the whole byte,
    /// with the spare bits unused.
    static func rowBytes(width: Int, pixelDepth: Int) -> Int {
        (width * pixelDepth + 7) / 8
    }
}
