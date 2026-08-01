import Testing

@testable import PNGCore

@Suite("Image header")
struct HeaderTests {
    /// Builds a thirteen byte IHDR payload.
    private func payload(
        width: UInt32 = 8,
        height: UInt32 = 4,
        bitDepth: UInt8 = 8,
        colorType: UInt8 = 2,
        compression: UInt8 = 0,
        filter: UInt8 = 0,
        interlace: UInt8 = 0
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        for shift in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: width >> shift)) }
        for shift in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: height >> shift)) }
        bytes += [bitDepth, colorType, compression, filter, interlace]
        return bytes
    }

    private func fields(_ bytes: [UInt8]) throws -> Header.Fields {
        try bytes.withUnsafeBufferPointer { try Header.Fields(parsing: $0) }
    }

    @Test("Reads the fields in stream order")
    func readsFields() throws {
        let fields = try self.fields(
            payload(width: 300, height: 200, bitDepth: 16, colorType: 6, interlace: 1)
        )

        #expect(fields.width == 300)
        #expect(fields.height == 200)
        #expect(fields.bitDepth == 16)
        #expect(fields.colorType == 6)
        #expect(fields.interlaceMethod == 1)
        #expect(fields.problems.isEmpty)
    }

    @Test("Rejects a payload that is not thirteen bytes")
    func rejectsWrongLength() {
        #expect(throws: Diagnostic.self) {
            try [UInt8](repeating: 0, count: 12).withUnsafeBufferPointer {
                try Header.Fields(parsing: $0)
            }
        }
    }

    /// A header can be wrong in several ways at once, and all of them are reported,
    /// so the set has to accumulate rather than stop at the first.
    @Test("Gathers every problem, not just the first")
    func gathersEveryProblem() throws {
        let fields = try self.fields(payload(width: 0, height: 0, bitDepth: 3, colorType: 2))
        let problems = fields.problems

        #expect(problems.contains(.zeroWidth))
        #expect(problems.contains(.zeroHeight))
        #expect(problems.contains(.badBitDepth))
        // Depth 3 with colour is also an invalid pairing, and the reference reports
        // both.
        #expect(problems.contains(.badCombination))
    }

    /// When the colour type itself is meaningless there is no pairing to judge, so
    /// only the one problem is reported.
    @Test("Does not judge the pairing when the colour type is invalid")
    func skipsPairingForUnknownColorType() throws {
        let problems = try self.fields(payload(colorType: 7)).problems

        #expect(problems.contains(.badColorType))
        #expect(!problems.contains(.badCombination))
    }

    @Test("Accepts every depth the specification allows, and no others")
    func validatesDepthPerColorType() throws {
        let allowed: [(UInt8, [UInt8])] = [
            (0, [1, 2, 4, 8, 16]),
            (2, [8, 16]),
            (3, [1, 2, 4, 8]),
            (4, [8, 16]),
            (6, [8, 16]),
        ]

        for (colorType, depths) in allowed {
            for depth in [1, 2, 4, 8, 16] as [UInt8] {
                let problems = try self.fields(
                    payload(bitDepth: depth, colorType: colorType)
                ).problems

                #expect(
                    problems.contains(.badCombination) == !depths.contains(depth),
                    "colour type \(colorType) at depth \(depth)"
                )
            }
        }
    }

    @Test("Rejects methods the specification does not define")
    func rejectsUnknownMethods() throws {
        #expect(try self.fields(payload(compression: 1)).problems
            .contains(.badCompressionMethod))
        #expect(try self.fields(payload(filter: 1)).problems.contains(.badFilterMethod))
        #expect(try self.fields(payload(interlace: 2)).problems
            .contains(.badInterlaceMethod))

        // Interlacing itself is valid; only a third method is not.
        #expect(try self.fields(payload(interlace: 1)).problems.isEmpty)
    }

    @Test("Derives row size from the width and pixel depth")
    func derivesRowSize() throws {
        // Eight pixels of three eight bit channels.
        let rgb = Header(try self.fields(payload(width: 8, bitDepth: 8, colorType: 2)))
        #expect(rgb.channels == 3)
        #expect(rgb.pixelDepth == 24)
        #expect(rgb.rowBytes == 24)
        #expect(rgb.filterStride == 3)

        // Sixteen bit samples step back two bytes per channel.
        let deep = Header(try self.fields(payload(width: 8, bitDepth: 16, colorType: 2)))
        #expect(deep.rowBytes == 48)
        #expect(deep.filterStride == 6)

        // A pixel narrower than a byte still refers back a whole byte.
        let mono = Header(try self.fields(payload(width: 8, bitDepth: 1, colorType: 0)))
        #expect(mono.rowBytes == 1)
        #expect(mono.filterStride == 1)
    }

    /// A row that does not fill its last byte leaves spare bits, and the mask says
    /// which of them belong to the image.
    @Test("Masks only the bits past the end of a row")
    func computesTrailingMask() throws {
        // Thirteen one bit pixels occupy thirteen of sixteen bits.
        let narrow = Header(try self.fields(payload(width: 13, bitDepth: 1, colorType: 0)))
        #expect(narrow.rowBytes == 2)
        #expect(narrow.trailingBitMask == 0xF8)

        // Nine four bit pixels occupy thirty six of forty bits.
        let indexed = Header(try self.fields(payload(width: 9, bitDepth: 4, colorType: 3)))
        #expect(indexed.rowBytes == 5)
        #expect(indexed.trailingBitMask == 0xF0)

        // A row that ends on a byte boundary has nothing to mask.
        let exact = Header(try self.fields(payload(width: 8, bitDepth: 1, colorType: 0)))
        #expect(exact.trailingBitMask == nil)

        let bytes = Header(try self.fields(payload(width: 8, bitDepth: 8, colorType: 2)))
        #expect(bytes.trailingBitMask == nil)
    }
}
