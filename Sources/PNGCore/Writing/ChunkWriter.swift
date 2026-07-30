// ChunkWriter.swift - putting chunks on the wire
//
// A chunk is a length, a four byte type, that many bytes, and a check value over the type and the
// bytes.  Everything a writer emits goes through here, so the framing is written once and the rest of
// the writer thinks in terms of contents.
//
// The check value is computed as the bytes go out rather than over a gathered copy, which is what lets
// the image data be written straight from the compressor's buffer.
//
// Two things about the shape.  It is a value used as a local, so the running checksum lives on a frame
// that a client jumping out of its own write callback can abandon with no consequence.  And the eight
// bytes of framing are staged in a buffer the caller owns rather than one made here, for the reason
// every buffer in this library hangs off the context: a jump must not be able to abandon an
// allocation.

/// Emits chunks through the host's write callback.
struct ChunkWriter {
    let host: Host

    /// At least eight bytes of scratch, owned by the caller, for staging the framing.
    let staging: UnsafeMutableBufferPointer<UInt8>

    private var crc = Crc32()

    init(host: Host, staging: UnsafeMutableBufferPointer<UInt8>) {
        self.host = host
        self.staging = staging
    }

    /// The eight bytes that begin every file.
    ///
    /// Chosen so that a file damaged by a transfer that translates line endings, or strips the high
    /// bit, stops being a valid file — which is the difference between a decoder saying so and a
    /// decoder producing a wrong picture.
    static let signature: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

    func writeSignature() {
        let bytes = Self.signature

        self.staging[0] = bytes.0
        self.staging[1] = bytes.1
        self.staging[2] = bytes.2
        self.staging[3] = bytes.3
        self.staging[4] = bytes.4
        self.staging[5] = bytes.5
        self.staging[6] = bytes.6
        self.staging[7] = bytes.7

        self.host.write(self.staging.baseAddress, count: 8)
    }

    /// Writes a whole chunk.
    mutating func write(_ name: ChunkName, _ payload: UnsafeBufferPointer<UInt8>) {
        self.begin(name, length: payload.count)
        self.data(payload)
        self.end()
    }

    /// Starts a chunk whose contents are written in pieces.
    ///
    /// The length comes before the contents on the wire, so it has to be known first.  That is why the
    /// image data is compressed into a buffer and written a bufferful at a time rather than streamed
    /// straight out of the compressor.
    mutating func begin(_ name: ChunkName, length: Int) {
        self.staging[0] = UInt8(truncatingIfNeeded: length >> 24)
        self.staging[1] = UInt8(truncatingIfNeeded: length >> 16)
        self.staging[2] = UInt8(truncatingIfNeeded: length >> 8)
        self.staging[3] = UInt8(truncatingIfNeeded: length)
        self.staging[4] = UInt8(truncatingIfNeeded: name.packed >> 24)
        self.staging[5] = UInt8(truncatingIfNeeded: name.packed >> 16)
        self.staging[6] = UInt8(truncatingIfNeeded: name.packed >> 8)
        self.staging[7] = UInt8(truncatingIfNeeded: name.packed)

        // The check value covers the type and the contents but not the length.
        self.crc.reset()

        for index in 4 ..< 8 {
            self.crc.update(self.staging[index])
        }

        self.host.write(self.staging.baseAddress, count: 8)
    }

    /// Writes part of a chunk's contents.
    mutating func data(_ payload: UnsafeBufferPointer<UInt8>) {
        guard payload.count > 0 else { return }

        self.crc.update(payload)
        self.host.write(UnsafeMutablePointer(mutating: payload.baseAddress), count: payload.count)
    }

    /// Ends a chunk, writing its check value.
    mutating func end() {
        let value = self.crc.checksum

        self.staging[0] = UInt8(truncatingIfNeeded: value >> 24)
        self.staging[1] = UInt8(truncatingIfNeeded: value >> 16)
        self.staging[2] = UInt8(truncatingIfNeeded: value >> 8)
        self.staging[3] = UInt8(truncatingIfNeeded: value)

        self.host.write(self.staging.baseAddress, count: 4)
    }
}

extension Host {
    /// Hands bytes to the client's write callback.
    ///
    /// Nothing on the Swift stack may own memory across this call: it runs the client's callback, and
    /// the client may jump out of it.
    func write(_ bytes: UnsafeMutablePointer<UInt8>?, count: Int) {
        guard let writeBytes = self.writeBytes, count > 0 else { return }

        writeBytes(self.owner, bytes, UInt(count))
    }
}
