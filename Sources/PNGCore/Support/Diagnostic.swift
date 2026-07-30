// Diagnostic.swift - how the engine reports failure
//
// The engine never transfers control to the client's jump target itself.  It
// throws, the exported entry point catches at the C boundary, and only there
// does the error reach the client's handler.  That ordering is what keeps a
// client longjmp from abandoning a Swift frame that still owns something: by the
// time the jump happens, every engine frame has already unwound normally.
//
// A thrown value therefore has to be safe to construct on a failing path with
// no allocation and nothing to release, so it carries a static message rather
// than a built string.  Text that has to be assembled at runtime is formatted
// into the control structure's message buffer instead.

/// A failure raised by the engine.
///
/// Deliberately not an `Error` carrying references: the value has to be
/// constructible without allocating, since some failures are reported while
/// recovering from a failed allocation.
public struct Diagnostic: Error, Sendable {
    /// Whether the condition is fatal, or recoverable and reportable as a
    /// warning.
    public enum Severity: Sendable {
        case error
        /// Invalid but recoverable; reported as an error or a warning depending
        /// on whether the client enabled benign errors.
        case benign
        case warning
    }

    public let message: StaticString
    public let severity: Severity

    /// The four-character chunk name to prefix the message with, when the
    /// failure is attributable to a specific chunk.
    public let chunk: ChunkName?

    public init(
        _ message: StaticString,
        severity: Severity = .error,
        chunk: ChunkName? = nil
    ) {
        self.message = message
        self.severity = severity
        self.chunk = chunk
    }
}
