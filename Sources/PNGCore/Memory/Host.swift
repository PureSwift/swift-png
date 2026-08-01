// Host.swift - how the engine reaches the services its caller provides
//
// The engine has no knowledge of the C API, because the Swift library must not
// drag it in.  But it still has to allocate through the allocator a libpng client
// installed, and read through that client's callback.  This is the seam: the
// boundary module fills in a `Host` and the engine calls through it.
//
// These are C function pointers rather than Swift closures for two reasons.  A
// client is allowed to jump out of any callback, and a plain function pointer
// call leaves nothing on the Swift side to be abandoned when that happens.  And
// a function pointer cannot capture, so nothing reference-counted can hide behind
// one.

/// The services the engine's caller provides.
///
/// `owner` is passed back to every function as its first argument. For a libpng
/// client it is the `png_struct`, which is where the installed callbacks and
/// their contexts live.
///
/// Deliberately not `Sendable`. The contract is libpng's: one structure per
/// thread, never shared, so there is nothing here to make safe to send.
public struct Host {
    public typealias Owner = UnsafeMutableRawPointer

    /// Allocates, or reports failure through the caller's error path and does not
    /// return. Used for anything whose pointer can reach the client, and for the
    /// row buffers, so that an installed allocator sees every allocation.
    public typealias Allocate =
        @convention(c) (Owner?, UInt) -> UnsafeMutableRawPointer?

    public typealias Deallocate =
        @convention(c) (Owner?, UnsafeMutableRawPointer?) -> Void

    /// Fills the buffer, or reports failure and does not return. Short reads are
    /// an error, matching what a libpng read callback must do.
    public typealias Read =
        @convention(c) (Owner?, UnsafeMutablePointer<UInt8>?, UInt) -> Void

    /// Hands bytes to whatever the caller writes through.
    ///
    /// Absent for a caller that only reads, which is how a decode-only host says so.
    public typealias Write =
        @convention(c) (Owner?, UnsafeMutablePointer<UInt8>?, UInt) -> Void

    /// Asks the caller to push whatever it has been given so far.
    public typealias Flush = @convention(c) (Owner?) -> Void

    /// Reports a condition that does not stop the decode.
    ///
    /// Takes a length rather than expecting a terminator, because the messages
    /// come from Swift string literals and their null termination is an
    /// implementation detail rather than a guarantee.
    public typealias Warn =
        @convention(c) (Owner?, UnsafePointer<UInt8>?, UInt) -> Void

    /// Reports a condition against the chunk it was found in.
    ///
    /// The chunk type arrives as its four bytes packed big-endian, which is how the engine
    /// holds it.
    public typealias WarnChunk =
        @convention(c) (Owner?, UnsafePointer<UInt8>?, UInt, UInt32) -> Void

    /// Hands one row to a transform the client installed, and reports the shape it
    /// left behind: the bit depth in the low byte and the channel count in the next.
    ///
    /// The shape travels as plain numbers in both directions rather than through a
    /// structure this side owns. A client may jump out of its own transform, and
    /// anything owned by a frame here at that moment would be abandoned with it.
    public typealias UserTransform = @convention(c) (
        Owner?, UnsafeMutablePointer<UInt8>?, UInt32, UInt32, UInt32, UInt32
    ) -> UInt32

    public let owner: Owner
    public let allocate: Allocate
    public let deallocate: Deallocate
    public let read: Read
    public let warn: Warn
    public let warnChunk: WarnChunk

    /// Absent for a caller with no way to install one, which is every caller but the
    /// C boundary.
    public let userTransform: UserTransform?

    /// Absent for a caller that only reads.
    public let writeBytes: Write?
    public let flushBytes: Flush?

    /// The three points a progressive read reports back at: the header is complete, a row is ready,
    /// and the image has ended.
    ///
    /// Absent for a caller that is not driving a progressive read, which is every caller but the C
    /// boundary — the pure Swift library hands rows back rather than calling out for them.
    public typealias ProgressiveInfo = @convention(c) (Owner?) -> Void
    public typealias ProgressiveRow =
        @convention(c) (Owner?, UnsafeMutablePointer<UInt8>?, UInt32, Int32) -> Void

    /// The same as ``userTransform``, for rows on their way into a file.
    ///
    /// A separate entry rather than a direction argument, because the two reach different callbacks: a
    /// client installs one for reading and another for writing, and a structure that did both would be
    /// a structure doing two jobs.
    public let writeUserTransform: UserTransform?

    /// Offers a chunk this library does not understand to the client.
    ///
    /// Returns what the client said: above zero it handled the chunk, below zero it failed, and zero
    /// means it would like whatever would have happened anyway.
    public typealias UserChunk =
        @convention(c) (Owner?, UInt32, UnsafeMutablePointer<UInt8>?, UInt) -> Int32

    public let userChunk: UserChunk?

    /// Reports something the client may have said it can live with.
    ///
    /// Returns when it can and does not return when it cannot, which is why this is called rather
    /// than thrown: a caller that carries on has to be able to carry on from the same place.
    public typealias Benign = @convention(c) (Owner?, UnsafePointer<UInt8>?, UInt) -> Void

    public let benign: Benign?

    public let progressiveInfoFn: ProgressiveInfo?
    public let progressiveRowFn: ProgressiveRow?
    public let progressiveEndFn: ProgressiveInfo?

    public init(
        owner: Owner,
        allocate: Allocate,
        deallocate: Deallocate,
        read: Read,
        warn: Warn,
        warnChunk: WarnChunk,
        userTransform: UserTransform? = nil,
        writeBytes: Write? = nil,
        flushBytes: Flush? = nil,
        writeUserTransform: UserTransform? = nil,
        userChunk: UserChunk? = nil,
        benign: Benign? = nil,
        progressiveInfoFn: ProgressiveInfo? = nil,
        progressiveRowFn: ProgressiveRow? = nil,
        progressiveEndFn: ProgressiveInfo? = nil
    ) {
        self.owner = owner
        self.allocate = allocate
        self.deallocate = deallocate
        self.read = read
        self.warn = warn
        self.warnChunk = warnChunk
        self.userTransform = userTransform
        self.writeBytes = writeBytes
        self.flushBytes = flushBytes
        self.writeUserTransform = writeUserTransform
        self.userChunk = userChunk
        self.benign = benign
        self.progressiveInfoFn = progressiveInfoFn
        self.progressiveRowFn = progressiveRowFn
        self.progressiveEndFn = progressiveEndFn
    }
}

extension Host {
    /// Allocates `count` bytes.
    ///
    /// The caller's allocator reports its own failure and does not return, so a
    /// nil result means it returned nil without reporting, which is a broken
    /// allocator rather than an out-of-memory condition we can describe.
    func allocateBytes(_ count: Int) throws(Diagnostic) -> UnsafeMutableRawPointer {
        guard let memory = self.allocate(self.owner, UInt(count)) else {
            throw Diagnostic("out of memory")
        }
        return memory
    }

    func deallocateBytes(_ memory: UnsafeMutableRawPointer) {
        self.deallocate(self.owner, memory)
    }

    /// Reads exactly `count` bytes into `destination`.
    ///
    /// Nothing on the Swift stack may own memory across this call: it runs the
    /// client's callback, and the client may jump out of it.
    func readExactly(into destination: UnsafeMutablePointer<UInt8>, count: Int) {
        self.read(self.owner, destination, UInt(count))
    }

    /// Reports a fault the client may have said it can live with.
    ///
    /// Falls back to a warning where there is no way to ask: a caller with no benign channel is a
    /// caller in a test, and losing the report entirely would be worse than reporting it too gently.
    func benignError(_ message: StaticString) {
        guard message.hasPointerRepresentation else { return }

        guard let benign = self.benign else {
            self.warn(message)
            return
        }

        benign(self.owner, message.utf8Start, UInt(message.utf8CodeUnitCount))
    }

    func warn(_ message: StaticString) {
        // Addressed directly rather than copied: a static string's bytes live for
        // the lifetime of the process, so there is nothing to keep alive here.
        guard message.hasPointerRepresentation else { return }
        self.warn(self.owner, message.utf8Start, UInt(message.utf8CodeUnitCount))
    }

    /// Reports a diagnostic as a warning, keeping whatever chunk it was attributed to.
    func warn(_ diagnostic: Diagnostic) {
        guard diagnostic.message.hasPointerRepresentation else { return }

        let text = diagnostic.message.utf8Start
        let length = UInt(diagnostic.message.utf8CodeUnitCount)

        guard let chunk = diagnostic.chunk else {
            self.warn(self.owner, text, length)
            return
        }

        self.warnChunk(self.owner, text, length, chunk.packed)
    }
}


extension Host {
    /// The three points a progressive read reports back at.
    ///
    /// Nothing on the Swift stack may own anything across these: they are the client's, and a client
    /// may jump out of any of them.
    func progressiveInfo() {
        self.progressiveInfoFn?(self.owner)
    }

    func progressiveRow(_ row: UnsafeMutablePointer<UInt8>?, row number: UInt32, pass: Int32) {
        self.progressiveRowFn?(self.owner, row, number, pass)
    }

    func progressiveEnd() {
        self.progressiveEndFn?(self.owner)
    }

    /// Offers a chunk to the client's own handler.
    ///
    /// Nothing on this side may own anything across it: the client may jump out, and the chunk it is
    /// shown lives in the context's own buffer rather than on a frame here.
    func callUserChunk(name: ChunkName, data: UnsafeMutablePointer<UInt8>?, size: Int) -> Int32 {
        guard let userChunk else { return 0 }

        return userChunk(self.owner, name.packed, data, UInt(size))
    }
}
