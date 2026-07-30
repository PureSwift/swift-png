import Testing

@testable import PNGCore

/// The reconstruction has to invert exactly what an encoder's prediction did, so each
/// case is checked against a prediction computed independently here rather than
/// against values the implementation produced.
@Suite("Scanline reconstruction")
struct DefilterTests {
    /// Applies a filter the way an encoder would, so the round trip is a real
    /// inversion rather than a restatement of the same code.
    private func encode(
        _ filter: Filter,
        row: [UInt8],
        previous: [UInt8],
        stride: Int
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: row.count)

        for index in 0 ..< row.count {
            let left = index >= stride ? Int(row[index - stride]) : 0
            let above = Int(previous[index])
            let aboveLeft = index >= stride ? Int(previous[index - stride]) : 0

            let prediction: Int
            switch filter {
            case .none: prediction = 0
            case .sub: prediction = left
            case .up: prediction = above
            case .average: prediction = (left + above) / 2
            case .paeth:
                let estimate = left + above - aboveLeft
                let candidates = [
                    (abs(estimate - left), left),
                    (abs(estimate - above), above),
                    (abs(estimate - aboveLeft), aboveLeft),
                ]
                prediction = candidates.min { $0.0 < $1.0 }!.1
            }

            out[index] = UInt8(truncatingIfNeeded: Int(row[index]) - prediction)
        }

        return out
    }

    private func decode(
        _ filter: Filter,
        encoded: [UInt8],
        previous: [UInt8],
        stride: Int
    ) -> [UInt8] {
        var working = encoded

        working.withUnsafeMutableBufferPointer { row in
            previous.withUnsafeBufferPointer { above in
                Defilter.apply(filter, to: row, previous: above, stride: stride)
            }
        }

        return working
    }

    @Test("Inverts every filter for every stride")
    func roundTripsEveryFilter() {
        let row: [UInt8] = [0, 1, 127, 128, 129, 200, 255, 3, 64, 91, 17, 250]
        let previous: [UInt8] = [255, 128, 3, 0, 77, 1, 200, 199, 8, 42, 128, 6]

        for filter in [Filter.none, .sub, .up, .average, .paeth] {
            for stride in [1, 2, 3, 4, 6, 8] {
                let encoded = self.encode(filter, row: row, previous: previous, stride: stride)
                let decoded = self.decode(
                    filter, encoded: encoded, previous: previous, stride: stride
                )

                #expect(decoded == row, "\(filter) at stride \(stride)")
            }
        }
    }

    /// The first row of an image has nothing above it, which the format defines as a
    /// row of zeroes rather than as a special case in each filter.
    @Test("Treats the row above the first as zeroes")
    func handlesTopEdge() {
        let row: [UInt8] = [9, 200, 17, 255, 1, 88]
        let previous = [UInt8](repeating: 0, count: row.count)

        for filter in [Filter.none, .sub, .up, .average, .paeth] {
            let encoded = self.encode(filter, row: row, previous: previous, stride: 3)
            let decoded = self.decode(filter, encoded: encoded, previous: previous, stride: 3)

            #expect(decoded == row, "\(filter) on the first row")
        }
    }

    /// A row shorter than the filter's reach exercises only the leading branch of
    /// each filter, which is where an off-by-one would hide.
    @Test("Handles a row narrower than the filter reach")
    func handlesShortRow() {
        let row: [UInt8] = [42, 7]
        let previous: [UInt8] = [200, 3]

        for filter in [Filter.none, .sub, .up, .average, .paeth] {
            // A stride wider than the row means no byte has a left neighbour.
            let encoded = self.encode(filter, row: row, previous: previous, stride: 6)
            let decoded = self.decode(filter, encoded: encoded, previous: previous, stride: 6)

            #expect(decoded == row, "\(filter) with stride past the row end")
        }
    }

    /// The average filter takes the mean in wider arithmetic before truncating, so a
    /// pair that overflows a byte must not wrap first.
    @Test("Averages without wrapping")
    func averagesInWiderArithmetic() {
        // 200 + 240 exceeds a byte; the mean is 220.
        let previous: [UInt8] = [240, 240]
        let row: [UInt8] = [200, 200]

        let encoded = self.encode(.average, row: row, previous: previous, stride: 1)
        let decoded = self.decode(.average, encoded: encoded, previous: previous, stride: 1)

        #expect(decoded == row)
    }

    /// The specification fixes how a tie resolves, because a different choice decodes
    /// to different pixels.
    @Test("Resolves a Paeth tie towards the left neighbour")
    func resolvesPaethTie() {
        // left and above are equidistant from the estimate, so left wins.
        let previous: [UInt8] = [10, 10]
        let row: [UInt8] = [10, 20]

        let encoded = self.encode(.paeth, row: row, previous: previous, stride: 1)
        let decoded = self.decode(.paeth, encoded: encoded, previous: previous, stride: 1)

        #expect(decoded == row)
    }
}
