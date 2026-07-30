// WriteAPI.swift - the calls that produce a file
//
// The order these are called in is the order the file comes out in, which is why so little of the
// writer is stateful: the client's call sequence *is* the state.  What is enforced here is only what
// the format requires and the client cannot repair afterwards — a header before anything else, a
// palette before the image data, and nothing at all after the end.

import CPNG
import PNGCore

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
