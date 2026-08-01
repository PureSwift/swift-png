import Testing

@testable import PNG

/// The pass geometry is checked against the definition rather than against itself: the
/// expected pass sizes here are counted from the eight-by-eight grid the format specifies,
/// not produced by the code under test.
@Suite("Interlaced pass geometry")
struct Adam7Tests {
    /// Which pass each pixel of the defining grid belongs to.
    ///
    /// This is the table the format is specified with, written out so that everything else can
    /// be derived from it independently of the implementation.
    static let grid: [[Int]] = [
        [0, 5, 3, 5, 1, 5, 3, 5],
        [6, 6, 6, 6, 6, 6, 6, 6],
        [4, 5, 4, 5, 4, 5, 4, 5],
        [6, 6, 6, 6, 6, 6, 6, 6],
        [2, 5, 3, 5, 2, 5, 3, 5],
        [6, 6, 6, 6, 6, 6, 6, 6],
        [4, 5, 4, 5, 4, 5, 4, 5],
        [6, 6, 6, 6, 6, 6, 6, 6],
    ]

    /// Counts a pass's pixels by walking the grid, which is how the sizes are checked without
    /// reusing the arithmetic being tested.
    private func countByGrid(pass: Int, width: Int, height: Int) -> (columns: Int, rows: Int) {
        var columns = Set<Int>()
        var rows = Set<Int>()

        for y in 0 ..< height {
            for x in 0 ..< width where Self.grid[y % 8][x % 8] == pass {
                columns.insert(x)
                rows.insert(y)
            }
        }

        return (columns.count, rows.count)
    }

    /// The sizes are per dimension: a pass's width does not know how tall the image is.  So
    /// they are compared against the grid only where the pass has pixels at all, and whether it
    /// has any is checked separately against the same grid.
    @Test("Derives pass sizes that match the defining grid")
    func matchesGrid() {
        for width in 1 ... 20 {
            for height in 1 ... 20 {
                for pass in 0 ..< Adam7.passCount {
                    let expected = self.countByGrid(pass: pass, width: width, height: height)
                    let isEmptyByGrid = expected.columns == 0 || expected.rows == 0

                    #expect(
                        Adam7.isEmpty(pass: pass, imageWidth: width, imageHeight: height)
                            == isEmptyByGrid,
                        "pass \(pass) emptiness for \(width)x\(height)"
                    )

                    guard !isEmptyByGrid else { continue }

                    #expect(
                        Adam7.width(ofPass: pass, imageWidth: width) == expected.columns,
                        "pass \(pass) width for \(width)x\(height)"
                    )
                    #expect(
                        Adam7.height(ofPass: pass, imageHeight: height) == expected.rows,
                        "pass \(pass) height for \(width)x\(height)"
                    )
                }
            }
        }
    }

    /// Every pixel has to be carried by exactly one pass, or a decode would either lose
    /// pixels or write some twice.
    @Test("Covers every pixel exactly once")
    func coversEveryPixel() {
        for width in 1 ... 17 {
            for height in 1 ... 17 {
                var seen = [[Int]](
                    repeating: [Int](repeating: 0, count: width),
                    count: height
                )

                for pass in 0 ..< Adam7.passCount {
                    let columns = Adam7.width(ofPass: pass, imageWidth: width)
                    let rows = Adam7.height(ofPass: pass, imageHeight: height)

                    for row in 0 ..< rows {
                        for column in 0 ..< columns {
                            let y = Adam7.imageRow(ofPass: pass, passRow: row)
                            let x = Adam7.imageColumn(ofPass: pass, passColumn: column)

                            #expect(y < height, "pass \(pass) row out of range")
                            #expect(x < width, "pass \(pass) column out of range")

                            if y < height, x < width {
                                seen[y][x] += 1
                            }
                        }
                    }
                }

                for y in 0 ..< height {
                    for x in 0 ..< width {
                        #expect(seen[y][x] == 1, "pixel \(x),\(y) of \(width)x\(height)")
                    }
                }
            }
        }
    }

    /// A pass an image is too small to contain is absent from the stream altogether, so
    /// recognising that is what keeps a decoder from trying to read it.
    @Test("Reports which passes a small image omits")
    func reportsEmptyPasses() {
        // A single pixel is carried entirely by the first pass.
        for pass in 1 ..< Adam7.passCount {
            #expect(Adam7.isEmpty(pass: pass, imageWidth: 1, imageHeight: 1))
        }
        #expect(!Adam7.isEmpty(pass: 0, imageWidth: 1, imageHeight: 1))

        // An image four wide has nothing in pass 1, whose first column is 4.
        #expect(Adam7.isEmpty(pass: 1, imageWidth: 4, imageHeight: 8))
        #expect(!Adam7.isEmpty(pass: 1, imageWidth: 5, imageHeight: 8))

        // An image four tall has nothing in pass 2, whose first row is 4.
        #expect(Adam7.isEmpty(pass: 2, imageWidth: 8, imageHeight: 4))
        #expect(!Adam7.isEmpty(pass: 2, imageWidth: 8, imageHeight: 5))

        // Nothing is empty once the image is at least as large as the grid.
        for pass in 0 ..< Adam7.passCount {
            #expect(!Adam7.isEmpty(pass: pass, imageWidth: 8, imageHeight: 8))
        }
    }

    @Test("Sizes the row buffer for the widest pass")
    func sizesForWidestPass() {
        let header = self.header(width: 17, depth: 8, colorType: 2)

        // The last pass takes every other column, so it is the widest.
        #expect(Adam7.widestRowBytes(header: header)
            == Adam7.rowBytes(ofPass: 6, header: header))

        for pass in 0 ..< Adam7.passCount {
            #expect(Adam7.rowBytes(ofPass: pass, header: header)
                <= Adam7.widestRowBytes(header: header))
        }
    }

    private func header(width: Int, depth: UInt8, colorType: UInt8) -> Header {
        Header(
            Header.Fields(
                width: UInt32(width),
                height: 17,
                bitDepth: depth,
                colorType: colorType,
                compressionMethod: 0,
                filterMethod: 0,
                interlaceMethod: 1
            )
        )
    }
}

/// De-interlacing moves single pixels between rows of different geometry, and below a byte per
/// pixel that means touching part of a byte without disturbing its neighbours.
@Suite("Single pixel copies")
struct PixelCopyTests {
    private func copy(
        source: [UInt8],
        at sourceIndex: Int,
        into destination: [UInt8],
        at destinationIndex: Int,
        pixelDepth: Int
    ) -> [UInt8] {
        var result = destination

        source.withUnsafeBufferPointer { from in
            result.withUnsafeMutableBufferPointer { to in
                PixelCopy.copy(
                    from: from,
                    at: sourceIndex,
                    to: to,
                    at: destinationIndex,
                    pixelDepth: pixelDepth
                )
            }
        }

        return result
    }

    @Test("Copies whole-byte pixels")
    func copiesWholeBytes() {
        // Three bytes a pixel: the second pixel of the source to the third of the destination.
        let result = self.copy(
            source: [1, 2, 3, 4, 5, 6],
            at: 1,
            into: [UInt8](repeating: 0, count: 12),
            at: 2,
            pixelDepth: 24
        )

        #expect(Array(result[6 ..< 9]) == [4, 5, 6])
        // Nothing else touched.
        #expect(Array(result[0 ..< 6]) == [0, 0, 0, 0, 0, 0])
        #expect(Array(result[9 ..< 12]) == [0, 0, 0])
    }

    /// The first pixel of a byte occupies its high bits, which is the part most easily got
    /// backwards.
    @Test("Reads sub-byte pixels from the high bits first")
    func readsHighBitsFirst() {
        // 0b11_00_01_10: four pixels at two bits each.
        let source: [UInt8] = [0b1100_0110]

        for (index, expected) in [(0, 0b11), (1, 0b00), (2, 0b01), (3, 0b10)] {
            let result = self.copy(
                source: source,
                at: index,
                into: [0],
                at: 0,
                pixelDepth: 2
            )

            // Written to the destination's first pixel, so it lands in the high bits.
            #expect(result[0] >> 6 == UInt8(expected), "pixel \(index)")
        }
    }

    @Test("Leaves the neighbours of a sub-byte pixel alone")
    func preservesNeighbours() {
        let result = self.copy(
            source: [0b1000_0000],
            at: 0,
            into: [0b0111_1111],
            at: 0,
            pixelDepth: 1
        )

        // The one bit written, the other seven as they were.
        #expect(result[0] == 0b1111_1111)

        let cleared = self.copy(
            source: [0b0000_0000],
            at: 0,
            into: [0b1111_1111],
            at: 3,
            pixelDepth: 2
        )

        // The fourth two-bit pixel cleared, the rest untouched.
        #expect(cleared[0] == 0b1111_1100)
    }

    @Test("Round trips every sub-byte position")
    func roundTripsEveryPosition() {
        for depth in [1, 2, 4] {
            let perByte = 8 / depth
            let maximum = (1 << depth) - 1

            for sourceIndex in 0 ..< perByte * 2 {
                for destinationIndex in 0 ..< perByte * 2 {
                    // A source where each pixel holds a different value, so a copy from the
                    // wrong place is visible.
                    var source = [UInt8](repeating: 0, count: 2)
                    source.withUnsafeMutableBufferPointer { bytes in
                        for index in 0 ..< perByte * 2 {
                            let shift = (perByte - 1 - index % perByte) * depth
                            bytes[index / perByte] |= UInt8((index % (maximum + 1)) << shift)
                        }
                    }

                    let result = self.copy(
                        source: source,
                        at: sourceIndex,
                        into: [UInt8](repeating: 0, count: 2),
                        at: destinationIndex,
                        pixelDepth: depth
                    )

                    let shift = (perByte - 1 - destinationIndex % perByte) * depth
                    let written = (result[destinationIndex / perByte] >> shift)
                        & UInt8(maximum)

                    #expect(
                        written == UInt8(sourceIndex % (maximum + 1)),
                        "depth \(depth), \(sourceIndex) to \(destinationIndex)"
                    )
                }
            }
        }
    }
}
