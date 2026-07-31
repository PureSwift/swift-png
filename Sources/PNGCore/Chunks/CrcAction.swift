// CrcAction.swift - what a checksum that does not match should mean
//
// Every chunk carries a check value, and one that does not match says the bytes are not the bytes the
// encoder wrote.  What follows from that is not the same for every chunk: a damaged header is a file
// nothing can be done with, while a damaged comment is a comment to drop.
//
// So the two are asked separately, and a client that knows something about how its files are damaged
// can override either — including telling the library to use data it has just been told is wrong,
// which is occasionally the only way to get anything out of a file at all.

/// What to do about a chunk whose check value does not match.
public enum CrcAction: Int32 {
    /// Whatever the library would do on its own.
    case `default` = 0
    /// Report it and stop.
    case errorQuit = 1
    /// Report it and drop the chunk.
    case warnDiscard = 2
    /// Report it and drop it anyway.
    ///
    /// Named for using the data, and observed not to: the reference reports and discards, and this
    /// follows what it does rather than what the name says.
    case warnUse = 3
    /// Use the chunk, saying nothing.
    case quietUse = 4
    /// Leave the setting as it was, which is not an action at all.
    case noChange = 5

    /// What this means for a chunk, once it is known which kind it is.
    ///
    /// The library's own answer differs between the two, so resolving it needs to know which — which
    /// is why this takes the question rather than answering it alone.
    public func resolved(isCritical: Bool) -> Self {
        guard self == .default else { return self }

        return isCritical ? .errorQuit : .warnDiscard
    }

    /// Whether a chunk whose checksum failed should still be read.
    public var usesData: Bool { self == .quietUse }

    /// Whether the client should be told.
    public var warns: Bool { self != .quietUse }
}
