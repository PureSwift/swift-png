// UnknownChunks.swift - what to do with a chunk this library does not know
//
// The format is built to be extended: a decoder that meets a chunk it has never heard of is expected
// to carry on, and the chunk's own name says whether it may be dropped and whether a program that
// edits the file may copy it forward.  So "unknown" is a state a correct decoder is in often, and not
// an error.
//
// What a client wants done with them varies, so it says.  It can ask for all of them, for the ones
// the chunk itself says are safe to copy, or for none — and it can name particular chunks and give
// each its own answer, which is what a program that understands one extension and not the rest needs.

/// What to do with a chunk nothing here understands.
public enum KeepPolicy: Int32 {
    /// Whatever the library would do on its own, which is to keep nothing.
    case asDefault = 0
    /// Drop it.
    case never = 1
    /// Keep it if the chunk says a program that does not understand it may copy it forward.
    case ifSafe = 2
    /// Keep it whatever it says.
    case always = 3
}

/// One chunk kept because a client asked for it.
public struct UnknownChunk {
    /// The four bytes, kept as bytes: a name is not text, and treating it as text would make a chunk
    /// named with a byte no character set has into a chunk with no name.
    public var name = ChunkName(packed: 0)

    public var data = EscapingBuffer<UInt8>()

    /// Where in the file it was, as the API's own bits: which of the chunks that divide a file into
    /// parts had already been seen when this one arrived.
    public var location: UInt8 = 0

    public init() {}

    public func deallocate(host: Host) {
        self.data.deallocate(host: host)
    }
}

/// What a client has asked to be done with chunks this library does not know.
public struct UnknownChunkPolicy {
    /// What to do with anything not named below.
    public var `default`: KeepPolicy = .asDefault

    /// What to do with particular chunks, which overrides the default.
    ///
    /// Held as a list rather than a dictionary because it is short and because the order a client set
    /// it in is the order it is reported back: a client that asks about a name it never set gets the
    /// answer for a name it never set, rather than the default.
    public var named: [(name: ChunkName, keep: KeepPolicy)] = []

    public init() {}

    /// What was asked for a particular chunk, ignoring the default.
    ///
    /// The default is deliberately not consulted, which is what `png_handle_as_unknown` reports: a
    /// client asking about one name is asking what it set for that name.
    public func named(_ name: ChunkName) -> KeepPolicy {
        for entry in self.named where entry.name == name {
            return entry.keep
        }

        return .asDefault
    }

    /// Records an answer, replacing any earlier one for the same name.
    public mutating func set(_ keep: KeepPolicy, for name: ChunkName) {
        for index in self.named.indices where self.named[index].name == name {
            self.named[index].keep = keep
            return
        }

        self.named.append((name, keep))
    }

    /// Whether a chunk should be kept, given what it is and what was asked.
    ///
    /// `isSafeToCopy` comes from the chunk's own name — the format puts it there so that a program
    /// which does not understand a chunk still knows whether copying it forward could be wrong.
    public func keeps(_ name: ChunkName, isSafeToCopy: Bool, hasUserCallback: Bool) -> Bool {
        var answer = self.named(name)

        if answer == .asDefault {
            answer = self.default
        }

        switch answer {
        case .never: return false
        case .always: return true
        case .ifSafe: return isSafeToCopy

        case .asDefault:
            // Nothing was asked.  A client that installed a callback for these has said it cares
            // about them, so they are kept and it is told so; one that did not gets none.
            return hasUserCallback
        }
    }
}


/// One kept chunk, laid out as the API publishes it.
///
/// Written out here rather than imported, for the reason the other published layouts are: this module
/// does not import the C header, and a change to a layout a client compiles against should be visible
/// where it is made.
public struct png_unknown_chunk_layout {
    public var name = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
    public var data: UnsafeMutablePointer<UInt8>?
    public var size = 0
    public var location: UInt8 = 0

    public init() {}
}
