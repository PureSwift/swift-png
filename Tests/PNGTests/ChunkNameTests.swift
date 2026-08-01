import Testing

@testable import PNG

@Suite("Chunk type codes")
struct ChunkNameTests {
    @Test("Packs four bytes in stream order")
    func packsInStreamOrder() {
        // "IHDR"
        let name = ChunkName(0x49, 0x48, 0x44, 0x52)

        #expect(name.packed == 0x4948_4452)
        #expect(name == .ihdr)

        let (a, b, c, d) = name.bytes
        #expect([a, b, c, d] == [0x49, 0x48, 0x44, 0x52])
    }

    /// The four property bits are the case of each letter, so the flags have to
    /// agree with what the spelling says.
    @Test("Reads the property bits from letter case")
    func readsPropertyBits() {
        #expect(!ChunkName.ihdr.isAncillary, "IHDR is critical")
        #expect(ChunkName.gama.isAncillary, "gAMA is ancillary")

        #expect(!ChunkName.ihdr.isPrivate, "IHDR is registered")
        #expect(!ChunkName.gama.isPrivate, "gAMA is registered")

        // A private chunk has a lowercase second letter, which no registered
        // type does.
        #expect(ChunkName(0x73, 0x70, 0x4E, 0x67).isPrivate)

        #expect(!ChunkName.ihdr.isReserved)
        #expect(!ChunkName.gama.isReserved)

        // Safe to copy means an editor that changed the critical chunks may
        // still carry this one across, which is only true of chunks that say
        // nothing about the pixels.
        #expect(ChunkName.text.isSafeToCopy, "tEXt is independent of the image")
        #expect(ChunkName.phys.isSafeToCopy, "pHYs is independent of the image")
        #expect(ChunkName.exif.isSafeToCopy, "eXIf is independent of the image")

        #expect(!ChunkName.gama.isSafeToCopy, "gAMA describes the samples")
        #expect(!ChunkName.time.isSafeToCopy, "tIME describes this revision")
        #expect(!ChunkName.splt.isSafeToCopy, "sPLT describes the palette")
    }

    /// Every code in the table must be four printable letters with the case its
    /// flags imply; a typo here would be a chunk we silently never recognise.
    @Test("Every declared code is a well formed chunk type")
    func declaredCodesAreWellFormed() {
        let names: [(String, ChunkName)] = [
            ("IHDR", .ihdr), ("PLTE", .plte), ("IDAT", .idat), ("IEND", .iend),
            ("tRNS", .trns), ("gAMA", .gama), ("cHRM", .chrm), ("sRGB", .srgb),
            ("iCCP", .iccp), ("sBIT", .sbit), ("bKGD", .bkgd), ("hIST", .hist),
            ("sPLT", .splt), ("cICP", .cicp), ("cLLI", .clli), ("mDCV", .mdcv),
            ("tEXt", .text), ("zTXt", .ztxt), ("iTXt", .itxt), ("pHYs", .phys),
            ("oFFs", .offs), ("pCAL", .pcal), ("sCAL", .scal), ("tIME", .time),
            ("eXIf", .exif),
        ]

        for (spelling, name) in names {
            let (a, b, c, d) = name.bytes
            let decoded = String(decoding: [a, b, c, d], as: UTF8.self)

            #expect(decoded == spelling, "\(spelling) is mis-encoded as \(decoded)")

            // The third letter is reserved and must be uppercase in every
            // currently defined type.
            #expect(!name.isReserved, "\(spelling) sets the reserved bit")
        }
    }
}
