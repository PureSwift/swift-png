// DeflateError.swift - what this module can fail with
//
// LZ77 sits below PNGCore and knows nothing about it, so it cannot throw PNGCore's
// `Diagnostic`.  This is the same shape for the same reason: a static message, safe to
// construct without allocating.

public struct DeflateError: Error, Sendable {
    public let message: StaticString

    public init(_ message: StaticString) {
        self.message = message
    }
}
