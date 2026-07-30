#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Gamma.swift - correcting for the encoding curve
//
// A file records what exponent its samples were encoded with; a client says what its display
// expects.  Correcting between the two is a per-sample power function, and since the samples are
// small integers the whole of it collapses into a lookup table built once per image.
//
// Bit-exactness matters here more than anywhere else in the library, because a client comparing
// output against another implementation will see every low bit.  Two things make it reachable.  The
// reference build computes these values in double precision rather than through its fixed-point
// logarithm path, so the arithmetic is reproducible rather than a reimplementation of an
// approximation.  And the rounding is stated explicitly below rather than left to a cast.

/// The exponents involved in a correction, and the table they produce.
public struct GammaState: Sendable {
    /// The exponent the file's samples were encoded with, scaled by 100000.
    public var fileGamma: FixedPoint = 0

    /// The exponent the client's display expects, scaled by 100000.
    ///
    /// Zero when the client has not said, which is what leaves the samples alone: correcting for an
    /// unknown display would be guessing.
    public var screenGamma: FixedPoint = 0

    public init() {}

    /// How far from doing nothing an exponent has to be before it is worth applying.
    ///
    /// Below this the correction would move few enough samples that the reference does not bother,
    /// and matching that matters: applying it anyway would change values the reference leaves alone.
    /// The value is the reference build's.
    static let significanceThreshold: FixedPoint = 5_000

    /// One in the same fixed-point scale.
    static let one: FixedPoint = 100_000

    /// Whether an exponent differs enough from one to be worth applying.
    static func isSignificant(_ gamma: FixedPoint) -> Bool {
        gamma < Self.one - Self.significanceThreshold
            || gamma > Self.one + Self.significanceThreshold
    }

    /// The exponent to raise each sample to: the reciprocal of the two gammas multiplied.
    ///
    /// A file encoded at 1/2.2 shown on a display expecting 2.2 needs no correction, and this is
    /// where that falls out — the product is one, so the reciprocal is one.
    ///
    /// Computed in double precision and rounded, which is what the reference does; the intermediate
    /// would overflow a 32-bit integer.
    var correctionExponent: FixedPoint? {
        guard self.screenGamma > 0, self.fileGamma > 0 else { return nil }

        let product = Double(self.fileGamma) * Double(self.screenGamma)
        let reciprocal = (1e15 / product).rounded()

        guard reciprocal.magnitude <= Double(FixedPoint.max) else { return nil }

        return FixedPoint(reciprocal)
    }

    /// Whether a correction would change anything.
    var isWorthApplying: Bool {
        guard let exponent = self.correctionExponent else { return false }
        return Self.isSignificant(exponent)
    }
}

/// A table mapping every eight bit sample to its corrected value.
///
/// Built once per image rather than computed per sample, which is both faster and how the reference
/// does it — and since the table is exhaustive, agreeing with it on all 256 entries is the whole of
/// agreeing on eight bit gamma.
public struct GammaTable {
    public private(set) var values = [UInt8](repeating: 0, count: 256)

    /// Builds the table for an exponent given in the fixed-point scale.
    public init(exponent: FixedPoint) {
        let gamma = Double(exponent) * 1e-5

        for value in 0 ..< 256 {
            self.values[value] = Self.correct8(UInt8(value), gamma: gamma)
        }
    }

    /// One eight bit sample, corrected.
    ///
    /// The ends are fixed points of the curve and are returned unchanged rather than computed: it
    /// costs nothing and removes any question of the arithmetic rounding them off the ends.
    static func correct8(_ value: UInt8, gamma: Double) -> UInt8 {
        guard value > 0, value < 255 else { return value }

        // Rounded by adding a half and taking the floor, which is what the reference does. A cast
        // alone would truncate and be wrong for about half the range.
        let corrected = (255 * pow(Double(value) / 255, gamma) + 0.5).rounded(.down)

        return UInt8(corrected)
    }

    /// One sixteen bit sample, corrected.
    ///
    /// Computed rather than looked up.  A table over sixteen bits would be 65536 entries per image,
    /// and the reference builds a reduced-precision one instead; this computes at full precision,
    /// which is a difference in the low bits for images whose significant-bits chunk asks for less.
    static func correct16(_ value: UInt16, gamma: Double) -> UInt16 {
        guard value > 0, value < 65535 else { return value }

        let corrected = (65535 * pow(Double(value) / 65535, gamma) + 0.5).rounded(.down)

        return UInt16(corrected)
    }
}

extension Transform {
    /// Corrects the colour samples of a row.
    ///
    /// Alpha is left alone: it is a coverage fraction rather than a light level, and correcting it
    /// would change what it means.
    static func gamma(
        _ row: UnsafeMutableBufferPointer<UInt8>,
        _ info: RowInfo,
        table: GammaTable,
        exponent: FixedPoint
    ) {
        // An indexed row holds indices, which name colours rather than being them.  The correction
        // belongs to the palette and is applied there instead.
        guard !info.colorType.isIndexed else { return }

        let colorChannels = info.colorType.hasAlpha ? info.channels - 1 : info.channels

        guard colorChannels > 0 else { return }

        switch info.bitDepth {
        case 8:
            for pixel in 0 ..< info.width {
                let base = pixel * info.channels

                for channel in 0 ..< colorChannels {
                    row[base + channel] = table.values[Int(row[base + channel])]
                }
            }

        case 16:
            let gamma = Double(exponent) * 1e-5

            for pixel in 0 ..< info.width {
                let base = pixel * info.channels * 2

                for channel in 0 ..< colorChannels {
                    let offset = base + channel * 2
                    let value = UInt16(row[offset]) << 8 | UInt16(row[offset + 1])
                    let corrected = GammaTable.correct16(value, gamma: gamma)

                    row[offset] = UInt8(truncatingIfNeeded: corrected >> 8)
                    row[offset + 1] = UInt8(truncatingIfNeeded: corrected)
                }
            }

        case 2, 4:
            // Below a byte the samples are corrected without being widened, by borrowing the eight
            // bit table: each sample is repeated to fill a byte, looked up, and the top bits of the
            // answer kept.  Repeating rather than shifting is what puts the sample at the right place
            // in the table's range — a two bit 3 becomes 255 rather than 192, so it reads as white
            // and comes back as white.
            let depth = info.bitDepth
            let perByte = 8 / depth
            let mask = UInt8((1 << depth) - 1)
            let multiplier: UInt8 = depth == 2 ? 0x55 : 0x11

            for index in 0 ..< info.width {
                let byte = index / perByte
                let position = (perByte - 1 - index % perByte) * depth

                let value = (row[byte] >> position) & mask
                let corrected = table.values[Int(value &* multiplier)] >> (8 - depth)

                row[byte] &= ~(mask << position)
                row[byte] |= (corrected & mask) << position
            }

        default:
            // One bit has only black and white, and neither moves: the correction is a curve through
            // both ends, so there is nothing between them to shift.
            return
        }
    }

    /// Corrects a palette in place.
    ///
    /// An indexed image's samples live in its palette, so this is where the correction goes.  It
    /// happens once per image rather than once per row, which is the reason indexed images are cheap
    /// to gamma-correct at all.
    static func gammaPalette(_ palette: UnsafeMutableBufferPointer<Rgb8>, table: GammaTable) {
        for index in palette.indices {
            palette[index].red = table.values[Int(palette[index].red)]
            palette[index].green = table.values[Int(palette[index].green)]
            palette[index].blue = table.values[Int(palette[index].blue)]
        }
    }
}
