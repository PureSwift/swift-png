// LimitsAPI.swift - what a decoder will not attempt
//
// A file says how large its image is and how much it has to say about itself, and a decoder that
// believes both without limit is a decoder that can be asked to allocate anything.  These are the
// ceilings, and they exist for that reason rather than as tuning.
//
// The defaults are the reference's and they are generous: a million pixels each way, a thousand
// ancillary chunks, and eight megabytes for any one of them.  A client that knows what it is reading
// lowers them; one that has to read anything raises them and takes its chances.

import CPNG
import PNGCore

@c @implementation
public func png_set_user_limits(
    _ png_ptr: png_structrp?,
    _ user_width_max: png_uint_32,
    _ user_height_max: png_uint_32
) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    context.limits.width = user_width_max
    context.limits.height = user_height_max
}

@c @implementation
public func png_get_user_width_max(_ png_ptr: png_const_structrp?) -> png_uint_32 {
    guard let png_ptr, let context = PngContext.from(png_structp(mutating: png_ptr)) else {
        return 0
    }

    return context.limits.width
}

@c @implementation
public func png_get_user_height_max(_ png_ptr: png_const_structrp?) -> png_uint_32 {
    guard let png_ptr, let context = PngContext.from(png_structp(mutating: png_ptr)) else {
        return 0
    }

    return context.limits.height
}

/// How many ancillary chunks a decoder will keep before it stops keeping them.
///
/// A file can carry any number of them, and each one a decoder holds is memory a client did not ask
/// for.  Zero means no limit, which is what a client says when it would rather have everything.
@c @implementation
public func png_set_chunk_cache_max(_ png_ptr: png_structrp?, _ user_chunk_cache_max: png_uint_32) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    context.limits.chunkCache = user_chunk_cache_max
}

@c @implementation
public func png_get_chunk_cache_max(_ png_ptr: png_const_structrp?) -> png_uint_32 {
    guard let png_ptr, let context = PngContext.from(png_structp(mutating: png_ptr)) else {
        return 0
    }

    return context.limits.chunkCache
}

/// The largest any one chunk may be.
///
/// Separate from the count above because the two are different risks: a thousand small chunks and one
/// enormous one are both ways of asking a decoder for more memory than it should give.
@c @implementation
public func png_set_chunk_malloc_max(
    _ png_ptr: png_structrp?,
    _ user_chunk_malloc_max: png_alloc_size_t
) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    context.limits.chunkBytes = Int(user_chunk_malloc_max)
}

@c @implementation
public func png_get_chunk_malloc_max(_ png_ptr: png_const_structrp?) -> png_alloc_size_t {
    guard let png_ptr, let context = PngContext.from(png_structp(mutating: png_ptr)) else {
        return 0
    }

    return png_alloc_size_t(context.limits.chunkBytes)
}
