#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#else
// A target with no C library at all — bare metal, or an embedded sandbox without a libm.
// The correction still needs a power function, so a small one is defined below in terms of
// exp and log series that converge fast over this file's narrow domain: bases in (0, 1] and
// exponents within the range gamma curves use.  Where a libm exists it is preferred, because
// the conformance suites pin this library's tables to the reference's, and the reference
// computes through the platform's own pow.
private func pow(_ base: Double, _ exponent: Double) -> Double {
    guard base > 0 else { return base == 0 ? 0 : .nan }
    guard exponent != 0 else { return 1 }

    // pow(b, e) = exp(e * ln b), with ln computed through atanh for stability near 1:
    // ln(x) = 2 atanh((x-1)/(x+1)), and the atanh series converges quickly because
    // |(x-1)/(x+1)| < 1 for every positive x once x is scaled into [0.5, 2) by pulling
    // out powers of two.
    var mantissa = base
    var exponent2 = 0

    while mantissa >= 2 { mantissa /= 2; exponent2 += 1 }
    while mantissa < 0.5 { mantissa *= 2; exponent2 -= 1 }

    let z = (mantissa - 1) / (mantissa + 1)
    let zSquared = z * z
    var term = z
    var atanh = 0.0

    for index in 0 ..< 32 {
        atanh += term / Double(2 * index + 1)
        term *= zSquared
    }

    let ln2 = 0.693147180559945309417232121458176568
    let logarithm = 2 * atanh + Double(exponent2) * ln2
    var x = exponent * logarithm

    // exp by scaling into a small range and squaring back up, so the series stays short.
    var squarings = 0

    while x > 0.5 { x /= 2; squarings += 1 }
    while x < -0.5 { x /= 2; squarings += 1 }

    var sum = 1.0
    var factorTerm = 1.0

    for index in 1 ..< 24 {
        factorTerm *= x / Double(index)
        sum += factorTerm
    }

    for _ in 0 ..< squarings {
        sum *= sum
    }

    return sum
}
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

    /// The exponent that takes a file's samples to linear light.
    ///
    /// A file's samples are not light levels: they are encoded with the file's own curve, and undoing
    /// that is the reciprocal of it.  Anything that has to *average* samples — discarding colour,
    /// compositing against a background — has to do it here rather than on the encoded values, because
    /// a weighted sum of encoded samples is not the encoding of the weighted sum.
    var toLinearExponent: FixedPoint? {
        Self.reciprocal(of: self.fileGamma)
    }

    /// The exponent that takes linear light back to what the display expects.
    var fromLinearExponent: FixedPoint? {
        Self.reciprocal(of: self.screenGamma)
    }

    /// One over an exponent, in the same fixed-point scale.
    private static func reciprocal(of gamma: FixedPoint) -> FixedPoint? {
        guard gamma > 0 else { return nil }

        let value = (1e10 / Double(gamma)).rounded()

        guard value.magnitude <= Double(FixedPoint.max) else { return nil }

        return FixedPoint(value)
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
    public private(set) var values: [UInt8]

    /// The identity curve, shared: every context starts with it, so building it fresh each time —
    /// let alone through two hundred odd calls to `pow`, as this once did — made creating a context
    /// the most expensive thing a small decode did.  Handing out the one copy is a retain.
    private static let identity = [UInt8](0 ... 255)

    /// Builds the table for an exponent given in the fixed-point scale.
    public init(exponent: FixedPoint) {
        if exponent == GammaState.one {
            self.values = Self.identity
            return
        }

        let gamma = Double(exponent) * 1e-5

        self.values = [UInt8](unsafeUninitializedCapacity: 256) { buffer, count in
            for value in 0 ..< 256 {
                buffer[value] = Self.correct8(UInt8(value), gamma: gamma)
            }
            count = 256
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
    /// which agrees with the reference's own single-value arithmetic — its per-value
    /// `png_gamma_16bit_correct` is this same floating computation — but not with its row tables,
    /// which quantize their inputs.  `WideGammaTable` below is those tables; this is the exact
    /// answer, right for map entries and backgrounds, wrong for rows whenever the table is coarse.
    static func correct16(_ value: UInt16, gamma: Double) -> UInt16 {
        guard value > 0, value < 65535 else { return value }

        let corrected = (65535 * pow(Double(value) / 65535, gamma) + 0.5).rounded(.down)

        return UInt16(corrected)
    }
}

/// The reference's segmented sixteen bit gamma table: what a sixteen bit *row sample* is corrected
/// through, as opposed to the exact per-value computation above.
///
/// The reference never corrects a sixteen bit row sample exactly.  It answers from a table whose
/// input is the sample's top `16 - shift` bits, where the shift comes from two places: a
/// significant-bits chunk saying fewer than sixteen bits are real, and a request to narrow the
/// samples to eight afterwards, which caps the input at eleven bits (the vendored configuration's
/// `PNG_MAX_GAMMA_8`) since precision about to be discarded is not worth correcting.  With no
/// shift at all there is no table to disagree with, and the exact computation stands.
///
/// Two constructions, the reference's own (`png_build_16bit_table` and `png_build_16to8_table`),
/// ported arithmetic step for arithmetic step rather than approximated — the goal is to agree with
/// the reference, not to be more accurate than it:
///
/// - The direct table corrects each quantized input as the sample it stands for, `pow` evaluated
///   at the bucket over its own maximum.  An exponent too slight to matter still quantizes: the
///   entry is the bucket's sample reconstructed, not the input passed through.
/// - The narrowing table inverts the correction instead: it walks the 256 possible eight bit
///   *outputs*, finds the input at the boundary between each adjacent pair — through the
///   reference's fixed-point reciprocal of the exponent, whose rounding is visible in the result —
///   and fills each span with the lower output, widened back out by 257.  This is why a narrowed
///   sixteen bit correction is not "correct, then scale": the table already answers in the eight
///   bit output's own terms.
public struct WideGammaTable {
    /// The exponent, for the exact path a zero shift takes.
    let gamma: Double

    /// How many low input bits the table ignores.
    let shift: Int

    /// The table, indexed by `value >> shift`; empty when the answer is exact.
    let values: [UInt16]

    /// The number of input bits a narrowed sixteen bit correction keeps — `PNG_MAX_GAMMA_8` in the
    /// vendored configuration.
    static let maxGamma8 = 11

    /// The reference's shift for one image: insignificant bits by the significant-bits chunk,
    /// floored at five when the samples are to be narrowed to eight, never more than eight so that
    /// at least one segment survives.
    static func shift(significantBits: Int, narrows: Bool) -> Int {
        var shift = significantBits > 0 && significantBits < 16 ? 16 - significantBits : 0

        if narrows, shift < 16 - Self.maxGamma8 {
            shift = 16 - Self.maxGamma8
        }

        return min(shift, 8)
    }

    /// The exact computation, for a correction with no shift in force: no table, no quantization,
    /// and the same answer `GammaTable.correct16` gives.
    init(exact exponent: FixedPoint) {
        self.gamma = Double(exponent) * 1e-5
        self.shift = 0
        self.values = []
    }

    /// The direct construction — `png_build_16bit_table`.
    ///
    /// The insignificant case still builds, and still quantizes: the entry is the bucket's sample
    /// scaled back to sixteen bits, which is not the identity once the low bits are gone.  The
    /// reference does the same, and the difference shows wherever a sixteen bit file's own curve
    /// is close enough to linear that only the quantization is left.
    init(direct exponent: FixedPoint, shift: Int) {
        precondition(shift > 0)

        self.gamma = Double(exponent) * 1e-5
        self.shift = shift

        let count = 1 << (16 - shift)
        let maximum = count - 1
        let half = 1 << (15 - shift)
        let significant = GammaState.isSignificant(exponent)
        let gamma = self.gamma

        self.values = [UInt16](unsafeUninitializedCapacity: count) { buffer, filled in
            for input in 0 ..< count {
                if significant {
                    let corrected = (65535 * pow(Double(input) / Double(maximum), gamma) + 0.5)
                        .rounded(.down)

                    buffer[input] = UInt16(corrected)
                } else {
                    buffer[input] = UInt16((input * 65535 + half) / maximum)
                }
            }

            filled = count
        }
    }

    /// The narrowing construction — `png_build_16to8_table`.
    ///
    /// Takes the forward correction and inverts it the way the reference does: through the
    /// fixed-point reciprocal, rounded to five decimal places first, because that rounding is part
    /// of where the boundaries land.
    init(narrowing correction: FixedPoint, shift: Int) {
        precondition(shift > 0)

        self.gamma = Double(correction) * 1e-5
        self.shift = shift

        // png_reciprocal: the inverse exponent at the fixed-point scale.
        let inverse = (1e10 / Double(correction) + 0.5).rounded(.down) * 1e-5

        let count = 1 << (16 - shift)
        let maximum = UInt32(count - 1)

        self.values = [UInt16](unsafeUninitializedCapacity: count) { buffer, filled in
            var last = 0

            for output in 0 ..< 255 {
                // The input at the boundary between this output value and the next, found by
                // taking the midpoint of the two sixteen bit outputs back through the inverse —
                // the reference's own `png_gamma_16bit_correct`, which is the exact computation.
                let midpoint = UInt32(output) * 257 + 128
                let boundary16 = (65535 * pow(Double(midpoint) / 65535, inverse) + 0.5)
                    .rounded(.down)

                // Adjusted (rounded) to the table's own input width.
                let bound = Int((UInt32(boundary16) * maximum + 32768) / 65535 + 1)

                while last < bound, last < count {
                    buffer[last] = UInt16(output * 257)
                    last += 1
                }
            }

            while last < count {
                buffer[last] = 65535
                last += 1
            }

            filled = count
        }
    }

    /// One sixteen bit row sample, corrected the way the reference's table answers it.
    func correct(_ value: UInt16) -> UInt16 {
        self.values.isEmpty
            ? GammaTable.correct16(value, gamma: self.gamma)
            : self.values[Int(value) >> self.shift]
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
        exponent: FixedPoint,
        wide: WideGammaTable? = nil
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
            // Through the reference's segmented table when the caller built one — which is
            // whenever a shift is in force — and the exact computation, which is the same as its
            // full-precision table, otherwise.
            let wide = wide ?? WideGammaTable(exact: exponent)

            for pixel in 0 ..< info.width {
                let base = pixel * info.channels * 2

                for channel in 0 ..< colorChannels {
                    let offset = base + channel * 2
                    let value = UInt16(row[offset]) << 8 | UInt16(row[offset + 1])
                    let corrected = wide.correct(value)

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
