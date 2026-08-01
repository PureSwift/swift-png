// TextStorage.swift - a string the client is given the address of
//
// The text chunks, the profile name and the scale strings are all reported to the
// client as plain C strings pointing into our storage.  So they live in memory from the
// client's allocator, like every other payload whose address escapes, and they are
// terminated even when what the file contained was not.
//
// Terminating matters more than it looks.  A text chunk's value runs to the end of the
// chunk with no terminator of its own, and a keyword is terminated only by the byte
// that separates it from the value.  A client is handed `char *` and will read to a
// null, so the null has to be something this library put there rather than something
// the file was trusted to provide.

/// A null-terminated string held in memory from the caller's allocator.
public struct TextStorage {
    private(set) var storage = RawBuffer.empty

    /// The length in bytes, not counting the terminator.
    public private(set) var count = 0

    public private(set) var isOwned = true

    public init() {}

    public var isEmpty: Bool { self.storage.isEmpty }

    /// The address the accessor reports.
    ///
    /// Null when nothing has been stored, which is what a client sees for a field the
    /// file did not carry.
    public var address: UnsafeMutablePointer<CChar>? {
        self.storage.base?.assumingMemoryBound(to: CChar.self)
    }

    /// Copies `bytes` and appends a terminator.
    public static func copying(
        _ bytes: UnsafeBufferPointer<UInt8>,
        host: Host
    ) throws(Diagnostic) -> Self {
        var text = Self()

        // One extra byte for the terminator, and one allocation even for an empty
        // string, so that the address a client is given is never null for a field that
        // was present but blank.
        text.storage = try RawBuffer.allocate(bytes.count + 1, host: host)
        text.count = bytes.count

        let destination = text.storage.bytes

        if let source = bytes.baseAddress, bytes.count > 0 {
            destination.baseAddress!.update(from: source, count: bytes.count)
        }

        destination[bytes.count] = 0

        return text
    }

    /// Copies a C string of unknown length.
    public static func copying(
        _ cString: UnsafePointer<CChar>?,
        host: Host
    ) throws(Diagnostic) -> Self {
        guard let cString else { return Self() }

        var length = 0
        while cString[length] != 0 { length += 1 }

        // The rebinding closure cannot throw a typed error through `rethrows`, so the throwing
        // copy happens inside it behind a Result and is unwrapped, typed, out here.
        let result = UnsafeRawPointer(cString)
            .withMemoryRebound(to: UInt8.self, capacity: length) { bytes -> Result<Self, Diagnostic> in
                do throws(Diagnostic) {
                    return .success(
                        try Self.copying(
                            UnsafeBufferPointer(start: bytes, count: length),
                            host: host
                        )
                    )
                } catch {
                    return .failure(error)
                }
            }

        return try result.get()
    }

    public func deallocate(host: Host) {
        guard self.isOwned else { return }
        self.storage.deallocate(host: host)
    }

    public mutating func relinquish() {
        self.isOwned = false
    }
}
