// RawBuffer.swift - a block of bytes owned through the caller's allocator
//
// Row buffers go through the client's allocator rather than Swift's, because a
// libpng client that installed one expects to see every allocation the library
// makes on its behalf, and because some buffers are later handed to the client to
// release itself.
//
// Lifetime is explicit rather than tied to `deinit`.  Everything here is owned by
// the context, which releases it when the client destroys the structure, and that
// has to work from any state a client jump can leave behind.  An implicit release
// running at an unpredictable point is the opposite of what that needs.
//
// Nothing here is `mutating`, and that is the important part.  A mutating method on
// a struct held in a class property takes an exclusive access to that property for
// the duration of the call.  If the call reaches the client's allocator and the
// client jumps out of it, the access is never ended, and the next touch of that
// property traps on a conflict that no longer exists.  So allocation returns a new
// value and the caller assigns it, which keeps every property access short and
// entirely free of client code.

/// Bytes allocated through a `Host`.
///
/// Not self-releasing: whoever allocates one is responsible for calling
/// ``deallocate(host:)``, and in this library that is always the context.
struct RawBuffer {
    let base: UnsafeMutableRawPointer?
    let count: Int

    static var empty: Self { Self(base: nil, count: 0) }

    private init(base: UnsafeMutableRawPointer?, count: Int) {
        self.base = base
        self.count = count
    }

    static func allocate(_ count: Int, host: Host) throws -> Self {
        guard count > 0 else { return .empty }
        return Self(base: try host.allocateBytes(count), count: count)
    }

    /// Releases the bytes.
    ///
    /// Operating on a copy of the value, so the caller can clear its own reference
    /// before calling and leave no property access open across the deallocation.
    func deallocate(host: Host) {
        if let base = self.base {
            host.deallocateBytes(base)
        }
    }

    var bytes: UnsafeMutableBufferPointer<UInt8> {
        UnsafeMutableBufferPointer(
            start: self.base?.assumingMemoryBound(to: UInt8.self),
            count: self.count
        )
    }

    var isEmpty: Bool {
        self.base == nil || self.count == 0
    }

    /// Clears the bytes. Allocation-free, so this cannot reach client code and is
    /// safe to call through a property.
    func zero() {
        guard let base = self.base else { return }
        base.initializeMemory(as: UInt8.self, repeating: 0, count: self.count)
    }
}
