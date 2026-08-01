// WriteAPI.swift - the calls that produce a file
//
// The order these are called in is the order the file comes out in, which is why so little of the
// writer is stateful: the client's call sequence *is* the state.  What is enforced here is only what
// the format requires and the client cannot repair afterwards — a header before anything else, a
// palette before the image data, and nothing at all after the end.

import CPNG
import PNG

/// Writes the eight bytes that begin a file.
///
/// Rarely called by a client: `png_write_info` writes them first if they have not been written, which
/// is what makes the ordinary sequence work without thinking about it.
@c @implementation
public func png_write_sig(_ png_ptr: png_structrp?) {
    attempt(png_ptr) { context in
        try context.writeSignature()
    }
}

/// Writes the header, and the chunks that have to precede a palette.
@c @implementation
public func png_write_info_before_PLTE(_ png_ptr: png_structrp?, _ info_ptr: png_const_inforp?) {
    png_write_info(png_ptr, info_ptr)
}

/// Writes everything that comes before the image data.
@c @implementation
public func png_write_info(_ png_ptr: png_structrp?, _ info_ptr: png_const_inforp?) {
    attempt(png_ptr, png_inforp(mutating: info_ptr)) { context, info in
        guard let header = info.header else {
            throw Diagnostic("png_write_info called before png_set_IHDR")
        }

        try context.writeHeader(
            Header.Fields(
                width: UInt32(header.width),
                height: UInt32(header.height),
                bitDepth: UInt8(header.bitDepth),
                colorType: header.colorType.rawValue,

                // One method is defined for each of these and a header naming another would not have
                // survived being set, so the file says what the format says.
                compressionMethod: 0,
                filterMethod: 0,
                interlaceMethod: header.isInterlaced ? 1 : 0
            )
        )

        try context.writePalette(info)
    }
}

/// Compresses one scanline into the file.
@c @implementation
public func png_write_row(_ png_ptr: png_structrp?, _ row: png_const_bytep?) {
    attempt(png_ptr) { context in
        try context.writeRow(row)
    }
}

/// The same for a run of consecutive rows.
@c @implementation
public func png_write_rows(
    _ png_ptr: png_structrp?,
    _ row: png_bytepp?,
    _ num_rows: png_uint_32
) {
    attempt(png_ptr) { context in
        guard let row else { return }

        for index in 0 ..< Int(num_rows) {
            try context.writeRow(row[index])
        }
    }
}

/// Writes a whole image the client holds as an array of rows.
@c @implementation
public func png_write_image(_ png_ptr: png_structrp?, _ image: png_bytepp?) {
    attempt(png_ptr) { context in
        guard let image else { return }

        try context.writeImage(rows: image)
    }
}

/// Finishes the image data and ends the file.
@c @implementation
public func png_write_end(_ png_ptr: png_structrp?, _ info_ptr: png_inforp?) {
    attempt(png_ptr) { context in
        // The info structure is optional here, and what it carries is the text a client added after
        // writing its rows.  Without one there is nothing left to say.
        try context.writeEnd(info_ptr.flatMap { InfoStore.from($0) })
    }
}

// -- what the encoder is allowed to do ---------------------------------------

/// Says which filters the encoder may choose between.
///
/// A choice about size against speed, and nothing else: every filter decodes to the same image, so a
/// client that restricts them is trading compression for the time spent trying them.
@c @implementation
public func png_set_filter(_ png_ptr: png_structrp?, _ method: Int32, _ filters: Int32) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    // The single filter method the format defines.  Anything else describes a file this library
    // cannot write, so the request is refused rather than approximated.
    guard method == 0 else {
        spng_c_error(png_ptr, "Unknown custom filter method")
    }

    // Negative asks for the default, which is all of them.
    context.filters = filters < 0 ? .all : FilterMask(rawValue: filters).intersection(.all)
}

@c @implementation
public func png_set_compression_level(_ png_ptr: png_structrp?, _ level: Int32) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    context.compression.level = level
}

@c @implementation
public func png_set_compression_mem_level(_ png_ptr: png_structrp?, _ mem_level: Int32) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    context.compression.memoryLevel = mem_level
}

@c @implementation
public func png_set_compression_strategy(_ png_ptr: png_structrp?, _ strategy: Int32) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    context.compression.strategy = strategy
}

/// Sets the window the compressor remembers, in bits.
///
/// Clamped rather than refused, and the clamping is the reference's: a window smaller than the
/// format's floor is raised to it, one larger than its ceiling is lowered, and the client is told in
/// both cases.  An image smaller than the window it asked for also has it lowered, since a window
/// larger than the data is memory nothing will use.
@c @implementation
public func png_set_compression_window_bits(_ png_ptr: png_structrp?, _ window_bits: Int32) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    var bits = window_bits

    if bits > 15 {
        spng_c_warning(png_ptr, "Only compression windows <= 32k supported by PNG")
        bits = 15
    }

    if bits < 8 {
        spng_c_warning(png_ptr, "Only compression windows >= 256 supported by PNG")
        bits = 8
    }

    context.compression.windowBits = bits
}

@c @implementation
public func png_set_compression_method(_ png_ptr: png_structrp?, _ method: Int32) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    // The one method zlib defines.  The reference warns and carries on with it.
    if method != 8 {
        spng_c_warning(png_ptr, "Only compression method 8 is supported by PNG")
    }

    context.compression.method = 8
}

/// How much compressed output to gather before writing a chunk.
///
/// A chunk size and nothing more: the compressed stream is the same however it is cut up, so this
/// trades the number of chunks against the memory held for them.
@c @implementation
public func png_set_compression_buffer_size(_ png_ptr: png_structrp?, _ size: size_t) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    context.compression.bufferSize = max(Int(size), 1)
}

@c @implementation
public func png_get_compression_buffer_size(_ png_ptr: png_const_structrp?) -> size_t {
    guard let png_ptr, let context = PngContext.from(png_structp(mutating: png_ptr)) else {
        return 0
    }

    return size_t(context.compression.bufferSize)
}


// -- how text is compressed --------------------------------------------------
//
// Separate from the image data's settings because the two are compressing different things: image
// data is large and wants a large window, while a text chunk is usually a line or two, where the
// window is memory nothing will use.

@c @implementation
public func png_set_text_compression_level(_ png_ptr: png_structrp?, _ level: Int32) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    context.textCompression.level = level
}

@c @implementation
public func png_set_text_compression_mem_level(_ png_ptr: png_structrp?, _ mem_level: Int32) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    context.textCompression.memoryLevel = mem_level
}

@c @implementation
public func png_set_text_compression_strategy(_ png_ptr: png_structrp?, _ strategy: Int32) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    context.textCompression.strategy = strategy
}

@c @implementation
public func png_set_text_compression_window_bits(_ png_ptr: png_structrp?, _ window_bits: Int32) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    var bits = window_bits

    if bits > 15 {
        spng_c_warning(png_ptr, "Only compression windows <= 32k supported by PNG")
        bits = 15
    }

    if bits < 8 {
        spng_c_warning(png_ptr, "Only compression windows >= 256 supported by PNG")
        bits = 8
    }

    context.textCompression.windowBits = bits
}

@c @implementation
public func png_set_text_compression_method(_ png_ptr: png_structrp?, _ method: Int32) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    if method != 8 {
        spng_c_warning(png_ptr, "Only compression method 8 is supported by PNG")
    }

    context.textCompression.method = 8
}

// -- chunks of the client's own ----------------------------------------------
//
// A client that knows about a chunk this library does not can write it itself.  What it gets from
// here is the framing — the length, the type and the check value — because those are what it would
// have to get exactly right and what it has no way to compute without the writer's state.

/// Writes a whole chunk the client has built.
@c @implementation
public func png_write_chunk(
    _ png_ptr: png_structrp?,
    _ chunk_name: png_const_bytep?,
    _ data: png_const_bytep?,
    _ length: size_t
) {
    png_write_chunk_start(png_ptr, chunk_name, png_uint_32(length))
    png_write_chunk_data(png_ptr, data, length)
    png_write_chunk_end(png_ptr)
}

/// Starts a chunk whose contents the client will write in pieces.
@c @implementation
public func png_write_chunk_start(
    _ png_ptr: png_structrp?,
    _ chunk_name: png_const_bytep?,
    _ length: png_uint_32
) {
    attempt(png_ptr) { context in
        guard let chunk_name else { throw Diagnostic("png_write_chunk_start given no name") }

        try context.beginChunk(
            ChunkName(
                chunk_name[0],
                chunk_name[1],
                chunk_name[2],
                chunk_name[3]
            ),
            length: Int(length)
        )
    }
}

@c @implementation
public func png_write_chunk_data(
    _ png_ptr: png_structrp?,
    _ data: png_const_bytep?,
    _ length: size_t
) {
    attempt(png_ptr) { context in
        context.writeChunkData(
            UnsafeBufferPointer(start: data, count: Int(length))
        )
    }
}

@c @implementation
public func png_write_chunk_end(_ png_ptr: png_structrp?) {
    attempt(png_ptr) { context in
        context.endChunk()
    }
}

// -- flushing ----------------------------------------------------------------

/// Asks for the output to be flushed every so many rows.
///
/// For a client writing to something slow, or something another process is reading: without this the
/// bytes appear whenever the compressor happens to produce them, which for a small image can be not
/// until the end.
@c @implementation
public func png_set_flush(_ png_ptr: png_structrp?, _ nrows: Int32) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    context.flushEveryRows = max(Int(nrows), 0)
}

@c @implementation
public func png_write_flush(_ png_ptr: png_structrp?) {
    attempt(png_ptr) { context in
        try context.flushOutput()
    }
}

// -- writing an image the client holds whole ---------------------------------

/// Records the rows a client holds, so that `png_write_png` can find them.
@c @implementation
public func png_set_rows(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ row_pointers: png_bytepp?
) {
    guard let info_ptr, let info = InfoStore.from(info_ptr) else { return }

    info.rows = row_pointers
}

@c @implementation
public func png_get_rows(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_bytepp? {
    guard let info_ptr, let info = InfoStore.from(png_inforp(mutating: info_ptr)) else {
        return nil
    }

    return info.rows
}

/// Writes a whole file in one call, from rows the client has already set.
///
/// The transform argument names the same ordinary requests a client could make one at a time —
/// this makes them on the client's behalf, in the reference's own fixed order, before the rows go
/// out.  Read-only bits (`STRIP_16`, `STRIP_ALPHA`, `EXPAND`, `GRAY_TO_RGB`, `EXPAND_16`,
/// `SCALE_16`) have no write-side counterpart and are silently ignored here, the same as there.
@c @implementation
public func png_write_png(
    _ png_ptr: png_structrp?,
    _ info_ptr: png_inforp?,
    _ transforms: Int32,
    _ params: png_voidp?
) {
    attempt(png_ptr, info_ptr) { context, info in
        guard let rows = info.rows else {
            throw Diagnostic("no rows for png_write_image to write")
        }

        png_write_info(png_ptr, png_const_inforp(info_ptr))

        if transforms & PNG_TRANSFORM_INVERT_MONO != 0 {
            png_set_invert_mono(png_ptr)
        }

        // Needs the significant-bits chunk to know how far to move the samples; a client that
        // asked for this without ever calling png_set_sBIT is asking for nothing there is data
        // to act on, so it is quietly skipped rather than treated as a mistake.
        if transforms & PNG_TRANSFORM_SHIFT != 0, info.isValid(PNG_INFO_sBIT) {
            var bits = png_color_8()
            let significantBits = info.significantBits

            bits.red = significantBits.red
            bits.green = significantBits.green
            bits.blue = significantBits.blue
            bits.gray = significantBits.gray
            bits.alpha = significantBits.alpha

            withUnsafePointer(to: &bits) {
                png_set_shift(png_ptr, $0)
            }
        }

        if transforms & PNG_TRANSFORM_PACKING != 0 {
            png_set_packing(png_ptr)
        }

        if transforms & PNG_TRANSFORM_SWAP_ALPHA != 0 {
            png_set_swap_alpha(png_ptr)
        }

        // Asking to strip a filler from both ends at once is a contradiction.  The reference
        // reports it as a benign error and then, only when a client has configured those as
        // warnings rather than errors, continues anyway by favouring AFTER — a pre-1.6.10
        // compatibility shim, not a considered choice.  Reporting a benign error mid-write here
        // would mean calling into the client's handler, which can jump out, before this frame's
        // own locals have unwound — the exact hazard `attempt` exists to avoid (see Boundary.swift)
        // — so this throws instead, which reaches the client the same way but only after Swift has
        // already unwound everything above it.  The one difference from the reference: a client
        // that has configured benign errors as warnings does not get the AFTER fallback here, it
        // gets nothing written at all.  Narrow enough, and safe enough, to be worth it.
        let stripsFillerAfter = transforms & PNG_TRANSFORM_STRIP_FILLER_AFTER != 0
        let stripsFillerBefore = transforms & PNG_TRANSFORM_STRIP_FILLER_BEFORE != 0

        if stripsFillerAfter, stripsFillerBefore {
            throw Diagnostic(
                "PNG_TRANSFORM_STRIP_FILLER: BEFORE+AFTER not supported",
                severity: .benign
            )
        } else if stripsFillerAfter {
            png_set_filler(png_ptr, 0, PNG_FILLER_AFTER)
        } else if stripsFillerBefore {
            png_set_filler(png_ptr, 0, PNG_FILLER_BEFORE)
        }

        if transforms & PNG_TRANSFORM_BGR != 0 {
            png_set_bgr(png_ptr)
        }

        if transforms & PNG_TRANSFORM_SWAP_ENDIAN != 0 {
            png_set_swap(png_ptr)
        }

        if transforms & PNG_TRANSFORM_PACKSWAP != 0 {
            png_set_packswap(png_ptr)
        }

        if transforms & PNG_TRANSFORM_INVERT_ALPHA != 0 {
            png_set_invert_alpha(png_ptr)
        }

        try context.writeImage(rows: rows)
        try context.writeEnd(info)
    }
}
