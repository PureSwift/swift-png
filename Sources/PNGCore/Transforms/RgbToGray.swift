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
        weights: RgbToGrayState
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

                // Truncated rather than rounded.  That is the reference's arithmetic, and it is
                // visible: it puts a pixel just under a boundary one value lower than rounding would.
                row[target] = UInt8((red * r + green * g + blue * b) >> 15)

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

                // Rounded here, where the eight bit path truncates.  The asymmetry is the
                // reference's rather than a choice, and it is visible on almost every pixel: the two
                // paths disagree by one wherever the weighted sum lands in the upper half of a step.
                let gray = (red * r + green * g + blue * b + 16384) >> 15

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
