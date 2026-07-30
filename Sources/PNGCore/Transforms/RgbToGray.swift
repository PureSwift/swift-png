// RgbToGray.swift - discarding colour
//
// Turning three channels into one is a weighted sum, and the weights matter: the eye is far more
// sensitive to green than to blue, so an unweighted average of a colour image looks wrong in a way
// that is obvious side by side.
//
// The weights are held as integers out of 32768 rather than as fractions, which is what lets the sum
// be computed in integer arithmetic and rounded once at the end.  A client may supply its own, and
// the third is derived rather than asked for, since the three have to add up.

/// How a row's colour is collapsed to a single channel.
public struct RgbToGrayState: Sendable {
    /// The weights, out of 32768.
    ///
    /// The defaults are the reference's, and they are not an even split: green carries most of the
    /// brightness a viewer perceives and blue very little.
    public var red: Int32 = 6968
    public var green: Int32 = 23434

    /// What is left once the other two are taken, so that the three always sum to the whole.
    public var blue: Int32 { 32768 - self.red - self.green }

    /// What to do about a pixel that was not grey to begin with.
    ///
    /// A client converting an image it believes is already grey can ask to be told when it is not,
    /// which is the difference between a conversion and a check.
    public enum ErrorAction: Int32, Sendable {
        /// Convert without comment.
        case none = 1
        /// Warn once if any pixel had colour.
        case warn = 2
        /// Fail if any pixel had colour.
        case error = 3
    }

    public var errorAction: ErrorAction = .none

    /// Whether a pixel with colour has been seen.
    ///
    /// Reported to the client through `png_get_rgb_to_gray_status`, and the reason the check is worth
    /// making at all: it says whether the conversion lost anything.
    public var sawColor = false

    public init() {}
}

extension Transform {
    /// Replaces the three colour channels with one.
    ///
    /// Returns whether any pixel had colour, which the caller records; reporting it is the caller's
    /// job because doing so may run the client's error handler, and this runs per row.
    static func rgbToGray(
        _ row: UnsafeMutableBufferPointer<UInt8>,
        _ info: inout RowInfo,
        weights: RgbToGrayState,
        toLinear: GammaTable? = nil,
        fromLinear: GammaTable? = nil,
        corrected: GammaTable? = nil,
        exponents: (toLinear: Double, fromLinear: Double, corrected: Double)? = nil
    ) -> Bool {
        guard info.colorType.hasColor, !info.colorType.isIndexed, info.bitDepth >= 8 else {
            return false
        }

        let hadAlpha = info.colorType.hasAlpha
        let sourceChannels = info.channels
        let targetChannels = hadAlpha ? 2 : 1

        let red = Int(weights.red)
        let green = Int(weights.green)
        let blue = Int(weights.blue)

        var sawColor = false

        if info.bitDepth == 8 {
            for pixel in 0 ..< info.width {
                let source = pixel * sourceChannels
                let target = pixel * targetChannels

                let r = Int(row[source])
                let g = Int(row[source + 1])
                let b = Int(row[source + 2])

                if r != g || r != b { sawColor = true }

                // Summed on linear light when there is a curve to undo, and on the samples as they
                // stand when there is not.  The distinction matters: a weighted sum of encoded samples
                // is not the encoding of the weighted sum, so averaging without decoding first gives a
                // grey that is wrong by the amount the curve bends.
                if let toLinear, let fromLinear, let corrected {
                    if r == g, r == b {
                        // Already grey, so there is nothing to average and no reason to go through
                        // linear at all: the sample takes the combined correction directly, which is
                        // both cheaper and — because the trip through linear loses precision — a
                        // different answer from the one the general path would give.
                        row[target] = corrected.values[r]
                    } else {
                        // Rounded here, where the sum without a correction truncates.  The two paths
                        // are the reference's and they differ; a pixel converted with a gamma in force
                        // is not the same as one converted without and then corrected.
                        let linear = Int(toLinear.values[r]) * red
                            + Int(toLinear.values[g]) * green
                            + Int(toLinear.values[b]) * blue
                            + 16384

                        row[target] = fromLinear.values[Int(linear >> 15)]
                    }
                } else {
                    // Truncated rather than rounded.  That is the reference's arithmetic, and it is
                    // visible: it puts a pixel just under a boundary one value lower than rounding
                    // would.
                    row[target] = UInt8((red * r + green * g + blue * b) >> 15)
                }

                if hadAlpha {
                    row[target + 1] = row[source + 3]
                }
            }
        } else {
            for pixel in 0 ..< info.width {
                let source = pixel * sourceChannels * 2
                let target = pixel * targetChannels * 2

                let r = Int(row[source]) << 8 | Int(row[source + 1])
                let g = Int(row[source + 2]) << 8 | Int(row[source + 3])
                let b = Int(row[source + 4]) << 8 | Int(row[source + 5])

                if r != g || r != b { sawColor = true }

                let gray: Int

                if let exponents {
                    // The same shape as the eight bit path: through linear to average, and back
                    // again — except that an already grey sample takes the combined correction
                    // directly rather than making the round trip.
                    if r == g, r == b {
                        gray = Int(
                            GammaTable.correct16(UInt16(r), gamma: exponents.corrected)
                        )
                    } else {
                        let linear = Int(GammaTable.correct16(UInt16(r), gamma: exponents.toLinear))
                            * red
                            + Int(GammaTable.correct16(UInt16(g), gamma: exponents.toLinear))
                            * green
                            + Int(GammaTable.correct16(UInt16(b), gamma: exponents.toLinear))
                            * blue
                            + 16384

                        gray = Int(
                            GammaTable.correct16(
                                UInt16(clamping: linear >> 15),
                                gamma: exponents.fromLinear
                            )
                        )
                    }
                } else {
                    // Rounded here, where the eight bit path truncates.  The asymmetry is the
                    // reference's rather than a choice, and it is visible on almost every pixel: the
                    // two paths disagree by one wherever the sum lands in the upper half of a step.
                    gray = (red * r + green * g + blue * b + 16384) >> 15
                }

                row[target] = UInt8(truncatingIfNeeded: gray >> 8)
                row[target + 1] = UInt8(truncatingIfNeeded: gray)

                if hadAlpha {
                    row[target + 2] = row[source + 6]
                    row[target + 3] = row[source + 7]
                }
            }
        }

        info.colorType = hadAlpha ? .grayscaleAlpha : .grayscale
        info.channels = targetChannels
        info.resize()

        return sawColor
    }
}
