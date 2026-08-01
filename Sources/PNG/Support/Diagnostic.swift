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
/// `Error` requires `Sendable`, and the borrowed message is a raw pointer, which the
/// compiler cannot see is safe to share. It is: the only text ever borrowed comes from
/// a decompressor's table of static strings, which outlives every use and is never
/// written.
public struct Diagnostic: Error, @unchecked Sendable {
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

    /// Text from somewhere other than this library, used instead of ``message``
    /// when present.
    ///
    /// The decompressor reports its own faults, and a client sees those words, so
    /// they are passed through rather than replaced with a summary of our own. The
    /// pointer must address storage that outlives the report, which is true of the
    /// static strings a decompressor returns.
    public let borrowedMessage: UnsafePointer<CChar>?

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
        self.borrowedMessage = nil
    }

    /// A failure described by text this library did not author.
    ///
    /// `message` is the fallback for when the borrowed text is absent.
    public init(
        borrowing borrowedMessage: UnsafePointer<CChar>?,
        or message: StaticString,
        severity: Severity = .error,
        chunk: ChunkName? = nil
    ) {
        self.message = message
        self.severity = severity
        self.chunk = chunk
        self.borrowedMessage = borrowedMessage
    }

    /// The same condition, reported as something the decode survived.
    ///
    /// For the places where whether a fault is fatal depends on who is asking rather than on what
    /// went wrong: the same corrupt stream stops a sequential read and only stops the rows of a
    /// progressive one.
    public var asWarning: Self {
        Self(
            borrowing: self.borrowedMessage,
            or: self.message,
            severity: .warning,
            chunk: self.chunk
        )
    }
}
