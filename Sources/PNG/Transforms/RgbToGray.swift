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

    /// What the client has asked for, kept as two bits rather than one choice.
    ///
    /// This is the reference's arrangement and it is worth spelling out, because it makes repeated
    /// requests behave in a way nobody would design.  Asking to warn sets one bit, asking to fail sets
    /// the other, and asking for neither sets *both*; what happens at a row is decided by which bits
    /// are set, with one bit meaning that thing and two bits meaning silence.
    ///
    /// So a client that asks to warn and then to fail gets neither, and one that asks for silence
    /// first can never be told anything afterwards.  The requests accumulate; they do not replace.
    public struct ErrorActions: OptionSet, Sendable {
        public let rawValue: Int32
        public init(rawValue: Int32) { self.rawValue = rawValue }

        public static let warn = Self(rawValue: 1 << 0)
        public static let error = Self(rawValue: 1 << 1)
    }

    public var errorActions: ErrorActions = []

    /// Records a request, which never takes back an earlier one.
    public mutating func request(_ action: ErrorAction) {
        switch action {
        case .none: self.errorActions.formUnion([.warn, .error])
        case .warn: self.errorActions.insert(.warn)
        case .error: self.errorActions.insert(.error)
        }
    }

    /// What a row with colour in it should produce, once every request is in.
    public var errorAction: ErrorAction {
        switch self.errorActions {
        case [.warn]: return .warn
        case [.error]: return .error
        default: return .none
        }
    }

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
        wide: (toLinear: WideGammaTable, fromLinear: WideGammaTable, corrected: WideGammaTable)? = nil
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

                if let wide {
                    // The same shape as the eight bit path: through linear to average, and back
                    // again — except that an already grey sample takes the combined correction
                    // directly rather than making the round trip.
                    if r == g, r == b {
                        gray = Int(wide.corrected.correct(UInt16(r)))
                    } else {
                        let linear = Int(wide.toLinear.correct(UInt16(r)))
                            * red
                            + Int(wide.toLinear.correct(UInt16(g)))
                            * green
                            + Int(wide.toLinear.correct(UInt16(b)))
                            * blue
                            + 16384

                        gray = Int(
                            wide.fromLinear.correct(UInt16(clamping: linear >> 15))
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
