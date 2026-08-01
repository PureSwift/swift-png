// AlphaMode.swift - what the alpha channel is taken to mean
//
// The format's own arrangement keeps colour and coverage independent: a pixel's colour is what it
// would be if it were opaque, and the alpha says how much of it to use.  That is convenient to store
// and inconvenient to draw with, because compositing wants the two already multiplied together, and
// wants them as light rather than as encoded samples.
//
// So a client can ask for the row in whichever arrangement suits what it is about to do, and this is
// the set of arrangements the API offers.  Each is a different pair of answers to two questions: is
// the colour multiplied by the coverage, and what space is the result left in.
//
// The arithmetic is the ordinary blend against black, which is what multiplying by coverage is, so
// this stage is compositing with the alpha channel kept rather than consumed — and it is written
// against the same two tables and the same rounding for exactly that reason.
//
// Two things are worth naming because they are easy to get wrong.  A fully opaque pixel is corrected
// once, by the combined curve, rather than being taken to light and back; that is not an optimization
// but the only way to avoid losing precision to a round trip.  And what the client asked for as an
// output gamma is not always what it gets: the premultiplied arrangement is defined in light, so its
// output is linear whatever was asked, which is settled where the request is recorded rather than
// here.

/// How the alpha channel and the colour relate to each other in the row a client receives.
public enum AlphaMode: Int32, Sendable {
    /// The format's own arrangement: colour and coverage independent, samples encoded for the display.
    case png = 0

    /// Colour multiplied by coverage, as light.  What compositing wants.
    case premultiplied = 1

    /// As premultiplied, except that the result is not encoded for the display again.
    ///
    /// The point is that a partly covered pixel is about to be composited by the client anyway, so
    /// encoding it only to have the client undo that is work with nothing to show for it.  Opaque
    /// pixels, which the client can use directly, are corrected as they always are — so the row is
    /// deliberately not all in one space, and the output gamma the client gave is what its opaque
    /// pixels are in.
    case optimized = 2

    /// As premultiplied, and the coverage is itself put through the display's curve.
    ///
    /// Named for what it is: coverage is a fraction of area and has no curve, so encoding it is a
    /// mistake.  The mode exists because some software made that mistake and files exist that expect
    /// it.
    case broken = 3
}

extension Transform {
    /// Rearranges a row into the alpha arrangement the client asked for.
    ///
    /// The three tables are the ones compositing uses and mean the same things: `toLinear` takes a
    /// sample to light, `fromLinear` brings light back to the display's space, and `corrected` is the
    /// two composed — the ordinary correction, applied to the pixels that need no blending.  All three
    /// are absent together when there is no curve in play, in which case the samples are already the
    /// numbers to multiply.
    static func alphaMode(
        _ row: UnsafeMutableBufferPointer<UInt8>,
        _ info: RowInfo,
        mode: AlphaMode,
        toLinear: GammaTable? = nil,
        fromLinear: GammaTable? = nil,
        corrected: GammaTable? = nil,
        exponents: (toLinear: Double, fromLinear: Double, corrected: Double)? = nil
    ) {
        guard mode != .png, info.colorType.hasAlpha, info.bitDepth >= 8 else { return }

        let colorChannels = info.channels - 1

        guard info.bitDepth == 8 else {
            Self.alphaMode16(row, info, mode: mode, exponents: exponents)
            return
        }

        for pixel in 0 ..< info.width {
            let base = pixel * info.channels
            let alphaOffset = base + colorChannels
            let alpha = Int(row[alphaOffset])

            for channel in 0 ..< colorChannels {
                let sample = Int(row[base + channel])

                guard let toLinear, let fromLinear, let corrected else {
                    row[base + channel] = Self.blend8(sample, alpha, 0)
                    continue
                }

                if alpha == 255 {
                    row[base + channel] = corrected.values[sample]
                } else if alpha == 0 {
                    // Nothing of the pixel survives, and the background it is multiplied against is
                    // black, so the answer is black in every space at once.
                    row[base + channel] = 0
                } else {
                    let light = Int(Self.blend8(Int(toLinear.values[sample]), alpha, 0))
                    row[base + channel] = mode == .optimized ? UInt8(truncatingIfNeeded: light)
                        : fromLinear.values[light]
                }
            }

            if mode == .broken, let fromLinear {
                row[alphaOffset] = fromLinear.values[alpha]
            }
        }
    }

    /// Puts the coverage through the display's curve, leaving the colour alone.
    ///
    /// The broken arrangement's other half, for the one case where the two halves have to happen in
    /// different places: an indexed image is multiplied in its palette, since that is where its colour
    /// is, but its coverage does not exist until the palette has been expanded into the row.
    static func encodeAlpha(
        _ row: UnsafeMutableBufferPointer<UInt8>,
        _ info: RowInfo,
        table: GammaTable?
    ) {
        guard let table, info.colorType.hasAlpha, info.bitDepth == 8 else { return }

        let alphaOffset = info.channels - 1

        for pixel in 0 ..< info.width {
            let offset = pixel * info.channels + alphaOffset
            row[offset] = table.values[Int(row[offset])]
        }
    }

    /// The same at sixteen bits, where the curves are computed rather than tabulated.
    ///
    /// A table over sixteen bit samples would be sixty five thousand entries per image, so each sample
    /// is put through the curve as it is reached.  The arrangement is otherwise identical, and so are
    /// the three cases: a covered pixel round trips through light, an uncovered one is black, and a
    /// fully opaque one is corrected once.
    private static func alphaMode16(
        _ row: UnsafeMutableBufferPointer<UInt8>,
        _ info: RowInfo,
        mode: AlphaMode,
        exponents: (toLinear: Double, fromLinear: Double, corrected: Double)?
    ) {
        let colorChannels = info.channels - 1

        for pixel in 0 ..< info.width {
            let base = pixel * info.channels * 2
            let alphaOffset = base + colorChannels * 2
            let alpha = Int(row[alphaOffset]) << 8 | Int(row[alphaOffset + 1])

            for channel in 0 ..< colorChannels {
                let offset = base + channel * 2
                let value = Int(row[offset]) << 8 | Int(row[offset + 1])
                let result: Int

                if let exponents {
                    if alpha == 65535 {
                        result = Int(GammaTable.correct16(UInt16(value), gamma: exponents.corrected))
                    } else if alpha == 0 {
                        result = 0
                    } else {
                        let light = Int(
                            GammaTable.correct16(UInt16(value), gamma: exponents.toLinear)
                        )
                        let blended = Int(Self.blend16(light, alpha, 0))

                        result = mode == .optimized ? blended
                            : Int(GammaTable.correct16(UInt16(blended), gamma: exponents.fromLinear))
                    }
                } else {
                    result = Int(Self.blend16(value, alpha, 0))
                }

                row[offset] = UInt8(truncatingIfNeeded: result >> 8)
                row[offset + 1] = UInt8(truncatingIfNeeded: result)
            }

            if mode == .broken, let exponents {
                let encoded = GammaTable.correct16(UInt16(alpha), gamma: exponents.fromLinear)

                row[alphaOffset] = UInt8(truncatingIfNeeded: encoded >> 8)
                row[alphaOffset + 1] = UInt8(truncatingIfNeeded: encoded)
            }
        }
    }
}
