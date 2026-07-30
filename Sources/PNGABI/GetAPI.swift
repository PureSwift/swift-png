// GetAPI.swift - reading the image description back
//
// These report what the header said.  They take the info structure rather than the
// control structure, and they answer zero rather than failing when asked before the
// header has been read, which is what the reference implementation does for a
// client that asks too early.

import CPNG
import PNGCore

/// Runs a query against the info structure, answering `fallback` when there is
/// nothing to query.
///
/// Queries do not report errors: a client calling these before `png_read_info` gets
/// a zero, not a jump.
private func query<Value>(
    _ info_ptr: png_const_inforp?,
    _ fallback: Value,
    _ body: (InfoStore) -> Value
) -> Value {
    guard let info_ptr, let info = InfoStore.from(info_ptr) else { return fallback }
    return body(info)
}

@c @implementation
public func png_get_image_width(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_uint_32 {
    query(info_ptr, 0) { $0.width }
}

@c @implementation
public func png_get_image_height(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_uint_32 {
    query(info_ptr, 0) { $0.height }
}

@c @implementation
public func png_get_bit_depth(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_byte {
    query(info_ptr, 0) { $0.bitDepth }
}

@c @implementation
public func png_get_color_type(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_byte {
    query(info_ptr, 0) { $0.colorType }
}

/// Samples per pixel.
///
/// Reports what the file stores until `png_read_update_info` runs, after which it
/// reports what the configured transforms produce.
@c @implementation
public func png_get_channels(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_byte {
    query(info_ptr, 0) { $0.channels }
}

@c @implementation
public func png_get_interlace_type(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_byte {
    query(info_ptr, 0) { $0.interlaceType }
}

/// Only one method is defined for each of these, so the answer is fixed; they exist
/// so that a client can check rather than assume.
@c @implementation
public func png_get_compression_type(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_byte {
    query(info_ptr, 0) { _ in png_byte(PNG_COMPRESSION_TYPE_BASE) }
}

@c @implementation
public func png_get_filter_type(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_byte {
    query(info_ptr, 0) { _ in png_byte(PNG_FILTER_TYPE_BASE) }
}

/// Bytes in one row as the client will receive it.
///
/// This is what a client allocates from, so it has to account for whatever
/// transforms are configured; until they are, it is the stored row size.
@c @implementation
public func png_get_rowbytes(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> size_t {
    query(info_ptr, 0) { size_t($0.rowBytes) }
}

/// Reads the header fields in one call, skipping any the client passed null for.
@c @implementation
public func png_get_IHDR(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ width: UnsafeMutablePointer<png_uint_32>?,
    _ height: UnsafeMutablePointer<png_uint_32>?,
    _ bit_depth: UnsafeMutablePointer<Int32>?,
    _ color_type: UnsafeMutablePointer<Int32>?,
    _ interlace_type: UnsafeMutablePointer<Int32>?,
    _ compression_type: UnsafeMutablePointer<Int32>?,
    _ filter_type: UnsafeMutablePointer<Int32>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.header != nil else { return 0 }

        width?.pointee = info.width
        height?.pointee = info.height
        bit_depth?.pointee = Int32(info.bitDepth)
        color_type?.pointee = Int32(info.colorType)
        interlace_type?.pointee = Int32(info.interlaceType)
        compression_type?.pointee = PNG_COMPRESSION_TYPE_BASE
        filter_type?.pointee = PNG_FILTER_TYPE_BASE

        return 1
    }
}

/// Reports which optional chunks were present.
///
/// The argument is a mask, and the result is the subset of it that applies, so a
/// client tests one flag at a time.
@c @implementation
public func png_get_valid(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ flag: png_uint_32
) -> png_uint_32 {
    query(info_ptr, 0) { $0.validChunks & flag }
}

/// The row the decoder will produce next.
@c @implementation
public func png_get_current_row_number(_ png_ptr: png_const_structrp?) -> png_uint_32 {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return 0 }
    return context.currentRow
}
