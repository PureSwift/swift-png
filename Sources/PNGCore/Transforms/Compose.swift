// Compose.swift - laying the image over a background
//
// A client that cannot draw transparency asks for the image to be composited against a colour of its
// choosing, and gets back an image with no alpha channel at all.  The arithmetic is the ordinary
// blend — the pixel's own colour weighted by its coverage, plus the background weighted by what is
// left — and three things about it are worth stating.
//
// It happens on light levels rather than on the samples as stored, when there is a curve to undo:
// blending encoded values gives a result wrong by however much the curve bends.  So the correction
// belongs to this stage, as it does to the conversion that discards colour.
//
// The division is by 255 rather than by 256, because coverage runs from nothing to fully opaque
// inclusive.  Dividing by 256 would leave a fully opaque pixel slightly short of itself.
//
// And the background is expected at the image's own depth: 0 to 255 for an eight bit image and the
// full range for a sixteen bit one.  A client that supplies the wrong scale gets nonsense — that is
// the reference's behaviour and not something to paper over, since papering over it would mean
// guessing which scale was meant.

/// The colour to lay the image over, and how its samples are to be read.
public struct ComposeState: Sendable {
    /// The background, in whatever scale the client supplied.
    public var color = Rgb16()

    /// How the background's own samples are encoded.
    public enum GammaCode: Int32, Sendable {
        case unknown = 0
        /// Already in the display's space, so it needs no correction of its own.
        case screen = 1
        /// In the file's space, so it is corrected along with the image.
        case file = 2
        /// In a space of its own, given separately.
        case unique = 3
    }

    public var gammaCode: GammaCode = .unknown

    /// The background's own exponent, when it is in a space of its own.
    public var gamma: FixedPoint = 0

    /// Whether the background is given in the file's terms rather than the display's.
    ///
    /// A client that names a palette index, or a value at a bit depth the row will be widened out of,
    /// sets this; one that names an ordinary colour does not.
    public var needsExpanding = false

    public init() {}
}

/// The background in the two spaces a blend needs it in.
///
/// A fully transparent pixel becomes the background as the display should see it; a partly covered one
/// is blended against the background as light.  Those are different numbers, and which exponent takes
/// the client's colour to each depends on what space the client said the colour was in — not on the
/// image's own curve.  A colour already in the display's space is taken to light by the display's
/// exponent; one given in the file's terms by the file's.
public struct ComposeBackground: Sendable {
    /// As the display should see it, for a pixel the background shows through completely.
    public var screen = Rgb16()

    /// As light, for blending against.
    public var linear = Rgb16()

    public init() {}

    public init(screen: Rgb16, linear: Rgb16) {
        self.screen = screen
        self.linear = linear
    }
}

extension Transform {
    /// Lays a palette over a background, using the transparency table for coverage.
    ///
    /// An indexed image is composited in its palette rather than in its rows, for the same reason it is
    /// gamma-corrected there: its rows hold indices, which name colours rather than being them.  So the
    /// rows come back untouched and still indexed, and it is the palette that no longer has anything
    /// transparent in it.
    ///
    /// Entries the table does not reach are opaque and keep their colour.
    static func composePalette(
        _ palette: UnsafeMutableBufferPointer<Rgb8>,
        alphas: UnsafeBufferPointer<UInt8>,
        background: ComposeBackground,
        toLinear: GammaTable? = nil,
        fromLinear: GammaTable? = nil,
        corrected: GammaTable? = nil
    ) {
        // One channel at a time through a nested function rather than a loop over key paths:
        // a key path is a runtime object, which some of the platforms this compiles for cannot
        // spend, and three calls say the same thing.
        func compose(
            _ foreground: inout UInt8,
            _ alpha: Int,
            _ screen: Int,
            _ linear: Int
        ) {
            let value = Int(foreground)

            guard let toLinear, let fromLinear, let corrected else {
                foreground = Self.blend8(value, alpha, screen)
                return
            }

            if alpha == 255 {
                foreground = corrected.values[value]
            } else if alpha == 0 {
                foreground = UInt8(truncatingIfNeeded: screen)
            } else {
                let blended = Int(Self.blend8(Int(toLinear.values[value]), alpha, linear))
                foreground = fromLinear.values[blended]
            }
        }

        for index in palette.indices {
            let alpha = index < alphas.count ? Int(alphas[index]) : 255

            compose(
                &palette[index].red,
                alpha,
                Int(background.screen.red),
                Int(background.linear.red)
            )
            compose(
                &palette[index].green,
                alpha,
                Int(background.screen.green),
                Int(background.linear.green)
            )
            compose(
                &palette[index].blue,
                alpha,
                Int(background.screen.blue),
                Int(background.linear.blue)
            )
        }
    }

    /// Lays a row that has no alpha channel over a background, using the transparent colour.
    ///
    /// The other shape compositing takes, and the one that only shows up with the alpha arrangements:
    /// asking for a background expands the transparency into a channel first, so the general path
    /// above handles it, while asking for an arrangement does not — the row still holds the colour the
    /// file called transparent, and it is compared rather than blended.
    ///
    /// There is nothing partial here.  A pixel either is that colour, in which case none of it survives
    /// and the background stands in its place, or it is not, in which case it is simply corrected.  So
    /// this is also where the correction happens for such a row, which is why it takes the table.
    static func composeTransparentColor(
        _ row: UnsafeMutableBufferPointer<UInt8>,
        _ info: RowInfo,
        transparent: Rgb16,
        background: ComposeBackground,
        corrected: GammaTable? = nil
    ) {
        guard !info.colorType.hasAlpha, !info.colorType.isIndexed, info.bitDepth >= 8 else { return }

        let isColor = info.colorType.hasColor

        func samples(of color: Rgb16) -> [Int] {
            isColor
                ? [Int(color.red), Int(color.green), Int(color.blue)]
                : [Int(color.gray)]
        }

        let transparentSamples = samples(of: transparent)
        let backgroundSamples = samples(of: background.screen)
        let channels = info.channels

        if info.bitDepth == 8 {
            for pixel in 0 ..< info.width {
                let base = pixel * channels
                let matches = (0 ..< channels).allSatisfy {
                    Int(row[base + $0]) == transparentSamples[$0] & 0xFF
                }

                for channel in 0 ..< channels {
                    if matches {
                        row[base + channel] =
                            UInt8(truncatingIfNeeded: backgroundSamples[channel])
                    } else if let corrected {
                        row[base + channel] = corrected.values[Int(row[base + channel])]
                    }
                }
            }

            return
        }

        for pixel in 0 ..< info.width {
            let base = pixel * channels * 2
            let matches = (0 ..< channels).allSatisfy {
                (Int(row[base + $0 * 2]) << 8 | Int(row[base + $0 * 2 + 1])) == transparentSamples[$0]
            }

            guard matches else { continue }

            for channel in 0 ..< channels {
                row[base + channel * 2] =
                    UInt8(truncatingIfNeeded: backgroundSamples[channel] >> 8)
                row[base + channel * 2 + 1] =
                    UInt8(truncatingIfNeeded: backgroundSamples[channel])
            }
        }
    }

    /// Blends one sample over a background.
    ///
    /// Divided by 255 rather than shifted by eight: coverage runs from nothing to fully opaque
    /// inclusive, so the divisor is the largest coverage and not one more than it.  The expression is
    /// the usual way of doing that without a division — add the high byte back in and shift — which is
    /// exact for every input rather than approximate.
    @inline(__always)
    static func blend8(_ foreground: Int, _ alpha: Int, _ background: Int) -> UInt8 {
        let total = foreground * alpha + background * (255 - alpha) + 128
        return UInt8(truncatingIfNeeded: (total + (total >> 8)) >> 8)
    }

    /// The same at sixteen bits.
    @inline(__always)
    static func blend16(_ foreground: Int, _ alpha: Int, _ background: Int) -> UInt16 {
        let total = foreground * alpha + background * (65535 - alpha) + 32768
        return UInt16(truncatingIfNeeded: (total + (total >> 16)) >> 16)
    }

    /// Lays a row over a background, leaving it with no alpha channel.
    ///
    /// The background arrives already in the row's own terms — expanded, and at the row's depth —
    /// because working that out needs the palette and the file's depth, which the caller has and this
    /// does not.
    static func compose(
        _ row: UnsafeMutableBufferPointer<UInt8>,
        _ info: inout RowInfo,
        background: ComposeBackground,
        toLinear: GammaTable? = nil,
        fromLinear: GammaTable? = nil,
        corrected: GammaTable? = nil,
        exponents: (toLinear: Double, fromLinear: Double, corrected: Double)? = nil
    ) {
        guard info.colorType.hasAlpha, info.bitDepth >= 8 else { return }

        let isColor = info.colorType.hasColor
        let colorChannels = info.channels - 1
        let sourceChannels = info.channels

        // The background's channels, in the order they appear in the row, in each of the two spaces.
        func channels(of color: Rgb16) -> [Int] {
            isColor
                ? [Int(color.red), Int(color.green), Int(color.blue)]
                : [Int(color.gray)]
        }

        let screenSamples = channels(of: background.screen)
        let linearSamples = channels(of: background.linear)

        if info.bitDepth == 8 {
            for pixel in 0 ..< info.width {
                let source = pixel * sourceChannels
                let target = pixel * colorChannels
                let alpha = Int(row[source + colorChannels])

                for channel in 0 ..< colorChannels {
                    let foreground = Int(row[source + channel])
                    guard let toLinear, let fromLinear, let corrected else {
                        row[target + channel] = Self.blend8(
                            foreground,
                            alpha,
                            screenSamples[channel]
                        )
                        continue
                    }

                    // Fully opaque and fully transparent are not blended at all: one is the pixel and
                    // the other is the background, and sending either through the round trip would
                    // lose precision for no reason.
                    if alpha == 255 {
                        row[target + channel] = corrected.values[foreground]
                    } else if alpha == 0 {
                        row[target + channel] =
                            UInt8(truncatingIfNeeded: screenSamples[channel])
                    } else {
                        let blended = Int(
                            Self.blend8(
                                Int(toLinear.values[foreground]),
                                alpha,
                                linearSamples[channel]
                            )
                        )
                        row[target + channel] = fromLinear.values[blended]
                    }
                }
            }
        } else {
            for pixel in 0 ..< info.width {
                let source = pixel * sourceChannels * 2
                let target = pixel * colorChannels * 2
                let alphaOffset = source + colorChannels * 2
                let alpha = Int(row[alphaOffset]) << 8 | Int(row[alphaOffset + 1])

                for channel in 0 ..< colorChannels {
                    let offset = source + channel * 2
                    let foreground = Int(row[offset]) << 8 | Int(row[offset + 1])
                    let blended: Int

                    // The same three cases as at eight bits, with the curve computed for each sample
                    // rather than looked up: a table over sixteen bit samples would be sixty five
                    // thousand entries per image.
                    if let exponents {
                        if alpha == 65535 {
                            blended = Int(
                                GammaTable.correct16(UInt16(foreground), gamma: exponents.corrected)
                            )
                        } else if alpha == 0 {
                            blended = screenSamples[channel]
                        } else {
                            let light = Int(
                                GammaTable.correct16(UInt16(foreground), gamma: exponents.toLinear)
                            )

                            blended = Int(
                                GammaTable.correct16(
                                    Self.blend16(light, alpha, linearSamples[channel]),
                                    gamma: exponents.fromLinear
                                )
                            )
                        }
                    } else {
                        blended = Int(Self.blend16(foreground, alpha, screenSamples[channel]))
                    }

                    row[target + channel * 2] = UInt8(truncatingIfNeeded: blended >> 8)
                    row[target + channel * 2 + 1] = UInt8(truncatingIfNeeded: blended)
                }
            }
        }

        info.colorType = isColor ? .rgb : .grayscale
        info.channels = colorChannels
        info.resize()
    }
}
