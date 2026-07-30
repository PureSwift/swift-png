// ReadAPI.swift - the functions that drive a decode
//
// Each is a thin shell: resolve the engine objects, run one operation, and let the
// boundary turn a failure into the client's error handler.  The decoding itself is
// in the engine, which knows nothing about any of this.

import CPNG
import PNGCore

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
