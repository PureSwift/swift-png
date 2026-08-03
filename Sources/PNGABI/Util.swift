// Util.swift - published functions that need no library state
//
// These depend on nothing but their arguments, which makes them the natural
// place to establish the pattern the rest of the exported surface follows:
// `@c @implementation` binds the Swift function to the declaration in the
// vendored png.h, and the compiler rejects any signature that does not match
// it, so the exported ABI cannot drift from the header.

import CPNG

@c @implementation
public func png_access_version_number() -> png_uint_32 {
    png_uint_32(PNG_LIBPNG_VER)
}

@c @implementation
public func png_get_copyright(_ png_ptr: png_const_structrp?) -> png_const_charp? {
    Version.copyright
}

@c @implementation
public func png_get_libpng_ver(_ png_ptr: png_const_structrp?) -> png_const_charp? {
    Version.string
}

@c @implementation
public func png_get_header_ver(_ png_ptr: png_const_structrp?) -> png_const_charp? {
    Version.string
}

@c @implementation
public func png_get_header_version(_ png_ptr: png_const_structrp?) -> png_const_charp? {
    Version.headerVersion
}

/// Compares up to eight bytes against the PNG signature.
///
/// Returns zero when the compared range matches, and a non-zero value
/// otherwise. A `start` beyond the end of the signature is a caller error and
/// reports as a mismatch.
@c @implementation
public func png_sig_cmp(
    _ sig: png_const_bytep?,
    _ start: Int,
    _ num_to_check: Int
) -> Int32 {
    guard let sig else { return -1 }

    let signature: [png_byte] = [137, 80, 78, 71, 13, 10, 26, 10]

    var count = num_to_check
    if start >= signature.count { return -1 }
    if start + count > signature.count { count = signature.count - start }

    for offset in 0 ..< count where sig[start + offset] != signature[start + offset] {
        return -1
    }

    return 0
}

@c @implementation
public func png_get_uint_32(_ buf: png_const_bytep?) -> png_uint_32 {
    guard let buf else { return 0 }
    return png_uint_32(buf[0]) << 24 | png_uint_32(buf[1]) << 16
        | png_uint_32(buf[2]) << 8 | png_uint_32(buf[3])
}

@c @implementation
public func png_get_uint_16(_ buf: png_const_bytep?) -> png_uint_16 {
    guard let buf else { return 0 }
    return png_uint_16(buf[0]) << 8 | png_uint_16(buf[1])
}

/// Reads a big-endian 32-bit value that a PNG stream requires to fit in 31
/// bits, reporting an error through `png_ptr` when it does not.
@c @implementation
public func png_get_uint_31(
    _ png_ptr: png_const_structrp?,
    _ buf: png_const_bytep?
) -> png_uint_32 {
    let value = png_get_uint_32(buf)

    if value > 0x7FFF_FFFF {
        // Nothing in this frame owns memory, so jumping from here is safe.
        swift_c_error(png_ptr, "PNG unsigned integer out of range")
    }

    return value
}

/// Reads a big-endian two's complement signed 32-bit value.
///
/// Returns zero for the one bit pattern whose negation does not fit, which no
/// valid stream contains; the value only ever arrives from a file, so a
/// defensible answer is better than a trap on hostile input.
@c @implementation
public func png_get_int_32(_ buf: png_const_bytep?) -> png_int_32 {
    let value = png_get_uint_32(buf)

    if value & 0x8000_0000 == 0 {
        return png_int_32(value)
    }

    let negated = (value ^ 0xFFFF_FFFF) &+ 1

    if negated & 0x8000_0000 == 0 {
        return -png_int_32(negated)
    }

    return 0
}

@c @implementation
public func png_save_uint_32(_ buf: png_bytep?, _ i: png_uint_32) {
    guard let buf else { return }
    buf[0] = png_byte(truncatingIfNeeded: i >> 24)
    buf[1] = png_byte(truncatingIfNeeded: i >> 16)
    buf[2] = png_byte(truncatingIfNeeded: i >> 8)
    buf[3] = png_byte(truncatingIfNeeded: i)
}

@c @implementation
public func png_save_uint_16(_ buf: png_bytep?, _ i: UInt32) {
    guard let buf else { return }
    buf[0] = png_byte(truncatingIfNeeded: i >> 8)
    buf[1] = png_byte(truncatingIfNeeded: i)
}

@c @implementation
public func png_save_int_32(_ buf: png_bytep?, _ i: png_int_32) {
    png_save_uint_32(buf, png_uint_32(bitPattern: i))
}

/// Fills `palette` with the evenly spaced grey ramp for the given bit depth.
@c @implementation
public func png_build_grayscale_palette(_ bit_depth: Int32, _ palette: png_colorp?) {
    guard let palette else { return }

    let entries: Int
    let step: png_byte

    switch bit_depth {
    case 1: entries = 2; step = 0xFF
    case 2: entries = 4; step = 0x55
    case 4: entries = 16; step = 0x11
    case 8: entries = 256; step = 0x01
    default: return
    }

    for index in 0 ..< entries {
        let value = png_byte(truncatingIfNeeded: index &* Int(step))
        palette[index].red = value
        palette[index].green = value
        palette[index].blue = value
    }
}
