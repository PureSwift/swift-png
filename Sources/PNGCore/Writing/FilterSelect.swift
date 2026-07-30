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

        // Each candidate is encoded into the scratch row and kept only if it beats what is there, so
        // the destination always holds the best seen so far.  Ties go to the first tried, which is why
        // the candidates are walked in the order the format numbers them: that is the reference's
        // order, and a tie broken the other way would produce a different file.
        for filter in candidates {
            let encoded = UnsafeMutableBufferPointer(
                start: scratch.baseAddress!,
                count: count
            )

            let cost = Self.apply(
                filter,
                row,
                previous: previous,
                stride: stride,
                into: encoded
            )

            guard cost < bestCost else { continue }

            bestCost = cost
            best = filter

            destination.baseAddress!.advanced(by: 1)
                .update(from: encoded.baseAddress!, count: count)
        }

        destination[0] = best.rawValue

        return best
    }

    /// Writes one filtered scanline and returns the reference's measure of how good it is.
    ///
    /// The measure is the sum of the differences read as signed bytes and taken as distances from
    /// zero, which is what the reference sums and what its choice therefore depends on.
    private static func apply(
        _ filter: Filter,
        _ row: UnsafeBufferPointer<UInt8>,
        previous: UnsafeBufferPointer<UInt8>,
        stride: Int,
        into destination: UnsafeMutableBufferPointer<UInt8>
    ) -> Int {
        let count = row.count
        var cost = 0

        @inline(__always)
        func record(_ index: Int, _ value: UInt8) {
            destination[index] = value
            cost += value < 128 ? Int(value) : 256 - Int(value)
        }

        // The bytes before the start of the row are taken as zero, which is what the format says and
        // what makes the first pixel of every row decodable on its own.
        @inline(__always)
        func left(_ index: Int) -> Int {
            index >= stride ? Int(row[index - stride]) : 0
        }

        @inline(__always)
        func upLeft(_ index: Int) -> Int {
            index >= stride ? Int(previous[index - stride]) : 0
        }

        switch filter {
        case .none:
            for index in 0 ..< count {
                record(index, row[index])
            }

        case .sub:
            for index in 0 ..< count {
                record(index, UInt8(truncatingIfNeeded: Int(row[index]) - left(index)))
            }

        case .up:
            for index in 0 ..< count {
                record(index, UInt8(truncatingIfNeeded: Int(row[index]) - Int(previous[index])))
            }

        case .average:
            for index in 0 ..< count {
                let predicted = (left(index) + Int(previous[index])) / 2
                record(index, UInt8(truncatingIfNeeded: Int(row[index]) - predicted))
            }

        case .paeth:
            for index in 0 ..< count {
                let predicted = Self.paeth(
                    left: left(index),
                    above: Int(previous[index]),
                    aboveLeft: upLeft(index)
                )

                record(index, UInt8(truncatingIfNeeded: Int(row[index]) - predicted))
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
