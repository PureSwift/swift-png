import Testing

@testable import PNGCore

/// The expected values here were measured from the reference rather than reasoned out.
///
/// Which is the only way they could be got: the reduction merges the nearest pair over and over and
/// its result is a consequence of that procedure rather than of any property worth naming, so a test
/// that computed what it expected would be the implementation written twice.  These fix particular
/// answers instead — small enough to read, and each one exercising a different route through the
/// request.
@Suite("Fitting into fewer colours")
struct QuantizeTests {
    /// Eight colours spread over the cube: black, white, the primaries, a grey, and two near-twins.
    private let spread: [Rgb8] = [
        Rgb8(red: 0, green: 0, blue: 0),
        Rgb8(red: 255, green: 255, blue: 255),
        Rgb8(red: 255, green: 0, blue: 0),
        Rgb8(red: 0, green: 255, blue: 0),
        Rgb8(red: 0, green: 0, blue: 255),
        Rgb8(red: 128, green: 128, blue: 128),
        Rgb8(red: 250, green: 250, blue: 250),
        Rgb8(red: 8, green: 8, blue: 8),
    ]

    private func reduce(
        _ palette: [Rgb8],
        to maximum: Int,
        histogram: [UInt16]? = nil,
        fullQuantize: Bool = false
    ) -> (palette: [Rgb8], map: [UInt8]?) {
        var entries = palette
        var map: [UInt8]?

        entries.withUnsafeMutableBufferPointer { buffer in
            if let histogram {
                histogram.withUnsafeBufferPointer { counts in
                    map = Quantize.reduce(
                        palette: buffer,
                        count: buffer.count,
                        maximum: maximum,
                        histogram: counts,
                        fullQuantize: fullQuantize
                    )
                }
            } else {
                map = Quantize.reduce(
                    palette: buffer,
                    count: buffer.count,
                    maximum: maximum,
                    histogram: nil,
                    fullQuantize: fullQuantize
                )
            }
        }

        return (entries, map)
    }

    private func triples(_ palette: [Rgb8]) -> [[Int]] {
        palette.map { [Int($0.red), Int($0.green), Int($0.blue)] }
    }

    @Test("a palette short enough already is left alone")
    func noReduction() {
        let result = self.reduce(self.spread, to: 8)

        #expect(self.triples(result.palette) == self.triples(self.spread))
        #expect(result.map == Array(0 ..< 8).map { UInt8($0) })
    }

    /// The two near-twins go first — black with near-black, white with near-white — and the merging
    /// then widens its reach until four are left.
    @Test("without a histogram the nearest pair goes first")
    func mergesNearest() {
        let result = self.reduce(self.spread, to: 4)

        #expect(self.triples(result.palette).prefix(4) == [
            [128, 128, 128], [255, 255, 255], [255, 0, 0], [0, 255, 0],
        ])
        #expect(result.map == [3, 1, 2, 3, 3, 0, 1, 3])
    }

    /// With counts to go on there is no searching: the four least used are dropped, and each is sent
    /// to whichever survivor is nearest it.
    @Test("a histogram decides what to lose")
    func keepsWhatIsUsed() {
        let counts: [UInt16] = [1, 2, 3, 4, 5, 6, 7, 8]
        let result = self.reduce(self.spread, to: 4, histogram: counts)

        #expect(self.triples(result.palette).prefix(4) == [
            [8, 8, 8], [250, 250, 250], [128, 128, 128], [0, 0, 255],
        ])
        #expect(result.map == [0, 1, 0, 0, 3, 2, 1, 0])
    }

    /// A client asking for the whole reduction gets no map — its rows are colours, not indices.
    @Test("the full reduction leaves no renumbering")
    func fullQuantizeHasNoMap() {
        let result = self.reduce(self.spread, to: 4, fullQuantize: true)

        #expect(result.map == nil)
        #expect(self.triples(result.palette).prefix(4) == [
            [128, 128, 128], [255, 255, 255], [255, 0, 0], [0, 255, 0],
        ])
    }

    /// Nine colours put through the lookup, including two that fall between palette entries and one
    /// that is equally far from two of them — where the first entry tried wins.
    @Test("colours find their entry through the lookup")
    func lookupFindsNearest() {
        let table = self.spread.withUnsafeBufferPointer {
            Quantize.lookup(palette: $0, count: $0.count)
        }

        let pixels: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 0), (255, 255, 255), (200, 30, 30), (30, 200, 30), (30, 30, 200),
            (127, 127, 127), (17, 200, 190), (250, 250, 10), (64, 0, 0),
        ]

        let found = pixels.map { table[Quantize.place(red: $0.0, green: $0.1, blue: $0.2)] }

        #expect(found == [0, 1, 2, 3, 4, 5, 5, 1, 0])
    }

    /// Two entries the lookup cannot tell apart, which is a thing that can happen to a client.
    ///
    /// It sees five bits a channel, so two colours differing only below that are one colour to it —
    /// they land in the same cell, the first one tried wins it, and the second is then unreachable.
    /// A client offering both gets an image drawn entirely in the first.
    @Test("the lookup sees only the top five bits")
    func lookupIsCoarse() {
        let palette = [
            Rgb8(red: 8, green: 8, blue: 8),
            Rgb8(red: 15, green: 15, blue: 15),
        ]

        let table = palette.withUnsafeBufferPointer {
            Quantize.lookup(palette: $0, count: $0.count)
        }

        #expect(table[Quantize.place(red: 8, green: 8, blue: 8)] == 0)
        #expect(table[Quantize.place(red: 15, green: 15, blue: 15)] == 0)
        #expect(!table.contains(1))
    }

    /// A row of indices renumbered, and a row of colours turned into indices.
    @Test("a row is renumbered or fitted, according to what it holds")
    func rowsGoThroughTheRightPath() {
        var tables = Quantization()
        tables.indexMap = [3, 1, 2, 3, 3, 0, 1, 3]

        var indices: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        var info = RowInfo(width: 8, bitDepth: 8, colorType: .palette, channels: 1)

        indices.withUnsafeMutableBufferPointer { row in
            Transform.quantize(row, &info, tables)
        }

        #expect(indices == [3, 1, 2, 3, 3, 0, 1, 3])
        #expect(info.colorType == .palette)

        var fitted = Quantization()
        fitted.lookup = self.spread.withUnsafeBufferPointer {
            Quantize.lookup(palette: $0, count: $0.count)
        }

        var colours: [UInt8] = [0, 0, 0, 255, 255, 255, 128, 128, 128]
        var colourInfo = RowInfo(width: 3, bitDepth: 8, colorType: .rgb, channels: 3)

        colours.withUnsafeMutableBufferPointer { row in
            Transform.quantize(row, &colourInfo, fitted)
        }

        #expect(Array(colours.prefix(3)) == [0, 1, 5])
        #expect(colourInfo.colorType == .palette)
        #expect(colourInfo.channels == 1)
        #expect(colourInfo.rowBytes == 3)
    }

    /// An index the shortened palette never had cannot be renumbered, and must not be read past.
    @Test("an index past the end of the map is left alone")
    func brokenIndexIsSafe() {
        var tables = Quantization()
        tables.indexMap = [1, 0]

        var indices: [UInt8] = [0, 1, 200]
        var info = RowInfo(width: 3, bitDepth: 8, colorType: .palette, channels: 1)

        indices.withUnsafeMutableBufferPointer { row in
            Transform.quantize(row, &info, tables)
        }

        #expect(indices == [1, 0, 200])
    }
}
