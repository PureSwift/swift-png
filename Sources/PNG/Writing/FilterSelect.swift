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

    /// Sixteen bytes of the row, loaded and stored at once.
    ///
    /// Filtering has no serial dependency, and that is the whole reason a block can be done at a
    /// time: every input a predictor reads comes from the source row or the row above, and this
    /// writes to neither.  Decoding is the opposite — there the left neighbour is a byte the same
    /// loop has just reconstructed — which is why the defilter's loops are shaped differently.
    @inline(__always)
    private static func load(_ bytes: UnsafeBufferPointer<UInt8>, _ index: Int) -> SIMD16<UInt8> {
        UnsafeRawPointer(bytes.baseAddress! + index).loadUnaligned(as: SIMD16<UInt8>.self)
    }

    @inline(__always)
    private static func store(
        _ bytes: UnsafeMutableBufferPointer<UInt8>, _ index: Int, _ value: SIMD16<UInt8>
    ) {
        UnsafeMutableRawPointer(bytes.baseAddress! + index)
            .storeBytes(of: value, as: SIMD16<UInt8>.self)
    }

    /// Writes one filtered scanline and returns the reference's measure of how good it is.
    ///
    /// The measure is the sum of the differences read as signed bytes and taken as distances from
    /// zero, which is what the reference sums and what its choice therefore depends on.  Gives up
    /// once the cost passes `abandonAbove`, leaving the rest of `destination` unwritten: a
    /// candidate that has already lost is not worth finishing, and the caller only compares the
    /// answer against the best so far.
    ///
    /// `lead` is how many leading bytes have no left neighbour, the format defining theirs as
    /// zero; there are at most eight, so they are done one at a time.
    ///
    /// Between flushes the running cost lives in sixteen bit lanes.  A lane takes at most 128 a
    /// step and the block is sixteen steps, so a lane cannot reach its own ceiling; the sum
    /// *across* lanes is widened before it is folded in, which is the step that silently
    /// overflowed when this was first written and made every cost wrong rather than merely slow.
    @inline(__always)
    private static func measure(
        count: Int,
        lead: Int,
        into destination: UnsafeMutableBufferPointer<UInt8>,
        abandonAbove: Int,
        leadByte: (Int) -> UInt8,
        block: (Int) -> SIMD16<UInt8>,
        byte: (Int) -> UInt8
    ) -> Int {
        var cost = 0
        var index = 0

        while index < lead {
            let value = leadByte(index)

            destination[index] = value
            cost += Int(min(value, 0 &- value))
            index += 1
        }

        let vectorEnd = lead + ((count - lead) & ~15)

        while index < vectorEnd {
            // Two hundred and fifty six bytes between checks, which is what the byte-at-a-time
            // form used, so a hopeless candidate is abandoned no later than it was before.
            let stop = min(index + 256, vectorEnd)
            var lanes = SIMD16<UInt16>()

            while index < stop {
                let value = block(index)

                Self.store(destination, index, value)
                lanes &+= SIMD16<UInt16>(truncatingIfNeeded: pointwiseMin(value, 0 &- value))
                index += 16
            }

            cost += Int(SIMD16<UInt32>(truncatingIfNeeded: lanes).wrappedSum())

            guard cost <= abandonAbove else { return cost }
        }

        while index < count {
            let value = byte(index)

            destination[index] = value
            cost += Int(min(value, 0 &- value))
            index += 1
        }

        return cost
    }

    private static func apply(
        _ filter: Filter,
        _ row: UnsafeBufferPointer<UInt8>,
        previous: UnsafeBufferPointer<UInt8>,
        stride: Int,
        into destination: UnsafeMutableBufferPointer<UInt8>,
        abandonAbove: Int
    ) -> Int {
        let count = row.count
        let lead = min(stride, count)

        switch filter {
        case .none:
            return Self.measure(
                count: count, lead: 0, into: destination, abandonAbove: abandonAbove,
                leadByte: { _ in 0 },
                block: { Self.load(row, $0) },
                byte: { row[$0] }
            )

        case .sub:
            return Self.measure(
                count: count, lead: lead, into: destination, abandonAbove: abandonAbove,
                leadByte: { row[$0] },
                block: { Self.load(row, $0) &- Self.load(row, $0 - stride) },
                byte: { row[$0] &- row[$0 - stride] }
            )

        case .up:
            return Self.measure(
                count: count, lead: 0, into: destination, abandonAbove: abandonAbove,
                leadByte: { _ in 0 },
                block: { Self.load(row, $0) &- Self.load(previous, $0) },
                byte: { row[$0] &- previous[$0] }
            )

        case .average:
            // The mean of two bytes wants nine bits before it is halved, which a byte lane has
            // not got.  `(l & a) + ((l ^ a) >> 1)` is that floored mean exactly and stays in
            // eight bits throughout: the bits the AND keeps are the carry the sum would have
            // overflowed into, and halving the rest puts them back where they belong.
            return Self.measure(
                count: count, lead: lead, into: destination, abandonAbove: abandonAbove,
                leadByte: { row[$0] &- (previous[$0] >> 1) },
                block: {
                    let left = Self.load(row, $0 - stride)
                    let above = Self.load(previous, $0)

                    return Self.load(row, $0) &- ((left & above) &+ ((left ^ above) &>> 1))
                },
                byte: {
                    let predicted = (Int(row[$0 - stride]) + Int(previous[$0])) / 2

                    return UInt8(truncatingIfNeeded: Int(row[$0]) - predicted)
                }
            )

        case .paeth:
            // With no left neighbour the estimate reduces to the byte above, so the leading bytes
            // are the upward filter.  The predictor itself is still one pixel at a time — see
            // `paeth` below for why it is the one that resists this treatment.
            var cost = 0
            var index = 0

            while index < lead {
                let value = row[index] &- previous[index]

                destination[index] = value
                cost += Int(min(value, 0 &- value))
                index += 1
            }

            while index < count {
                let stop = min(index + 256, count)

                while index < stop {
                    let predicted = Self.paeth(
                        left: Int(row[index - stride]),
                        above: Int(previous[index]),
                        aboveLeft: Int(previous[index - stride])
                    )
                    let value = UInt8(truncatingIfNeeded: Int(row[index]) - predicted)

                    destination[index] = value
                    cost += Int(min(value, 0 &- value))
                    index += 1
                }

                guard cost <= abandonAbove else { return cost }
            }

            return cost
        }
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
