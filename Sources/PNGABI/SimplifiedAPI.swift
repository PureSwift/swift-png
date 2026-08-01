// SimplifiedAPI.swift - reading an image without deciding anything
//
// The rest of the library asks a client to describe what it wants a row at a time.  This asks for one
// thing: what the pixels should look like when they arrive.  Everything else — the depth the file
// used, whether it was indexed, whether it was interlaced, what its transparency meant — is the
// library's problem.
//
// Which makes this a layer rather than a decoder.  It works out which of the ordinary requests add up
// to the format the client named, makes them, and reads the rows into the client's own buffer.  The
// interesting part is the working out, and the interesting part of that is the light: the eight bit
// formats are encoded for a display and the sixteen bit ones are linear, so converting between them is
// not a matter of moving bits about.

import CPNG
import PNG

/// What a client asks for, as the flags the API defines.
struct SimplifiedFormat {
    let raw: UInt32

    var hasAlpha: Bool { self.raw & UInt32(PNG_FORMAT_FLAG_ALPHA) != 0 }
    var hasColor: Bool { self.raw & UInt32(PNG_FORMAT_FLAG_COLOR) != 0 }
    var isLinear: Bool { self.raw & UInt32(PNG_FORMAT_FLAG_LINEAR) != 0 }
    var isColormapped: Bool { self.raw & UInt32(PNG_FORMAT_FLAG_COLORMAP) != 0 }
    var isReversed: Bool { self.raw & UInt32(PNG_FORMAT_FLAG_BGR) != 0 }
    var alphaFirst: Bool { self.raw & UInt32(PNG_FORMAT_FLAG_AFIRST) != 0 }

    var channels: Int {
        (self.hasColor ? 3 : 1) + (self.hasAlpha ? 1 : 0)
    }

    var bytesPerChannel: Int { self.isLinear ? 2 : 1 }
}

/// Reads the header and describes the image in the API's own terms.
@c
public func spng_swift_image_read_header(
    _ image: png_imagep?,
    _ control: png_controlp?
) -> Int32 {
    guard let image, let control, let png_ptr = control.pointee.png_ptr,
          let info_ptr = control.pointee.info_ptr else {
        return 0
    }

    png_read_info(png_ptr, info_ptr)

    guard let info = InfoStore.from(info_ptr), let header = info.header else { return 0 }

    image.pointee.width = png_uint_32(header.width)
    image.pointee.height = png_uint_32(header.height)

    var format: UInt32 = 0

    // What the file is, said in the API's terms.  An indexed image is described as colour that
    // happens to be colour-mapped, because that is what a client can do something with; a transparent
    // colour counts as an alpha channel, because that is what it will become.
    if header.colorType.hasColor || header.colorType.isIndexed {
        format |= UInt32(PNG_FORMAT_FLAG_COLOR)
    }

    if header.colorType.hasAlpha || info.isValid(PNG_INFO_tRNS) {
        format |= UInt32(PNG_FORMAT_FLAG_ALPHA)
    }

    if header.colorType.isIndexed {
        format |= UInt32(PNG_FORMAT_FLAG_COLORMAP)
    }

    if header.bitDepth == 16 {
        format |= UInt32(PNG_FORMAT_FLAG_LINEAR)
    }

    image.pointee.format = format

    // How many entries a colour map would need.
    //
    // An indexed image says so itself.  A greyscale one narrower than a byte needs only as many as its
    // samples can take, which is the one place this is not simply the largest a map could be — and it
    // is worth having, since a client that asks for a colour-mapped grey gets a map it can index with
    // the samples directly.  Everything else could need the lot.
    if header.colorType.isIndexed {
        image.pointee.colormap_entries = png_uint_32(info.palette.elements.count)
    } else if !header.colorType.hasColor, header.bitDepth < 8 {
        image.pointee.colormap_entries = png_uint_32(1 << header.bitDepth)
    } else {
        image.pointee.colormap_entries = 256
    }

    return 1
}

/// Reads the image into the client's buffer, in the format it asked for.
@c
public func spng_swift_image_finish_read(
    _ image: png_imagep?,
    _ control: png_controlp?,
    _ background: png_const_colorp?,
    _ buffer: UnsafeMutableRawPointer?,
    _ row_stride: png_int_32,
    _ colormap: UnsafeMutableRawPointer?
) -> Int32 {
    guard let image, let control, let png_ptr = control.pointee.png_ptr,
          let info_ptr = control.pointee.info_ptr, let buffer else {
        return 0
    }

    let format = SimplifiedFormat(raw: image.pointee.format)

    // The messages below are short on purpose.  What a client is handed is a sixty four byte buffer,
    // and a sentence cut off in the middle of a word says less than it meant to.
    guard !format.isColormapped else {
        spng_c_error(png_ptr, "png_image: colour-mapped output not implemented")
    }

    guard let info = InfoStore.from(info_ptr), let header = info.header else { return 0 }

    // What this does not do yet, and refuses rather than approximates.
    //
    // Every one of these changes the light rather than the arrangement: taking coverage away means
    // compositing, taking colour away means averaging, and moving between eight bits and sixteen means
    // moving between an encoding and the light it encodes.  The reference does all three through a
    // wider intermediate than the ordinary requests can be made to use, and the results differ in the
    // low bits — so producing them would be producing something nearly right, which is worse than
    // saying so.
    let fileHasAlpha = header.colorType.hasAlpha || info.isValid(PNG_INFO_tRNS)

    // Removing coverage means compositing, and what onto is the client's answer.  A colour it named
    // is a colour to blend against; nothing named means blending against whatever its buffer already
    // holds, which the reference does with machinery of its own rather than through the ordinary
    // requests — so that one is refused and the other is not.
    if !format.hasAlpha, fileHasAlpha, background == nil {
        spng_c_error(png_ptr, "png_image: removing alpha onto the buffer not implemented")
    }

    if !format.hasColor, header.colorType.hasColor || header.colorType.isIndexed {
        spng_c_error(png_ptr, "png_image: discarding colour not implemented")
    }

    // A linear result is always a conversion, even from a sixteen bit file: the file's samples are
    // encoded for a display and this format's are light.  And a sixteen bit file read at eight bits is
    // the same conversion the other way.
    if format.isLinear || header.bitDepth == 16 {
        spng_c_error(png_ptr, "png_image: light conversion not implemented")
    }

    let passes = requestConversion(
        png_ptr,
        info_ptr,
        from: header,
        to: format,
        background: background
    )

    // The client may space its rows further apart than the pixels need, and may lay the image out
    // bottom-up by giving a negative stride.  Both are its business; what matters here is that every
    // row goes where it said.
    let minimum = Int(image.pointee.width) * format.channels * format.bytesPerChannel
    let stride = row_stride == 0 ? minimum : Int(row_stride) * format.bytesPerChannel
    let height = Int(image.pointee.height)

    guard abs(stride) >= minimum else {
        spng_c_error(png_ptr, "png_image: row stride too small")
    }

    let first = stride < 0
        ? buffer.advanced(by: -stride * (height - 1))
        : buffer

    // Every row once per pass.  An interlaced file holds the same picture as one that is not, and a
    // client of this API asked for a picture — so the passes are the library's business, and the rows
    // are swept as many times as it takes.
    for _ in 0 ..< passes {
        for row in 0 ..< height {
            let destination = first.advanced(by: stride * row)
                .assumingMemoryBound(to: UInt8.self)

            png_read_row(png_ptr, destination, nil)
        }
    }

    png_read_end(png_ptr, nil)

    return 1
}

/// Makes the ordinary requests that add up to the format the client named.
///
/// The order is the order a client would make them in and does not matter — the library resolves them
/// together — but the reasoning does, so each is here with what it is for.
@discardableResult
private func requestConversion(
    _ png_ptr: png_structrp?,
    _ info_ptr: png_inforp?,
    from header: Header,
    to format: SimplifiedFormat,
    background: png_const_colorp?
) -> Int {
    // Everything starts by becoming samples: an indexed row is indices, a transparent colour is not a
    // channel, and anything below eight bits is not a byte.
    png_set_expand(png_ptr)

    // The depth the client asked for.  Sixteen bit output is linear light, eight bit output is
    // encoded for a display, and this is where that is settled — the conversion between them is the
    // gamma machinery's, not a matter of moving bits.
    if format.isLinear {
        png_set_expand_16(png_ptr)
        png_set_alpha_mode(png_ptr, PNG_ALPHA_PNG, 1.0)
    } else {
        png_set_scale_16(png_ptr)

        // Negative asks for the display the format assumes when a file says nothing, which is what an
        // eight bit result is encoded for.  It is a value rather than a flag because the call takes a
        // number, and the number it takes here means "the usual one".
        png_set_alpha_mode_fixed(png_ptr, PNG_ALPHA_PNG, png_fixed_point(PNG_DEFAULT_sRGB))
    }

    // Colour the client did not ask for is averaged away; colour it asked for and the file has not is
    // made by repeating the grey.
    if format.hasColor, !header.colorType.hasColor, !header.colorType.isIndexed {
        png_set_gray_to_rgb(png_ptr)
    }

    if !format.hasColor, header.colorType.hasColor || header.colorType.isIndexed {
        png_set_rgb_to_gray(png_ptr, PNG_ERROR_ACTION_NONE, -1, -1)
    }

    let fileHasAlpha = header.colorType.hasAlpha
        || (info_ptr.flatMap { InfoStore.from($0)?.isValid(PNG_INFO_tRNS) } ?? false)

    if !format.hasAlpha, fileHasAlpha, let background {
        // Named in the sRGB the API speaks, and handed on at the depth the blend will happen at —
        // which is the row's, and the row's is eight bits here because a file with more is refused
        // above.  A colour widened for sixteen bits and given to an eight bit blend is not a darker
        // colour, it is out of range.
        var colour = png_color_16()

        colour.red = png_uint_16(background.pointee.red)
        colour.green = png_uint_16(background.pointee.green)
        colour.blue = png_uint_16(background.pointee.blue)

        // Grey output takes the green channel, which is the API's own rule and not an arbitrary one:
        // green is most of what a viewer sees as brightness.
        colour.gray = colour.green

        withUnsafePointer(to: &colour) {
            png_set_background_fixed(png_ptr, $0, PNG_BACKGROUND_GAMMA_SCREEN, 0, 0)
        }
    }

    if format.hasAlpha, !fileHasAlpha {
        // Opaque, since a file with nothing to say about coverage is a file with nothing hidden — and
        // put where the client wants it rather than added and then moved.  Adding it at the end and
        // swapping afterwards would not do: the swap runs before the channel is added, so the row it
        // would reverse has no coverage in it yet.
        png_set_add_alpha(
            png_ptr,
            0xFFFF,
            format.alphaFirst ? PNG_FILLER_BEFORE : PNG_FILLER_AFTER
        )
    }

    if format.isReversed {
        png_set_bgr(png_ptr)
    }

    // Only when the file brought the coverage with it.  One that did not had it put in the right
    // place above, and swapping now would move it back out.
    if format.alphaFirst, fileHasAlpha {
        png_set_swap_alpha(png_ptr)
    }

    // Sixteen bit samples are handed over in the order this machine reads them rather than the order
    // the file stores them.  A client of this API is given numbers to use, not bytes to parse.
    if format.isLinear, SimplifiedFormat.isLittleEndian {
        png_set_swap(png_ptr)
    }

    // Asked for before the pipeline is resolved, since it is itself part of the shape a row ends up
    // with.  The count comes back here rather than being worked out again by the caller.
    let passes = png_set_interlace_handling(png_ptr)

    png_read_update_info(png_ptr, info_ptr)

    return Int(passes)
}

extension SimplifiedFormat {
    /// Whether this machine reads a two byte number low end first.
    static var isLittleEndian: Bool {
        UInt16(1).littleEndian == 1
    }
}

// -- writing an image without deciding anything ------------------------------

/// Writes the image a client is holding, in whatever format it says it holds it.
///
/// The mirror of the reader, and simpler, because there is only one file to choose: the format the
/// client named decides the colour type and the depth, and nothing about the file is a judgement call.
@c
public func spng_swift_image_write(
    _ image: png_imagep?,
    _ control: png_controlp?,
    _ buffer: UnsafeRawPointer?,
    _ row_stride: png_int_32,
    _ convert_to_8_bit: Int32,
    _ colormap: UnsafeRawPointer?
) -> Int32 {
    guard let image, let control, let png_ptr = control.pointee.png_ptr,
          let info_ptr = control.pointee.info_ptr, let buffer else {
        return 0
    }

    let format = SimplifiedFormat(raw: image.pointee.format)

    guard !format.isColormapped else {
        spng_c_error(png_ptr, "png_image: colour-mapped input not implemented")
    }

    // Sixteen bit input is light and a file's samples are encoded, so writing one as the other is the
    // same conversion the reader refuses — and asking for it to be narrowed on the way is that
    // conversion by another name.
    guard !format.isLinear else {
        spng_c_error(png_ptr, "png_image: light conversion not implemented")
    }

    guard convert_to_8_bit == 0 || !format.isLinear else {
        spng_c_error(png_ptr, "png_image: narrowing on write not implemented")
    }

    let width = Int(image.pointee.width)
    let height = Int(image.pointee.height)

    guard width > 0, height > 0 else {
        spng_c_error(png_ptr, "png_image: no image to write")
    }

    // The colour type the format implies.  There is no choosing here: a client that said its pixels
    // have colour and coverage is describing exactly one of the format's types.
    let colorType: Int32

    switch (format.hasColor, format.hasAlpha) {
    case (true, true): colorType = PNG_COLOR_TYPE_RGB_ALPHA
    case (true, false): colorType = PNG_COLOR_TYPE_RGB
    case (false, true): colorType = PNG_COLOR_TYPE_GRAY_ALPHA
    case (false, false): colorType = PNG_COLOR_TYPE_GRAY
    }

    png_set_IHDR(
        png_ptr,
        info_ptr,
        png_uint_32(width),
        png_uint_32(height),
        8,
        colorType,
        PNG_INTERLACE_NONE,
        PNG_COMPRESSION_TYPE_DEFAULT,
        PNG_FILTER_TYPE_DEFAULT
    )

    png_write_info(png_ptr, info_ptr)

    // The client's rows are in the arrangement it named, and the file's are in the format's own.  Both
    // of these are their own inverses, which is why the same calls serve here as when reading.
    if format.isReversed {
        png_set_bgr(png_ptr)
    }

    if format.alphaFirst {
        png_set_swap_alpha(png_ptr)
    }

    let minimum = width * format.channels * format.bytesPerChannel
    let stride = row_stride == 0 ? minimum : Int(row_stride) * format.bytesPerChannel

    guard abs(stride) >= minimum else {
        spng_c_error(png_ptr, "png_image: row stride too small")
    }

    // A negative stride says the client holds the image bottom-up, which is its business: the file is
    // written top-down either way.
    let first = stride < 0
        ? buffer.advanced(by: -stride * (height - 1))
        : buffer

    for row in 0 ..< height {
        let source = first.advanced(by: stride * row)
            .assumingMemoryBound(to: UInt8.self)

        png_write_row(png_ptr, source)
    }

    png_write_end(png_ptr, info_ptr)

    return 1
}
