// EscapingBuffer.swift - storage whose address the client is given
//
// Most of what a decode holds is private to it.  A handful of things are not: the
// palette, the transparency table, the text strings, the colour profile and the
// unknown chunks are all reported to the client as pointers into our storage, and
// the client may hold those pointers for as long as the info structure lives.
//
// That has two consequences the rest of the engine does not have to think about, but
// this file does.  The memory has to come from the client's own allocator, because
// `png_data_freer` lets a client take ownership of these blocks and release them with
// `png_free` afterwards; if we had allocated them any other way, the two sides would
// disagree about who owns what.  And the address has to stay put once handed over, so
// a payload is allocated once at the size it needs rather than grown.

/// A payload the client is given the address of.
///
/// Wraps a `RawBuffer` with the count of elements rather than bytes, since that is
/// what the accessors report, and with a note of who is responsible for releasing it.
public struct EscapingBuffer<Element> {
    private(set) var storage = RawBuffer.empty

    /// How many elements are present, which is what the accessor reports.
    public private(set) var count = 0

    /// Whether this library still owns the memory.
    ///
    /// Cleared when a client takes ownership through `png_data_freer`, after which the
    /// block must not be released here: the client will do it.
    public private(set) var isOwned = true

    public var isEmpty: Bool { self.count == 0 || self.storage.isEmpty }

    /// The elements, for reading and writing in place.
    public var elements: UnsafeMutableBufferPointer<Element> {
        UnsafeMutableBufferPointer(
            start: self.storage.base?.assumingMemoryBound(to: Element.self),
            count: self.count
        )
    }

    /// The address the accessor reports, or nil when there is nothing to report.
    public var address: UnsafeMutablePointer<Element>? {
        self.isEmpty ? nil : self.storage.base?.assumingMemoryBound(to: Element.self)
    }

    /// Replaces the payload with room for `count` elements.
    ///
    /// The old block is released after the new one is in place and only if this
    /// library still owned it, so that a client which took ownership does not have its
    /// memory freed underneath it.
    public static func allocated(_ count: Int, host: Host) throws(Diagnostic) -> Self {
        guard count > 0 else { return Self() }

        var buffer = Self()
        buffer.storage = try RawBuffer.allocate(
            count * MemoryLayout<Element>.stride,
            host: host
        )
        buffer.count = count
        buffer.storage.zero()

        return buffer
    }

    /// Releases the payload, unless the client has taken it over.
    public func deallocate(host: Host) {
        guard self.isOwned else { return }
        self.storage.deallocate(host: host)
    }

    /// Records that the client is now responsible for this block.
    public mutating func relinquish() {
        self.isOwned = false
    }

    /// Records that this library is responsible for this block again.
    public mutating func reclaim() {
        self.isOwned = true
    }
}
