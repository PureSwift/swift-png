// InflateStream.swift - decompressing the image data
//
// The image data is one zlib stream split across however many IDAT chunks the
// encoder chose, and the decoder wants scanlines out of it a row at a time.  So
// this is shaped as push-in, pull-out: compressed bytes go in whenever the caller
// has some, decompressed bytes come out whenever the caller needs some, and
// neither side dictates the other's block size.
//
// Two implementations sit behind this.  The C library compresses with zlib, which
// is what the reference build links against, so its output and its tuning knobs
// behave identically for clients that depend on them.  The Swift library uses the
// implementation in the LZ77 module, so that it needs no C dependency at all.

#if SystemZlib
import CSystemZlib
#else
import Zlib
#endif

/// A zlib stream being decompressed.
final class InflateStream {
    /// Whether the stream has delivered its end marker.
    private(set) var isFinished = false

    #if SystemZlib
    private var stream = z_stream()
    private var isInitialized = false
    #else
    private let stream = Decompressor()
    #endif

    init() throws(Diagnostic) {
        #if SystemZlib
        // The size is passed because zlib checks it against its own idea of the
        // structure, which is how it detects a header/library mismatch.
        let status = inflateInit_(
            &self.stream,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )

        guard status == Z_OK else {
            throw Diagnostic("could not start decompression")
        }

        self.isInitialized = true
        #endif
    }

    func release() {
        #if SystemZlib
        if self.isInitialized {
            inflateEnd(&self.stream)
            self.isInitialized = false
        }
        #endif
    }

    /// Whether the stream has consumed everything it was last given.
    var needsInput: Bool {
        #if SystemZlib
        return self.stream.avail_in == 0
        #else
        return self.stream.needsInput
        #endif
    }

    /// Hands the stream a block of compressed bytes.
    ///
    /// The bytes are not copied, so they must stay valid and unmodified until
    /// ``needsInput`` reports true again.
    func setInput(_ bytes: UnsafeMutableBufferPointer<UInt8>) {
        #if SystemZlib
        self.stream.next_in = bytes.baseAddress
        self.stream.avail_in = UInt32(bytes.count)
        #else
        self.stream.setInput(UnsafeBufferPointer(bytes))
        #endif
    }

    /// Decompresses into `destination`, returning how many bytes were produced.
    ///
    /// A result smaller than `count` means the stream needs more input, or has
    /// ended; the caller distinguishes those with ``needsInput`` and
    /// ``isFinished``.
    func inflate(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int
    ) throws(Diagnostic) -> Int {
        guard count > 0 else { return 0 }

        #if SystemZlib
        self.stream.next_out = destination
        self.stream.avail_out = UInt32(count)

        let status = CSystemZlib.inflate(&self.stream, Z_NO_FLUSH)

        switch status {
        case Z_OK, Z_BUF_ERROR:
            break

        case Z_STREAM_END:
            self.isFinished = true

        case Z_DATA_ERROR:
            // The decompressor's own words: a client sees these, and it describes
            // the fault more precisely than anything this layer could say.
            throw Diagnostic(
                borrowing: self.stream.msg,
                or: "Decompression error",
                chunk: .idat
            )

        case Z_MEM_ERROR:
            throw Diagnostic("out of memory")

        default:
            throw Diagnostic(
                borrowing: self.stream.msg,
                or: "Decompression error",
                chunk: .idat
            )
        }

        return count - Int(self.stream.avail_out)
        #else
        // Typed, so the catch binds a DeflateError directly: catching by dynamic cast would
        // erase it to an existential, which this module cannot spend on every platform it
        // compiles for — and which crashes the 6.3.3 compiler outright on some of them.
        do throws(DeflateError) {
            let produced = try self.stream.inflate(into: destination, count: count)
            self.isFinished = self.stream.isFinished
            return produced
        } catch {
            throw Diagnostic(error.message, chunk: .idat)
        }
        #endif
    }
}
