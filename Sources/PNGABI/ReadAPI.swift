// ReadAPI.swift - the functions that drive a decode
//
// Each is a thin shell: resolve the engine objects, run one operation, and let the
// boundary turn a failure into the client's error handler.  The decoding itself is
// in the engine, which knows nothing about any of this.

import CPNG
import PNG

@c @implementation
public func png_read_info(_ png_ptr: png_structrp?, _ info_ptr: png_inforp?) {
    attempt(png_ptr, info_ptr) { context, info in
        try context.readInfo(into: info)
    }
}

/// Allocates the row buffers ahead of the first row.
///
/// Optional for a client to call: the first `png_read_row` does it if this was
/// skipped.
@c @implementation
public func png_start_read_image(_ png_ptr: png_structrp?) {
    attempt(png_ptr) { context in
        try context.startReadImage()
    }
}

/// Reads one scanline.
///
/// `row` receives the pixels. `display_row` is for the progressive display
/// arrangement, where a partially decoded interlaced image is shown as it
/// arrives; it has no effect until interlacing is supported.
@c @implementation
public func png_read_row(
    _ png_ptr: png_structrp?,
    _ row: png_bytep?,
    _ display_row: png_bytep?
) {
    attempt(png_ptr) { context in
        try context.readRow(into: row)

    }
}

@c @implementation
public func png_read_rows(
    _ png_ptr: png_structrp?,
    _ row: png_bytepp?,
    _ display_row: png_bytepp?,
    _ num_rows: png_uint_32
) {
    attempt(png_ptr) { context in
        for index in 0 ..< Int(num_rows) {
            // Either array may be absent, and an individual entry may be null to
            // decode a row without keeping it.
            try context.readRow(into: row?[index])
        }

    }
}

/// Reads the whole image.
///
/// The array must have one entry per row, each large enough for a row as the
/// client will receive it.
@c @implementation
public func png_read_image(_ png_ptr: png_structrp?, _ image: png_bytepp?) {
    attempt(png_ptr) { context in
        guard let image else {
            throw Diagnostic("png_read_image needs an array of row pointers")
        }

        try context.readImage(rows: image)

    }
}

@c @implementation
public func png_read_end(_ png_ptr: png_structrp?, _ info_ptr: png_inforp?) {
    attempt(png_ptr) { context in
        // The info structure is optional: a client that does not want the metadata after
        // the image data passes null, and the stream is still walked to the end marker.
        try context.readEnd(into: info_ptr.flatMap { InfoStore.from($0) })
    }
}

/// Asks for an interlaced image's passes to arrive as full-width rows, and reports how many
/// times every row has to be read.
///
/// Seven for an interlaced image, one otherwise, so a client can loop that many times
/// without caring which it has.
@c @implementation
public func png_set_interlace_handling(_ png_ptr: png_structrp?) -> Int32 {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return 1 }
    return Int32(context.enableInterlaceHandling())
}

/// Which pass the decoder is on.
@c @implementation
public func png_get_current_pass_number(_ png_ptr: png_const_structrp?) -> png_byte {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return 0 }
    return context.currentPass
}

/// Declares how many signature bytes the client already read and checked.
///
/// A client that sniffed the file to identify it uses this so that the decoder
/// does not expect those bytes again.
@c @implementation
public func png_set_sig_bytes(_ png_ptr: png_structrp?, _ num_bytes: Int32) {
    attempt(png_ptr) { context in
        guard num_bytes >= 0, num_bytes <= 8 else {
            throw Diagnostic("Too many bytes for PNG signature")
        }

        context.signatureBytesConsumed = Int(num_bytes)
    }
}

// -- reading what has arrived so far -----------------------------------------
//
// The other way round from the calls above.  A client that cannot promise to produce bytes on demand —
// one reading from a network, or from a file it is still receiving — hands over whatever it has and is
// called back with whatever that completes.
//
// Which makes the client's callbacks the whole of the interface: there is no row to return, because
// the call that would have returned it may end half way through a chunk.

/// Installs the three callbacks a progressive read reports through.
@c @implementation
public func png_set_progressive_read_fn(
    _ png_ptr: png_structrp?,
    _ progressive_ptr: png_voidp?,
    _ info_fn: png_progressive_info_ptr?,
    _ row_fn: png_progressive_row_ptr?,
    _ end_fn: png_progressive_end_ptr?
) {
    guard let png_ptr else { return }

    png_ptr.pointee.info_fn = info_fn
    png_ptr.pointee.row_fn = row_fn
    png_ptr.pointee.end_fn = end_fn
    png_ptr.pointee.progressive_ptr = progressive_ptr
}

@c @implementation
public func png_get_progressive_ptr(_ png_ptr: png_const_structrp?) -> png_voidp? {
    png_ptr?.pointee.progressive_ptr
}

/// Hands over bytes that have arrived.
///
/// Everything given is consumed unless the client pauses, which it does from inside one of its own
/// callbacks; what is left then is the client's to hand over again.
@c @implementation
public func png_process_data(
    _ png_ptr: png_structrp?,
    _ info_ptr: png_inforp?,
    _ buffer: png_bytep?,
    _ buffer_size: size_t
) {
    attempt(png_ptr) { context in
        guard let buffer else { return }

        // Kept for the length of this push, so that the callbacks can be handed the structure the
        // client named.  Borrowed rather than owned: it is the client's, and the machine does not
        // outlive the call.
        png_ptr?.pointee.progressive_info = info_ptr

        defer { png_ptr?.pointee.progressive_info = nil }

        try context.processData(
            UnsafeBufferPointer(start: buffer, count: Int(buffer_size)),
            info: info_ptr.flatMap { InfoStore.from($0) }
        )
    }
}

/// Stops the current call and says how much of what it was given is left over.
///
/// Called from inside a callback.  The count it returns is what the client must hand over again,
/// which is why it is measured from the end rather than the beginning: the client knows what it gave.
@c @implementation
public func png_process_data_pause(_ png_ptr: png_structrp?, _ save: Int32) -> size_t {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return 0 }

    return size_t(context.pauseProcessing(saving: save != 0))
}

/// Says the client has thrown away the rest of the chunk being read.
///
/// For a chunk a client wants nothing to do with: rather than pushing its bytes through only to have
/// them ignored, it says how many it dropped and the machine counts them off.
@c @implementation
public func png_process_data_skip(_ png_ptr: png_structrp?) -> png_uint_32 {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return 0 }

    return png_uint_32(context.skipRemainingChunk())
}

/// Places a row the client was just handed into the image it is assembling.
///
/// Only useful for an interlaced image, where a pass's rows are narrower than the image's and belong
/// at every nth pixel.  For an image that is not interlaced it is a copy.
@c @implementation
public func png_progressive_combine_row(
    _ png_ptr: png_const_structrp?,
    _ old_row: png_bytep?,
    _ new_row: png_const_bytep?
) {
    guard let png_ptr, let context = PngContext.from(png_structp(mutating: png_ptr)),
          let old_row, let new_row else { return }

    context.combineRow(into: old_row, from: new_row)
}

// -- reading a whole file in one call ----------------------------------------

/// Reads an entire image, allocating the rows to hold it.
///
/// The convenience form, for a client that wants the pixels and has no interest in how they arrive.
/// What it gives up is the streaming: the whole image is in memory at once, which for a large one is
/// the difference between a decoder that works and one that does not.
///
/// The rows belong to the library and are released with the structure that holds them.
@c @implementation
public func png_read_png(
    _ png_ptr: png_structrp?,
    _ info_ptr: png_inforp?,
    _ transforms: Int32,
    _ params: png_voidp?
) {
    attempt(png_ptr, info_ptr) { context, info in
        png_read_info(png_ptr, info_ptr)

        // The requests are made here rather than by the client, which is the whole point of the call:
        // a client that wanted to make them itself would be using the ordinary sequence.
        applyReadTransforms(png_ptr, info_ptr, transforms)

        // Turned on here rather than left to the client, because the client is not reading the rows:
        // the whole image is being assembled on its behalf, and a pass's narrow rows would not fit
        // the array it is about to be handed.
        _ = png_set_interlace_handling(png_ptr)

        png_read_update_info(png_ptr, info_ptr)

        try info.allocateRows(rowBytes: context.transformedShape?.rowBytes ?? info.rowBytes)

        guard let rows = info.rows else { return }

        try context.readImage(rows: rows)

        png_read_end(png_ptr, info_ptr)
    }
}

/// Turns the bits `png_read_png` takes into the requests they stand for.
///
/// Spelled out one at a time rather than driven by a table, because each is a different call with
/// different arguments — and because the two that are not simply "do this" are worth seeing: the
/// shift needs the significant bits the file declared, and asking for both ways of narrowing sixteen
/// bit samples is a choice the resolution below makes rather than one made here.
private func applyReadTransforms(
    _ png_ptr: png_structrp?,
    _ info_ptr: png_inforp?,
    _ transforms: Int32
) {
    if transforms & PNG_TRANSFORM_SCALE_16 != 0 { png_set_scale_16(png_ptr) }
    if transforms & PNG_TRANSFORM_STRIP_16 != 0 { png_set_strip_16(png_ptr) }
    if transforms & PNG_TRANSFORM_STRIP_ALPHA != 0 { png_set_strip_alpha(png_ptr) }
    if transforms & PNG_TRANSFORM_PACKING != 0 { png_set_packing(png_ptr) }
    if transforms & PNG_TRANSFORM_PACKSWAP != 0 { png_set_packswap(png_ptr) }
    if transforms & PNG_TRANSFORM_EXPAND != 0 { png_set_expand(png_ptr) }
    if transforms & PNG_TRANSFORM_INVERT_MONO != 0 { png_set_invert_mono(png_ptr) }

    // Only when the file said what its significant bits were: without that there is nothing to shift
    // by, and the reference asks for the shift only when it has an answer.
    if transforms & PNG_TRANSFORM_SHIFT != 0 {
        var bits: png_color_8p?

        if png_get_sBIT(png_ptr, info_ptr, &bits) != 0, let bits {
            png_set_shift(png_ptr, bits)
        }
    }

    if transforms & PNG_TRANSFORM_BGR != 0 { png_set_bgr(png_ptr) }
    if transforms & PNG_TRANSFORM_SWAP_ALPHA != 0 { png_set_swap_alpha(png_ptr) }
    if transforms & PNG_TRANSFORM_SWAP_ENDIAN != 0 { png_set_swap(png_ptr) }
    if transforms & PNG_TRANSFORM_INVERT_ALPHA != 0 { png_set_invert_alpha(png_ptr) }
    if transforms & PNG_TRANSFORM_GRAY_TO_RGB != 0 { png_set_gray_to_rgb(png_ptr) }
    if transforms & PNG_TRANSFORM_EXPAND_16 != 0 { png_set_expand_16(png_ptr) }
}
