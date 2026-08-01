// UnknownChunkAPI.swift - the chunks this library does not understand
//
// The format is built to be extended, so meeting a chunk nothing here knows is an ordinary thing
// rather than a fault.  What should happen to it is the client's answer: keep them all, keep the ones
// the chunk itself says are safe to copy forward, keep none, or decide chunk by chunk.
//
// A client may also ask to be shown each one as it arrives, which is how a program that understands
// an extension this library does not gets to read it.

import CPNG
import PNG

/// Says what to do with chunks this library does not know.
///
/// With a list, the answer applies to those chunks; without one it becomes the answer for everything
/// else.  The two are kept apart rather than merged, because a client that names a chunk and then
/// changes the default means the named one to keep its answer.
@c @implementation
public func png_set_keep_unknown_chunks(
    _ png_ptr: png_structrp?,
    _ keep: Int32,
    _ chunk_list: png_const_bytep?,
    _ num_chunks: Int32
) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }
    guard let policy = KeepPolicy(rawValue: keep) else { return }

    guard let chunk_list, num_chunks > 0 else {
        context.unknownChunks.default = policy
        return
    }

    for index in 0 ..< Int(num_chunks) {
        let base = index * 5

        context.unknownChunks.set(
            policy,
            for: ChunkName(
                chunk_list[base],
                chunk_list[base + 1],
                chunk_list[base + 2],
                chunk_list[base + 3]
            )
        )
    }
}

/// What was asked for one particular chunk.
///
/// The default is deliberately not consulted: a client asking about a name is asking what it set for
/// that name, and answering with the default would tell it something it did not ask.
@c @implementation
public func png_handle_as_unknown(_ png_ptr: png_const_structrp?, _ chunk_name: png_const_bytep?) -> Int32 {
    guard let png_ptr, let context = PngContext.from(png_structp(mutating: png_ptr)),
          let chunk_name else {
        return PNG_HANDLE_CHUNK_AS_DEFAULT
    }

    return context.unknownChunks.named(
        ChunkName(chunk_name[0], chunk_name[1], chunk_name[2], chunk_name[3])
    ).rawValue
}

/// Installs a handler to be shown each chunk this library does not know.
@c @implementation
public func png_set_read_user_chunk_fn(
    _ png_ptr: png_structrp?,
    _ user_chunk_ptr: png_voidp?,
    _ read_user_chunk_fn: png_user_chunk_ptr?
) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    png_ptr.pointee.read_user_chunk_fn = read_user_chunk_fn
    png_ptr.pointee.user_chunk_ptr = user_chunk_ptr

    context.hasUserChunkCallback = read_user_chunk_fn != nil
}

@c @implementation
public func png_get_user_chunk_ptr(_ png_ptr: png_const_structrp?) -> png_voidp? {
    png_ptr?.pointee.user_chunk_ptr
}

/// The chunks that were kept.
@c @implementation
public func png_get_unknown_chunks(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ entries: UnsafeMutablePointer<png_unknown_chunkp?>?
) -> Int32 {
    query(info_ptr, 0) { info in
        guard !info.unknownChunks.isEmpty else { return 0 }
        guard (try? info.buildUnknownChunkArray()) != nil else { return 0 }

        entries?.pointee = UnsafeMutableRawPointer(info.unknownChunkArray.address)?
            .assumingMemoryBound(to: png_unknown_chunk.self)

        return Int32(info.unknownChunks.count)
    }
}

/// Adds chunks of the client's own, to be written where their location says.
@c @implementation
public func png_set_unknown_chunks(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ unknowns: png_const_unknown_chunkp?,
    _ num_unknowns: Int32
) {
    guard let unknowns, num_unknowns > 0 else { return }

    updateAllocating(png_ptr, info_ptr) { info in
        for index in 0 ..< Int(num_unknowns) {
            let source = unknowns[index]
            var kept = UnknownChunk()

            kept.name = ChunkName(
                source.name.0,
                source.name.1,
                source.name.2,
                source.name.3
            )

            // The location a client sets here is not final: the reference has it name the place in
            // the file rather than the moment, and a client that gives none has it filled in when the
            // chunk is written.
            kept.location = source.location

            let count = Int(source.size)

            if count > 0, let from = source.data {
                kept.data = try EscapingBuffer<UInt8>.allocated(count, host: info.host)
                kept.data.elements.baseAddress!.update(from: from, count: count)
            }

            info.unknownChunks.append(kept)
        }
    }
}

/// Moves one of them to a different part of the file.
///
/// Indexed by position rather than by name, because a client may add two chunks with the same name
/// and mean them to go in different places.
@c @implementation
public func png_set_unknown_chunk_location(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ chunk: Int32,
    _ location: Int32
) {
    guard let info_ptr, let info = InfoStore.from(info_ptr) else { return }
    guard chunk >= 0, Int(chunk) < info.unknownChunks.count else { return }

    info.unknownChunks[Int(chunk)].location = UInt8(truncatingIfNeeded: location)
}
