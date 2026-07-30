// Defilter.swift - undoing the per-scanline filter
//
// Each scanline is prefixed with a byte naming one of five filters, which predict
// a byte from its neighbours so that what gets compressed is small differences
// rather than the samples themselves.  Undoing one is inherently sequential: byte
// `i` is reconstructed from bytes already reconstructed in the same row, so this
// cannot be vectorised across the row without care.
//
// `stride` is the distance to the byte representing the same channel of the
// previous pixel: one pixel in bytes, or one byte when a pixel is narrower.

enum Filter: UInt8 {
    case none = 0
    case sub = 1
    case up = 2
    case average = 3
    case paeth = 4
}

enum Defilter {
    /// Reconstructs `row` in place, given the already-reconstructed `previous`.
    ///
    /// `previous` must be all zeroes for the first row of a pass, which is what
    /// makes the filters that refer upwards work on the top edge.
    static func apply(
        _ filter: Filter,
        to row: UnsafeMutableBufferPointer<UInt8>,
        previous: UnsafeBufferPointer<UInt8>,
        stride: Int
    ) {
        let count = row.count

        // How many leading bytes have no left neighbour.  Clamped, because a row can
        // be no longer than one pixel: a single pixel of four sixteen bit channels is
        // eight bytes wide and refers back eight bytes, so the two are equal, and an
        // unclamped range would be empty in one direction and out of bounds in the
        // other.
        let lead = min(stride, count)

        switch filter {
        case .none:
            break

        case .sub:
            // Bytes before the first pixel have no predecessor, so they stay.
            for index in lead ..< count {
                row[index] = row[index] &+ row[index - stride]
            }

        case .up:
            for index in 0 ..< count {
                row[index] = row[index] &+ previous[index]
            }

        case .average:
            // The mean is taken in wider arithmetic and truncated, so it must not
            // be computed with wrapping byte addition.
            for index in 0 ..< lead {
                row[index] = row[index] &+ UInt8(Int(previous[index]) / 2)
            }

            for index in lead ..< count {
                let left = Int(row[index - stride])
                let above = Int(previous[index])
                row[index] = row[index] &+ UInt8((left + above) / 2)
            }

        case .paeth:
            // With no left neighbour the estimate reduces to the byte above, so this
            // is the same as the upward filter for the leading bytes.
            for index in 0 ..< lead {
                row[index] = row[index] &+ previous[index]
            }

            for index in lead ..< count {
                let left = Int(row[index - stride])
                let above = Int(previous[index])
                let aboveLeft = Int(previous[index - stride])

                row[index] = row[index] &+ UInt8(
                    Self.paethPredictor(left: left, above: above, aboveLeft: aboveLeft)
                )
            }
        }
    }

    /// Picks whichever neighbour is closest to `left + above - aboveLeft`.
    ///
    /// Ties go to `left`, then `above`, which the specification fixes because a
    /// different choice would decode differently.
    private static func paethPredictor(left: Int, above: Int, aboveLeft: Int) -> Int {
        let estimate = left + above - aboveLeft

        let distanceToLeft = abs(estimate - left)
        let distanceToAbove = abs(estimate - above)
        let distanceToAboveLeft = abs(estimate - aboveLeft)

        if distanceToLeft <= distanceToAbove, distanceToLeft <= distanceToAboveLeft {
            return left
        }

        if distanceToAbove <= distanceToAboveLeft {
            return above
        }

        return aboveLeft
    }
}
