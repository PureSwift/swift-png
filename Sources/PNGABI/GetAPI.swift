// GetAPI.swift - reading the image description back
//
// These report what the header said.  They take the info structure rather than the
// control structure, and they answer zero rather than failing when asked before the
// header has been read, which is what the reference implementation does for a
// client that asks too early.

import CPNG
import PNG

/// Runs a query against the info structure, answering `fallback` when there is
/// nothing to query.
///
/// Queries do not report errors: a client calling these before `png_read_info` gets
/// a zero, not a jump.
func query<Value>(
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

/// Describes an image a client is about to write, or corrects one it has read.
///
/// The combination is checked here rather than accepted and rejected later, because every
/// size the rest of the library works from is derived from these fields, and deriving them
/// from an impossible combination would produce buffer sizes nothing could satisfy.
@c @implementation
public func png_set_IHDR(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ width: png_uint_32,
    _ height: png_uint_32,
    _ bit_depth: Int32,
    _ color_type: Int32,
    _ interlace_type: Int32,
    _ compression_type: Int32,
    _ filter_type: Int32
) {
    guard let info_ptr, let info = InfoStore.from(info_ptr) else { return }

    let fields = Header.Fields(
        width: width,
        height: height,
        bitDepth: UInt8(truncatingIfNeeded: bit_depth),
        colorType: UInt8(truncatingIfNeeded: color_type),
        compressionMethod: UInt8(truncatingIfNeeded: compression_type),
        filterMethod: UInt8(truncatingIfNeeded: filter_type),
        interlaceMethod: UInt8(truncatingIfNeeded: interlace_type)
    )

    let problems = fields.problems

    if !problems.isEmpty {
        guard let png_ptr else { return }

        // Reported the way a bad header in a file is: one warning per fault, then a single
        // failure. The info structure's own host is used, since it is the one whose
        // allocator and callbacks belong to this client.
        problems.report(to: info.host)
        spng_c_error(png_structp(mutating: png_ptr), "Invalid IHDR data")
    }

    info.header = Header(fields)
}

/// The row the decoder will produce next.
@c @implementation
public func png_get_current_row_number(_ png_ptr: png_const_structrp?) -> png_uint_32 {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return 0 }
    return context.currentRow
}

/// The eight bytes a file began with, as they were read.
///
/// Useful for a client that wants to know what it actually saw rather than that it was accepted: the
/// bytes are kept whether or not they were the right ones.
@c @implementation
public func png_get_signature(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_const_bytep? {
    guard let info_ptr, let info = InfoStore.from(png_inforp(mutating: info_ptr)) else {
        return nil
    }

    return info.signatureBytes()
}

/// The largest palette index the image data actually used.
///
/// Not what the palette holds — what the pixels reached.  A client can use it to shrink a palette
/// that is larger than the image needs, and it is why the count is tracked while rows are read rather
/// than worked out afterwards.
@c @implementation
public func png_get_palette_max(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> Int32 {
    // Minus one rather than nought when there is nothing to answer from, which distinguishes "no
    // answer" from "the rows only ever named the first entry".
    guard let png_ptr, info_ptr != nil,
          let context = PngContext.from(png_structp(mutating: png_ptr)) else {
        return -1
    }

    return Int32(context.highestPaletteIndex)
}
