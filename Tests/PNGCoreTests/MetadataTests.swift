#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

import Testing

@testable import PNGCore

/// These check the parsers directly, without a stream, so a fault in one is not confused
/// with a fault in the framing around it.
///
/// A store needs somewhere to allocate from, so the host here uses the process allocator
/// and counts what it hands out; a payload left unreleased shows up as an imbalance rather
/// than as a leak nobody notices.
@Suite("Optional chunks")
struct MetadataTests {
    /// What one host handed out and took back.
    ///
    /// Per host rather than per process. The callbacks are C function pointers and cannot
    /// capture, so the obvious thing is a global counter — but tests run in parallel, and a
    /// shared counter would record another test's allocations as this one's. The host's
    /// `owner` pointer is exactly the way through: it is passed back to every callback, so
    /// it addresses this ledger.
    final class Ledger {
        var allocations = 0
        var frees = 0

        var isBalanced: Bool { self.allocations == self.frees }
    }

    /// A host whose allocator reports to `ledger`.
    ///
    /// The ledger is retained and never released, deliberately.  A host holds its owner as a raw
    /// pointer and cannot keep anything alive, so an unretained ledger is dangling the moment the
    /// caller stops holding it — and a caller that only wants the host, not the counts, has no reason
    /// to hold it. Leaking one small object per host is the price of removing that trap; the test
    /// process is short-lived and the alternative was silently reading freed memory.
    static func makeHost(reportingTo ledger: Ledger) -> Host {
        Host(
            owner: Unmanaged.passRetained(ledger).toOpaque(),
            allocate: { owner, size in
                owner!.ledger.allocations += 1
                return malloc(Int(size))
            },
            deallocate: { owner, memory in
                owner!.ledger.frees += 1
                free(memory)
            },
            read: { _, _, _ in },
            warn: { _, _, _ in },
            warnChunk: { _, _, _, _ in }
        )
    }

    private func store(_ header: Header? = nil, ledger: Ledger = Ledger()) -> InfoStore {
        let store = InfoStore(host: Self.makeHost(reportingTo: ledger))
        store.header = header
        return store
    }

    private func header(
        width: Int = 8,
        depth: UInt8 = 8,
        colorType: UInt8 = 2
    ) -> Header {
        var bytes: [UInt8] = []
        for shift in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: width >> shift)) }
        bytes += [0, 0, 0, 4]
        bytes += [depth, colorType, 0, 0, 0]

        return bytes.withUnsafeBufferPointer { buffer in
            Header(try! Header.Fields(parsing: buffer))
        }
    }

    private func parse(
        _ payload: [UInt8],
        into store: InfoStore,
        _ body: (InfoStore, UnsafeBufferPointer<UInt8>) throws -> Void
    ) throws {
        try payload.withUnsafeBufferPointer { try body(store, $0) }
    }

    @Test("Reads the gamma as the file stores it")
    func readsGamma() throws {
        let store = self.store()
        try self.parse([0, 0, 0xB1, 0x8F], into: store) { try $0.parseGamma($1) }

        #expect(store.gamma == 45455)
        #expect(store.isValid(InfoStore.Valid.gama))
    }

    @Test("Refuses a chunk whose length is not what the format fixes")
    func refusesWrongLength() {
        let store = self.store()

        #expect(throws: Diagnostic.self) {
            try self.parse([0, 0, 0xB1], into: store) { try $0.parseGamma($1) }
        }
        #expect(!store.isValid(InfoStore.Valid.gama))
    }

    @Test("Refuses a rendering intent the format does not define")
    func refusesUnknownIntent() throws {
        let store = self.store()

        try self.parse([2], into: store) { try $0.parseSrgb($1) }
        #expect(store.srgbIntent == 2)

        #expect(throws: Diagnostic.self) {
            try self.parse([4], into: self.store()) { try $0.parseSrgb($1) }
        }
    }

    /// The reported structure has a field per channel, and the ones the chunk does not
    /// mention are filled rather than left at zero.
    @Test("Fills the channels the significant bits chunk does not mention")
    func fillsSignificantBits() throws {
        // Colour: the three channels come from the chunk, and alpha defaults to the depth.
        let colour = self.store(self.header(depth: 8, colorType: 2))
        try self.parse([5, 6, 5], into: colour) { try $0.parseSignificantBits($1) }

        #expect(colour.significantBits.red == 5)
        #expect(colour.significantBits.green == 6)
        #expect(colour.significantBits.blue == 5)
        #expect(colour.significantBits.gray == 0)
        #expect(colour.significantBits.alpha == 8)

        // Greyscale: the one value is mirrored into the colour channels.
        let gray = self.store(self.header(depth: 16, colorType: 0))
        try self.parse([9], into: gray) { try $0.parseSignificantBits($1) }

        #expect(gray.significantBits.gray == 9)
        #expect(gray.significantBits.red == 9)
        #expect(gray.significantBits.green == 9)
        #expect(gray.significantBits.blue == 9)
        // Sixteen bit, so the defaulted alpha is 16 rather than 8.
        #expect(gray.significantBits.alpha == 16)

        // With a real alpha channel the chunk supplies it.
        let rgba = self.store(self.header(depth: 8, colorType: 6))
        try self.parse([5, 6, 7, 4], into: rgba) { try $0.parseSignificantBits($1) }

        #expect(rgba.significantBits.alpha == 4)
    }

    /// Entries the bit depth cannot address are unreachable, and dropping them lets a file
    /// with an over-long palette still decode.
    @Test("Truncates a palette longer than the bit depth can address")
    func truncatesPalette() throws {
        let store = self.store(self.header(depth: 2, colorType: 3))

        // Sixteen entries offered, four addressable at two bits.
        let payload = (0 ..< 16).flatMap { [UInt8($0), UInt8($0 * 2), UInt8($0 * 3)] }
        try self.parse(payload, into: store) { try $0.parsePalette($1) }

        #expect(store.palette.count == 4)
        #expect(store.palette.elements[3].green == 6)

        store.release()
    }

    @Test("Refuses a palette that is not a whole number of entries")
    func refusesRaggedPalette() {
        let store = self.store(self.header(depth: 8, colorType: 3))

        #expect(throws: Diagnostic.self) {
            try self.parse([1, 2, 3, 4], into: store) { try $0.parsePalette($1) }
        }
    }

    /// A background outside the range the image's depth can express would composite to
    /// something the client never asked for, so it is refused rather than clamped.
    @Test("Refuses a background the bit depth cannot express")
    func refusesOutOfRangeBackground() throws {
        let eightBit = self.store(self.header(depth: 8, colorType: 0))

        #expect(throws: Diagnostic.self) {
            // 900 needs more than eight bits.
            try self.parse([0x03, 0x84], into: eightBit) { try $0.parseBackground($1) }
        }
        #expect(!eightBit.isValid(InfoStore.Valid.bkgd))

        // The same value is in range at sixteen bits.
        let sixteenBit = self.store(self.header(depth: 16, colorType: 0))
        try self.parse([0x03, 0x84], into: sixteenBit) { try $0.parseBackground($1) }

        #expect(sixteenBit.background.gray == 900)
        // Mirrored into the colour channels, as the reference reports it.
        #expect(sixteenBit.background.red == 900)
    }

    /// Both chunks are sized against the palette, so neither can precede it.
    @Test("Refuses transparency and a histogram that precede the palette")
    func refusesPaletteReferencesBeforePalette() {
        let store = self.store(self.header(depth: 8, colorType: 3))

        #expect(throws: Diagnostic.self) {
            try self.parse([0, 64], into: store) { try $0.parseTransparency($1) }
        }

        #expect(throws: Diagnostic.self) {
            try self.parse([0, 9, 0, 8], into: store) { try $0.parseHistogram($1) }
        }
    }

    @Test("Resolves an indexed background through the palette")
    func resolvesIndexedBackground() throws {
        let store = self.store(self.header(depth: 8, colorType: 3))

        try self.parse([10, 20, 30, 40, 50, 60], into: store) { try $0.parsePalette($1) }
        try self.parse([1], into: store) { try $0.parseBackground($1) }

        #expect(store.background.index == 1)
        #expect(store.background.red == 40)
        #expect(store.background.green == 50)
        #expect(store.background.blue == 60)

        store.release()
    }

    @Test("Refuses an indexed background outside the palette")
    func refusesIndexPastPalette() throws {
        let store = self.store(self.header(depth: 8, colorType: 3))
        try self.parse([10, 20, 30], into: store) { try $0.parsePalette($1) }

        #expect(throws: Diagnostic.self) {
            try self.parse([5], into: store) { try $0.parseBackground($1) }
        }

        store.release()
    }

    /// An image that already carries alpha has nothing for this chunk to say.
    @Test("Refuses transparency on an image that already has alpha")
    func refusesTransparencyWithAlpha() {
        let store = self.store(self.header(depth: 8, colorType: 6))

        #expect(throws: Diagnostic.self) {
            try self.parse([0, 1, 0, 2, 0, 3], into: store) { try $0.parseTransparency($1) }
        }
    }

    /// Replacing a payload has to release the one it replaced, or a file with two of the
    /// same chunk would leak the first.
    @Test("Releases a payload it replaces")
    func releasesReplacedPayload() throws {
        let ledger = Ledger()
        let store = self.store(self.header(depth: 8, colorType: 3), ledger: ledger)
        let payload: [UInt8] = [1, 2, 3, 4, 5, 6]

        // The same chunk twice, which a file is free to contain.
        try self.parse(payload, into: store) { try $0.parsePalette($1) }
        try self.parse(payload, into: store) { try $0.parsePalette($1) }

        #expect(ledger.allocations == 2)

        store.release()

        #expect(ledger.isBalanced, "every payload should have been released")
    }

    @Test("Reads a timestamp field by field")
    func readsTimestamp() throws {
        let store = self.store()
        try self.parse([0x07, 0xEA, 7, 29, 13, 45, 7], into: store) {
            try $0.parseTimestamp($1)
        }

        #expect(store.timestamp.year == 2026)
        #expect(store.timestamp.month == 7)
        #expect(store.timestamp.day == 29)
        #expect(store.timestamp.hour == 13)
        #expect(store.timestamp.minute == 45)
        #expect(store.timestamp.second == 7)
    }

    /// An offset is signed, unlike a resolution: an image may sit above or left of the
    /// origin.
    @Test("Reads a negative offset")
    func readsNegativeOffset() throws {
        let store = self.store()
        try self.parse(
            [0xFF, 0xFF, 0xFF, 0xF4, 0, 0, 0, 0x22, 0],
            into: store
        ) { try $0.parseOffset($1) }

        #expect(store.offset.x == -12)
        #expect(store.offset.y == 34)
        #expect(store.offset.unit == 0)
    }
}

extension UnsafeMutableRawPointer {
    /// The ledger a host's `owner` pointer addresses.
    fileprivate var ledger: MetadataTests.Ledger {
        Unmanaged<MetadataTests.Ledger>.fromOpaque(self).takeUnretainedValue()
    }
}
