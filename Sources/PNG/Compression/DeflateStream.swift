// DeflateStream.swift - compressing the image data
//
// The mirror of the decompressor next door, and the same shape for the same reason: rows go in as the
// encoder produces them, compressed bytes come out whenever there is room to put them, and neither
// side dictates the other's block size.  An encoder that had to hand over the whole image at once
// would need the whole image in memory, which is the one thing a streaming encoder must not need.
//
// What a client can ask for here is wider than on the reading side, because compression has choices
// where decompression has none: how hard to try, what window to remember, how to bias the search.  The
// reference passes those straight to zlib, so a client that has tuned its output against the reference
// gets the same bytes here.

#if SystemZlib
import CSystemZlib
#else
// Both, and the second is not redundant: `Ending` and `DeflateError` are declared in `LZ77` and
// only re-exposed through `Zlib`, and Embedded Swift refuses a type whose defining module this
// file has not imported itself.
import LZ77
import Zlib
#endif

/// How the image data is to be compressed.
///
/// The defaults are the reference's rather than zlib's own, which differ in two places: the window is
/// the largest the format allows, and the level is the middle one rather than the fastest.
public struct CompressionSettings: Sendable {
    public var level: Int32 = 6
    public var method: Int32 = 8
    public var windowBits: Int32 = 15
    public var memoryLevel: Int32 = 8
    public var strategy: Int32 = 0

    /// How much compressed output to gather before writing a chunk.
    ///
    /// Only a chunk size, not a correctness matter: the stream is the same however it is cut up. A
    /// client sets it to trade the count of chunks against the memory held for them.
    public var bufferSize = 8192

    public init() {}
}

/// A zlib stream being compressed.
final class DeflateStream {
    /// Whether the stream has written its last block and its check value.
    private(set) var isFinished = false

    #if SystemZlib
    private var stream = z_stream()
    private var isInitialized = false
    #else
    private let stream: Compressor
    #endif

    init(settings: CompressionSettings) throws(Diagnostic) {
        #if SystemZlib
        // The window is given negated by callers who want a raw stream; here it is always positive,
        // since the format's image data is a zlib stream complete with its header and check value.
        let status = deflateInit2_(
            &self.stream,
            settings.level,
            settings.method,
            settings.windowBits,
            settings.memoryLevel,
            settings.strategy,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )

        guard status == Z_OK else {
            throw Diagnostic("could not start compression")
        }

        self.isInitialized = true
        #else
        self.stream = Compressor(level: settings.level)
        #endif
    }

    func release() {
        #if SystemZlib
        if self.isInitialized {
            deflateEnd(&self.stream)
            self.isInitialized = false
        }
        #endif
    }

    /// Whether the stream has taken everything it was last given.
    var needsInput: Bool {
        #if SystemZlib
        return self.stream.avail_in == 0
        #else
        return self.stream.needsInput
        #endif
    }

    /// Hands the stream a block of bytes to compress.
    ///
    /// Not copied, so they have to stay valid and unmodified until ``needsInput`` reports true again.
    func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
        #if SystemZlib
        self.stream.next_in = UnsafeMutablePointer(mutating: bytes.baseAddress)
        self.stream.avail_in = UInt32(bytes.count)
        #else
        self.stream.setInput(bytes)
        #endif
    }

    /// How much a call is asking the stream to give up.
    ///
    /// Compressing well means holding on to what you have been given until you have enough of it to
    /// find the repetitions, so a compressor produces nothing for a while by design.  These are the
    /// two ways of asking it to stop holding: one that ends the stream, and one that only empties it,
    /// for a client that wants the bytes it has so far to reach whatever is reading them.
    enum Ending {
        case none
        case flush
        case finish
    }

    /// Compresses into `destination`, returning how many bytes were produced.
    ///
    /// A result smaller than `count` with no ending asked for simply means the stream is holding on to
    /// what it has been given, which is what a compressor does.
    func deflate(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int,
        ending: Ending = .none
    ) throws(Diagnostic) -> Int {
        guard count > 0 else { return 0 }

        #if SystemZlib
        self.stream.next_out = destination
        self.stream.avail_out = UInt32(count)

        let mode: Int32

        switch ending {
        case .none: mode = Z_NO_FLUSH
        case .flush: mode = Z_SYNC_FLUSH
        case .finish: mode = Z_FINISH
        }

        let status = CSystemZlib.deflate(&self.stream, mode)

        switch status {
        case Z_OK, Z_BUF_ERROR:
            break

        case Z_STREAM_END:
            self.isFinished = true

        case Z_MEM_ERROR:
            throw Diagnostic("out of memory")

        default:
            throw Diagnostic(
                borrowing: self.stream.msg,
                or: "Compression error",
                chunk: .idat
            )
        }

        return count - Int(self.stream.avail_out)
        #else
        let mode: Compressor.Ending

        switch ending {
        case .none: mode = .none
        case .flush: mode = .flush
        case .finish: mode = .finish
        }

        // Typed, so the catch binds a DeflateError directly: catching by dynamic cast would
        // erase it to an existential, which this module cannot spend on every platform it
        // compiles for — and which crashes the 6.3.3 compiler outright on some of them.
        do throws(DeflateError) {
            let produced = try self.stream.deflate(
                into: destination,
                count: count,
                ending: mode
            )
            self.isFinished = self.stream.isFinished
            return produced
        } catch {
            throw Diagnostic(error.message, chunk: .idat)
        }
        #endif
    }
}
