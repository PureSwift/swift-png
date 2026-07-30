// ParseMetadata.swift - reading the optional chunks
//
// One function per chunk, each taking the payload and the store to record it in.  They
// are gathered here rather than spread across a file each because they are all the same
// shape — read a few fields, check them, record them — and reading them together is how
// you notice that one has been checked differently from its neighbours.
//
// The order of the two steps matters and is uniform: nothing is recorded until
// everything in the chunk has been read and accepted.  A chunk that turns out to be
// malformed half way through must leave no trace, or a client would see a partly filled
// field it has no way to detect.

extension InfoStore {
    /// The bit `png_get_valid` reports for a chunk, and the flag values are the API's
    /// own so that a client's tests against them work unchanged.
    enum Valid {
        static let gama: UInt32 = 0x0001
        static let sbit: UInt32 = 0x0002
        static let chrm: UInt32 = 0x0004
        static let plte: UInt32 = 0x0008
        static let trns: UInt32 = 0x0010
        static let bkgd: UInt32 = 0x0020
        static let hist: UInt32 = 0x0040
        static let phys: UInt32 = 0x0080
        static let offs: UInt32 = 0x0100
        static let time: UInt32 = 0x0200
        static let pcal: UInt32 = 0x0400
        static let srgb: UInt32 = 0x0800
        static let iccp: UInt32 = 0x1000
        static let splt: UInt32 = 0x2000
        static let scal: UInt32 = 0x4000
        static let idat: UInt32 = 0x8000
        static let exif: UInt32 = 0x10000
        static let cicp: UInt32 = 0x20000
        static let clli: UInt32 = 0x40000
        static let mdcv: UInt32 = 0x80000
    }

    // -- colour ---------------------------------------------------------------

    /// The gamma the file was encoded with, scaled by 100000.
    func parseGamma(_ payload: UnsafeBufferPointer<UInt8>) throws {
        var reader = ByteReader(payload)

        guard payload.count == 4 else {
            throw Diagnostic("invalid", chunk: .gama)
        }

        let gamma = try reader.readUInt32()

        self.gamma = FixedPoint(truncatingIfNeeded: gamma)
        self.markValid(Valid.gama)
    }

    /// The white point and primaries, as eight rationals scaled by 100000.
    func parseChromaticity(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard payload.count == 32 else {
            throw Diagnostic("invalid", chunk: .chrm)
        }

        var reader = ByteReader(payload)
        var chromaticity = Chromaticity()

        chromaticity.whiteX = FixedPoint(truncatingIfNeeded: try reader.readUInt32())
        chromaticity.whiteY = FixedPoint(truncatingIfNeeded: try reader.readUInt32())
        chromaticity.redX = FixedPoint(truncatingIfNeeded: try reader.readUInt32())
        chromaticity.redY = FixedPoint(truncatingIfNeeded: try reader.readUInt32())
        chromaticity.greenX = FixedPoint(truncatingIfNeeded: try reader.readUInt32())
        chromaticity.greenY = FixedPoint(truncatingIfNeeded: try reader.readUInt32())
        chromaticity.blueX = FixedPoint(truncatingIfNeeded: try reader.readUInt32())
        chromaticity.blueY = FixedPoint(truncatingIfNeeded: try reader.readUInt32())

        self.chromaticity = chromaticity
        self.markValid(Valid.chrm)
    }

    /// Which of the four defined rendering intents the file was prepared for.
    func parseSrgb(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard payload.count == 1 else {
            throw Diagnostic("invalid", chunk: .srgb)
        }

        var reader = ByteReader(payload)
        let intent = try reader.readUInt8()

        guard intent < 4 else {
            throw Diagnostic("invalid rendering intent", chunk: .srgb)
        }

        self.srgbIntent = intent
        self.markValid(Valid.srgb)
    }

    /// How many bits of each channel were significant before the image was widened.
    ///
    /// The chunk carries only the channels the image has, but the reported structure has a
    /// field for every channel, and the unmentioned ones are not left at zero: a greyscale
    /// image's value is mirrored into the colour channels, and an image without an alpha
    /// channel reports the image's own bit depth as its alpha precision. Both are
    /// conveniences the reference provides, and clients read them.
    func parseSignificantBits(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard let header = self.header else {
            throw Diagnostic("missing IHDR", chunk: .sbit)
        }

        // One value per channel the image has.  An indexed image reports three, for the
        // palette's channels rather than for its single index.
        let expected = header.colorType.isIndexed ? 3 : header.channels

        guard payload.count == expected else {
            throw Diagnostic("invalid", chunk: .sbit)
        }

        var reader = ByteReader(payload)
        var bits = SignificantBits()

        if header.colorType.hasColor || header.colorType.isIndexed {
            bits.red = try reader.readUInt8()
            bits.green = try reader.readUInt8()
            bits.blue = try reader.readUInt8()
        } else {
            let gray = try reader.readUInt8()
            bits.gray = gray
            bits.red = gray
            bits.green = gray
            bits.blue = gray
        }

        bits.alpha = header.colorType.hasAlpha
            ? try reader.readUInt8()
            : UInt8(header.bitDepth)

        self.significantBits = bits
        self.markValid(Valid.sbit)
    }

    // -- palette and transparency ---------------------------------------------

    /// The palette, which is required for an indexed image and advisory for others.
    func parsePalette(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard let header = self.header else {
            throw Diagnostic("missing IHDR", chunk: .plte)
        }

        guard payload.count % 3 == 0 else {
            throw Diagnostic("invalid", chunk: .plte)
        }

        let stored = payload.count / 3

        guard stored > 0, stored <= 256 else {
            throw Diagnostic("Invalid palette size", chunk: .plte)
        }

        // Entries beyond what the bit depth can address are unreachable, and the reference
        // drops them silently rather than refusing the file, so a stream with a longer
        // palette than it can use still decodes.
        let count = header.colorType.isIndexed
            ? min(stored, 1 << header.bitDepth)
            : stored

        var reader = ByteReader(payload)
        let palette = try EscapingBuffer<Rgb8>.allocated(count, host: self.host)
        let entries = palette.elements

        for index in 0 ..< count {
            entries[index] = Rgb8(
                red: try reader.readUInt8(),
                green: try reader.readUInt8(),
                blue: try reader.readUInt8()
            )
        }

        self.palette.deallocate(host: self.host)
        self.palette = palette
        self.markValid(Valid.plte)
    }

    /// Transparency: one alpha per palette entry for an indexed image, or a single
    /// colour to treat as transparent otherwise.
    func parseTransparency(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard let header = self.header else {
            throw Diagnostic("missing IHDR", chunk: .trns)
        }

        var reader = ByteReader(payload)

        if header.colorType.isIndexed {
            // The table is sized against the palette, so it cannot precede it.
            guard !self.palette.isEmpty else {
                throw Diagnostic("out of place", chunk: .trns)
            }

            guard payload.count > 0, payload.count <= self.palette.count else {
                throw Diagnostic("Invalid", chunk: .trns)
            }

            var alpha = try EscapingBuffer<UInt8>.allocated(payload.count, host: self.host)
            let entries = alpha.elements

            for index in 0 ..< payload.count {
                entries[index] = try reader.readUInt8()
            }

            self.transparentAlpha.deallocate(host: self.host)
            self.transparentAlpha = alpha
            self.transparentCount = payload.count
        } else if header.colorType.hasAlpha {
            // An image that already carries alpha has no use for this.
            throw Diagnostic("Invalid", chunk: .trns)
        } else {
            let expected = header.colorType.hasColor ? 6 : 2

            guard payload.count == expected else {
                throw Diagnostic("Invalid", chunk: .trns)
            }

            var color = Rgb16()

            if header.colorType.hasColor {
                color.red = try reader.readUInt16()
                color.green = try reader.readUInt16()
                color.blue = try reader.readUInt16()
            } else {
                color.gray = try reader.readUInt16()
            }

            self.transparentColor = color
            self.transparentCount = 0
        }

        self.markValid(Valid.trns)
    }

    /// The colour to composite against, for a client that wants one.
    ///
    /// The values are stored at sixteen bits whatever the image's depth, so a file can
    /// name a background the image itself could never contain. The reference refuses those
    /// rather than clamping, since compositing against a colour outside the image's range
    /// would produce something the client did not ask for.
    func parseBackground(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard let header = self.header else {
            throw Diagnostic("missing IHDR", chunk: .bkgd)
        }

        // An index for an indexed image, one channel for greyscale, three for colour.
        let expected: Int
        if header.colorType.isIndexed {
            expected = 1
        } else if header.colorType.hasColor {
            expected = 6
        } else {
            expected = 2
        }

        guard payload.count == expected else {
            throw Diagnostic("invalid", chunk: .bkgd)
        }

        var reader = ByteReader(payload)
        var background = Rgb16()

        if header.colorType.isIndexed {
            // Indexes into the palette, so the palette has to be known already.
            guard !self.palette.isEmpty else {
                throw Diagnostic("out of place", chunk: .bkgd)
            }

            background.index = try reader.readUInt8()

            guard Int(background.index) < self.palette.count else {
                throw Diagnostic("invalid index", chunk: .bkgd)
            }

            // Resolved through the palette, so a client that wants the colour does not
            // have to look it up itself.
            let entry = self.palette.elements[Int(background.index)]
            background.red = UInt16(entry.red)
            background.green = UInt16(entry.green)
            background.blue = UInt16(entry.blue)
        } else if header.colorType.hasColor {
            background.red = try reader.readUInt16()
            background.green = try reader.readUInt16()
            background.blue = try reader.readUInt16()

            let limit = self.maximumSample(header)

            guard background.red <= limit, background.green <= limit,
                  background.blue <= limit else {
                throw Diagnostic("invalid color", chunk: .bkgd)
            }
        } else {
            background.gray = try reader.readUInt16()

            guard background.gray <= self.maximumSample(header) else {
                throw Diagnostic("invalid gray level", chunk: .bkgd)
            }

            // Mirrored into the colour channels, as the significant bits are.
            background.red = background.gray
            background.green = background.gray
            background.blue = background.gray
        }

        self.background = background
        self.markValid(Valid.bkgd)
    }

    /// The largest sample value the image's bit depth can express.
    private func maximumSample(_ header: Header) -> UInt16 {
        header.bitDepth >= 16 ? UInt16.max : UInt16(1 << header.bitDepth) - 1
    }

    /// How often each palette entry is used, for a viewer that has to reduce the
    /// palette and wants to know which entries matter.
    func parseHistogram(_ payload: UnsafeBufferPointer<UInt8>) throws {
        // Sized against the palette, so it cannot precede it.
        guard !self.palette.isEmpty else {
            throw Diagnostic("invalid", chunk: .hist)
        }

        guard payload.count == self.palette.count * 2 else {
            throw Diagnostic("invalid", chunk: .hist)
        }

        var reader = ByteReader(payload)
        let histogram = try EscapingBuffer<UInt16>.allocated(
            self.palette.count,
            host: self.host
        )
        let entries = histogram.elements

        for index in 0 ..< self.palette.count {
            entries[index] = try reader.readUInt16()
        }

        self.histogram.deallocate(host: self.host)
        self.histogram = histogram
        self.markValid(Valid.hist)
    }

    // -- physical layout ------------------------------------------------------

    /// The intended size of a pixel.
    func parsePhysicalDimensions(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard payload.count == 9 else {
            throw Diagnostic("invalid", chunk: .phys)
        }

        var reader = ByteReader(payload)
        var dimensions = PhysicalDimensions()

        dimensions.pixelsPerUnitX = try reader.readUInt32()
        dimensions.pixelsPerUnitY = try reader.readUInt32()
        dimensions.unit = try reader.readUInt8()

        self.physicalDimensions = dimensions
        self.markValid(Valid.phys)
    }

    /// Where the image sits on its page.
    func parseOffset(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard payload.count == 9 else {
            throw Diagnostic("invalid", chunk: .offs)
        }

        var reader = ByteReader(payload)
        var offset = ImageOffset()

        // Signed, unlike the resolutions: an image may be positioned above or left of
        // the origin.
        offset.x = Int32(bitPattern: try reader.readUInt32())
        offset.y = Int32(bitPattern: try reader.readUInt32())
        offset.unit = try reader.readUInt8()

        self.offset = offset
        self.markValid(Valid.offs)
    }

    /// When the image was last modified, always in universal time.
    func parseTimestamp(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard payload.count == 7 else {
            throw Diagnostic("invalid", chunk: .time)
        }

        var reader = ByteReader(payload)
        var timestamp = Timestamp()

        timestamp.year = try reader.readUInt16()
        timestamp.month = try reader.readUInt8()
        timestamp.day = try reader.readUInt8()
        timestamp.hour = try reader.readUInt8()
        timestamp.minute = try reader.readUInt8()
        timestamp.second = try reader.readUInt8()

        self.timestamp = timestamp
        self.markValid(Valid.time)
    }

    // -- high dynamic range signalling ----------------------------------------

    /// Coding parameters, as indices into published registries.
    func parseCodePoints(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard payload.count == 4 else {
            throw Diagnostic("invalid", chunk: .cicp)
        }

        var reader = ByteReader(payload)
        var points = CodingIndependentCodePoints()

        points.colorPrimaries = try reader.readUInt8()
        points.transferFunction = try reader.readUInt8()
        points.matrixCoefficients = try reader.readUInt8()
        points.videoFullRangeFlag = try reader.readUInt8()

        self.codePoints = points
        self.markValid(Valid.cicp)
    }

    /// The light levels the content was mastered for.
    func parseContentLightLevel(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard payload.count == 8 else {
            throw Diagnostic("invalid", chunk: .clli)
        }

        var reader = ByteReader(payload)
        var level = ContentLightLevel()

        level.maxContentLightLevel = try reader.readUInt32()
        level.maxFrameAverageLightLevel = try reader.readUInt32()

        self.contentLightLevel = level
        self.markValid(Valid.clli)
    }

    /// The display the content was mastered on.
    func parseMasteringDisplay(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard payload.count == 24 else {
            throw Diagnostic("invalid", chunk: .mdcv)
        }

        var reader = ByteReader(payload)
        var display = MasteringDisplayColorVolume()

        display.redX = try reader.readUInt16()
        display.redY = try reader.readUInt16()
        display.greenX = try reader.readUInt16()
        display.greenY = try reader.readUInt16()
        display.blueX = try reader.readUInt16()
        display.blueY = try reader.readUInt16()
        display.whiteX = try reader.readUInt16()
        display.whiteY = try reader.readUInt16()
        display.maxLuminance = try reader.readUInt32()
        display.minLuminance = try reader.readUInt32()

        self.masteringDisplay = display
        self.markValid(Valid.mdcv)
    }

    // -- opaque payloads ------------------------------------------------------

    /// Metadata in the format cameras use, carried without interpretation.
    func parseExif(_ payload: UnsafeBufferPointer<UInt8>) throws {
        guard payload.count > 0 else {
            throw Diagnostic("invalid", chunk: .exif)
        }

        var exif = try EscapingBuffer<UInt8>.allocated(payload.count, host: self.host)

        if let source = payload.baseAddress {
            exif.elements.baseAddress!.update(from: source, count: payload.count)
        }

        self.exif.deallocate(host: self.host)
        self.exif = exif
        self.markValid(Valid.exif)
    }
}
