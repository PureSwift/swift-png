// FilterSelect.swift - choosing how to encode each scanline
//
// Every scanline is stored as a difference from something: from nothing, from the pixel to its left,
// from the pixel above, from their average, or from a prediction built out of all three.  The choice
// is per row and free — the decoder is told which was used — so an encoder picks whichever leaves the
// compressor the least to do.
//
// Which one that is cannot be known without trying, because what matters is not the size of the
// differences but how well they compress, and that is not something you can measure without
// compressing.  So the reference uses a stand-in: the sum of the differences, read as signed bytes and
// taken as distances from zero.  A row of small differences compresses better than a row of large
// ones, usually, and "usually" is all a heuristic promises.
//
// This is the reference's heuristic exactly, and it has to be: a client that compares file sizes
// against the reference would notice any other choice, even a better one.

/// Which filters a client will allow, as the mask `png_set_filter` takes.
public struct FilterMask: OptionSet, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let none = Self(rawValue: 0x08)
    public static let sub = Self(rawValue: 0x10)
    public static let up = Self(rawValue: 0x20)
    public static let average = Self(rawValue: 0x40)
    public static let paeth = Self(rawValue: 0x80)

    public static let all: Self = [.none, .sub, .up, .average, .paeth]

    /// The bit that stands for one filter.
    static func bit(for filter: Filter) -> Self {
        switch filter {
        case .none: return .none
        case .sub: return .sub
        case .up: return .up
        case .average: return .average
        case .paeth: return .paeth
        }
    }
}

enum FilterSelect {
    /// Encodes one scanline into `destination`, choosing among the filters the client allows.
    ///
    /// `destination` holds the filter byte followed by the encoded scanline.  `previous` is the
    /// scanline above as it was *before* encoding — the decoder reconstructs upwards from what it has
    /// already rebuilt, so the encoder has to difference against the same thing.
    ///
    /// Returns the filter chosen, which the caller has already been given in the first byte.
    @discardableResult
    static func encode(
        _ row: UnsafeBufferPointer<UInt8>,
        previous: UnsafeBufferPointer<UInt8>,
        stride: Int,
        allowed: FilterMask,
        into destination: UnsafeMutableBufferPointer<UInt8>,
        scratch: UnsafeMutableBufferPointer<UInt8>
    ) -> Filter {
        let count = row.count

        // A client that allowed nothing gets the filter that does nothing, which is what the reference
        // falls back to and the only choice that is always available.
        var candidates = Filter.allCases.filter { allowed.contains(FilterMask.bit(for: $0)) }

        if candidates.isEmpty {
            candidates = [.none]
        }

        var best = candidates[0]
        var bestCost = Int.max

        // Ties go to the first tried, which is why the candidates are walked in the order the format
        // numbers them: that is the reference's order, and a tie broken the other way would produce a
        // different file.
        //
        // Each candidate is encoded into whichever of the two rows does not hold the best so far,
        // so a winner is a note of where it lies rather than a copy of it, and at most one copy
        // happens at the end.  Where the row lands cannot change the choice, only what it costs.
        let straight = UnsafeMutableBufferPointer(
            start: destination.baseAddress! + 1,
            count: count
        )
        var bestInScratch = false

        for filter in candidates {
            let encoded = UnsafeMutableBufferPointer(
                start: bestInScratch ? straight.baseAddress! : scratch.baseAddress!,
                count: count
            )

            let cost = Self.apply(
                filter,
                row,
                previous: previous,
                stride: stride,
                into: encoded,
                abandonAbove: bestCost
            )

            guard cost < bestCost else { continue }

            bestCost = cost
            best = filter
            bestInScratch = encoded.baseAddress == scratch.baseAddress
        }

        if bestInScratch {
            straight.baseAddress!.update(from: scratch.baseAddress!, count: count)
        }

        destination[0] = best.rawValue

        return best
    }

    /// Writes one filtered scanline and returns the reference's measure of how good it is.
    ///
    /// The measure is the sum of the differences read as signed bytes and taken as distances from
    /// zero, which is what the reference sums and what its choice therefore depends on.
    /// Gives up once `cost` passes `abandonAbove`, leaving the rest of `destination` unwritten: a
    /// candidate that has already lost is not worth finishing.  The check sits between blocks of the
    /// row rather than between bytes, so the loops inside a block stay straight enough to vectorise.
    private static func apply(
        _ filter: Filter,
        _ row: UnsafeBufferPointer<UInt8>,
        previous: UnsafeBufferPointer<UInt8>,
        stride: Int,
        into destination: UnsafeMutableBufferPointer<UInt8>,
        abandonAbove: Int
    ) -> Int {
        let count = row.count
        var cost = 0
        let block = 256

        @inline(__always)
        func record(_ index: Int, _ value: UInt8) {
            destination[index] = value
            cost += value < 128 ? Int(value) : 256 - Int(value)
        }

        // Each filter is two loops rather than one with a branch in it: the first `stride` bytes are
        // the ones whose left-hand neighbours the format defines as zero, and once they are done the
        // test for them has nothing left to catch.
        let prefix = min(stride, count)

        switch filter {
        case .none:
            var start = 0
            while start < count, cost <= abandonAbove {
                for index in start ..< min(start + block, count) {
                    record(index, row[index])
                }
                start += block
            }

        case .sub:
            for index in 0 ..< prefix {
                record(index, row[index])
            }

            var start = prefix
            while start < count, cost <= abandonAbove {
                for index in start ..< min(start + block, count) {
                    record(
                        index,
                        UInt8(truncatingIfNeeded: Int(row[index]) - Int(row[index - stride]))
                    )
                }
                start += block
            }

        case .up:
            var start = 0
            while start < count, cost <= abandonAbove {
                for index in start ..< min(start + block, count) {
                    record(index, UInt8(truncatingIfNeeded: Int(row[index]) - Int(previous[index])))
                }
                start += block
            }

        case .average:
            for index in 0 ..< prefix {
                record(index, UInt8(truncatingIfNeeded: Int(row[index]) - Int(previous[index]) / 2))
            }

            var start = prefix
            while start < count, cost <= abandonAbove {
                for index in start ..< min(start + block, count) {
                    let predicted = (Int(row[index - stride]) + Int(previous[index])) / 2
                    record(index, UInt8(truncatingIfNeeded: Int(row[index]) - predicted))
                }
                start += block
            }

        case .paeth:
            // For the first pixel the prediction collapses to the byte above: with nothing to the
            // left both other candidates are zero, and the tie-breaking picks the same value either
            // way.
            for index in 0 ..< prefix {
                record(index, UInt8(truncatingIfNeeded: Int(row[index]) - Int(previous[index])))
            }

            var start = prefix
            while start < count, cost <= abandonAbove {
                for index in start ..< min(start + block, count) {
                    let predicted = Self.paeth(
                        left: Int(row[index - stride]),
                        above: Int(previous[index]),
                        aboveLeft: Int(previous[index - stride])
                    )

                    record(index, UInt8(truncatingIfNeeded: Int(row[index]) - predicted))
                }
                start += block
            }
        }

        return cost
    }

    /// The prediction the fifth filter subtracts.
    ///
    /// Whichever of the three neighbours is closest to their combination, which is a cheap way of
    /// guessing which direction the picture is smooth in.
    @inline(__always)
    static func paeth(left: Int, above: Int, aboveLeft: Int) -> Int {
        let estimate = left + above - aboveLeft
        let toLeft = abs(estimate - left)
        let toAbove = abs(estimate - above)
        let toAboveLeft = abs(estimate - aboveLeft)

        if toLeft <= toAbove, toLeft <= toAboveLeft { return left }
        if toAbove <= toAboveLeft { return above }

        return aboveLeft
    }
}
