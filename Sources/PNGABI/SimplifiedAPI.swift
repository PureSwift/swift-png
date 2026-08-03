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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
public func swift_swift_image_read_header(
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
public func swift_swift_image_finish_read(
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

    guard let info = InfoStore.from(info_ptr), let header = info.header else { return 0 }

    // The three colour-mapped cases built so far, every one an opaque source with no coverage of
    // its own: a greyscale file into a greyscale colour map (colour asked back from it or not), an
    // RGB file into either the reference's fixed six-by-six-by-six colour cube or, discarding its
    // colour, the same grey map the first case builds, and an indexed file into its own palette,
    // corrected.  Everything else — coverage in any of these, sixteen bits — still refuses.
    if format.isColormapped {
        let fileHasAlpha = header.colorType.hasAlpha || info.isValid(PNG_INFO_tRNS)

        // Colour asked back from a grey source is not a conversion the way the reverse is: every
        // channel just repeats the one light level a grey file has, so there is nothing here that
        // needs the averaging discarding an RGB source's colour does.  Coverage in the output is
        // the same free addition it is for the palette case, for the same reason: every entry but
        // one is opaque either way, and unlike coverage carried a channel at a time, a single
        // named transparent value never touches the rows — only the one map entry it points at.
        if !format.isLinear, header.colorType == .grayscale, header.bitDepth <= 8,
            format.hasAlpha || background != nil || !fileHasAlpha {
            return readGrayColormap(
                image: image, png_ptr: png_ptr, info_ptr: info_ptr, info: info, header: header,
                background: background, buffer: buffer, rowStride: row_stride, colormap: colormap
            )
        }

        // Coverage kept through a colour map is its own layout, not a correction of a byte already
        // there — see the function itself for why.  A single named transparent value never
        // reaches here: the branch above already handles every `.grayscale` source, coverage kept
        // or not, since nothing about a value that is either wholly there or wholly gone needs
        // this map's finer alpha grading.
        if header.colorType == .grayscaleAlpha, format.hasAlpha, !format.isLinear {
            return readGAColormap(
                image: image, png_ptr: png_ptr, info_ptr: info_ptr, header: header,
                background: nil, buffer: buffer, rowStride: row_stride, colormap: colormap
            )
        }

        // Coverage removed rather than kept collapses back to an ordinary grey ramp whenever a
        // named background is a single fixed colour is all a blend needs to settle into — no
        // reason to build the finer twenty-six-entry layout above only to have every pixel land on
        // whichever one grey level the background happens to match.  Only when the output wants
        // colour *and* the named background is not itself a shade of grey does a settled-into
        // colour vary by more than one channel, and the finer layout — every entry now opaque,
        // holding a real blend rather than the raw grey a kept alpha channel leaves ungraded — is
        // what a per-pixel compose would otherwise cost.
        if header.colorType == .grayscaleAlpha, !format.hasAlpha, !format.isLinear {
            guard let background else {
                swift_c_error(png_ptr, "background color must be supplied to remove alpha/transparency")
            }

            let backgroundIsGrey = background.pointee.red == background.pointee.green
                && background.pointee.green == background.pointee.blue

            if !format.hasColor || backgroundIsGrey {
                return readGrayAlphaComposedColormap(
                    image: image, png_ptr: png_ptr, info_ptr: info_ptr, header: header,
                    background: background, buffer: buffer, rowStride: row_stride, colormap: colormap
                )
            }

            return readGAColormap(
                image: image, png_ptr: png_ptr, info_ptr: info_ptr, header: header,
                background: background, buffer: buffer, rowStride: row_stride, colormap: colormap
            )
        }

        // Discarding an RGB source's colour is ordinary averaging, safe here for the same reason
        // it is for the ordinary (non-colour-mapped) reader — nothing about it needs the
        // gamma-aware compositing that combining it with real coverage would, and this file has
        // none.  Unlike the grey-source case above, the map here is not a correction of the raw
        // file bytes: png_set_rgb_to_gray decodes, averages and re-encodes each pixel itself, so
        // what reaches the row is already the sRGB byte the client wants, and the map is the
        // identity — the reference builds it the same way, as 256 entries of `i, i, i`.
        if !format.hasColor, !format.isLinear, header.colorType == .rgb, !fileHasAlpha {
            return readColorReducedGrayColormap(
                image: image, png_ptr: png_ptr, info_ptr: info_ptr, header: header,
                buffer: buffer, rowStride: row_stride, colormap: colormap
            )
        }

        // `.rgba` is never reached here: that colour type carries an alpha channel by
        // definition, so `!fileHasAlpha` already rules it out — a source with genuinely no
        // coverage to remove is always `.rgb`.
        if format.hasColor, !format.hasAlpha, !format.isLinear,
            header.colorType == .rgb, !fileHasAlpha {
            return readRGBColormap(
                image: image, png_ptr: png_ptr, info_ptr: info_ptr, header: header,
                buffer: buffer, rowStride: row_stride, colormap: colormap
            )
        }

        // An RGB or RGBA source with real coverage of its own, colour asked back: the reference's
        // fixed cube gains a hundred and twenty eight further entries a pixel's own coverage picks
        // among — kept or removed, the layout and the row-by-row classification that reaches it
        // are the same either way, since a per-pixel compose is exactly what this coarse
        // classification exists to avoid; only what removed coverage settles into differs, and
        // only when a named background does not already fall exactly on the cube's own grid does
        // that difference need entries of its own rather than the ordinary background composite
        // the opaque cube already uses.
        if format.hasColor, !format.isLinear,
            header.colorType == .rgb || header.colorType == .rgba, fileHasAlpha {
            guard format.hasAlpha || background != nil else {
                swift_c_error(png_ptr, "background color must be supplied to remove alpha/transparency")
            }

            return readRGBAlphaColormap(
                image: image, png_ptr: png_ptr, info_ptr: info_ptr, header: header,
                background: background, buffer: buffer, rowStride: row_stride, colormap: colormap
            )
        }

        // An indexed source's own palette, corrected, and — now — composited where its own tRNS
        // table says an entry is not fully opaque: every row byte is already the index a client
        // wants, unchanged, so the only work coverage adds here is in the map, not the rows.  Kept
        // in the output alongside the source's own is the easy half, the same constant-255 case as
        // an opaque source; removed needs a colour to blend against, and unlike the ordinary
        // reader there is no client buffer for a colour-mapped read to fall back on — a fixed map
        // cannot remember what pixel it will end up written over — so a background is required
        // outright rather than merely preferred.
        if format.hasColor, !format.isLinear, header.colorType.isIndexed,
            format.hasAlpha || background != nil || !fileHasAlpha {
            return readPaletteColormap(
                image: image, png_ptr: png_ptr, info_ptr: info_ptr, info: info, header: header,
                background: background, buffer: buffer, rowStride: row_stride, colormap: colormap
            )
        }

        if header.colorType.isIndexed, format.hasColor, !format.isLinear {
            swift_c_error(png_ptr, "background color must be supplied to remove alpha/transparency")
        }

        if header.colorType == .grayscale, header.bitDepth <= 8, !format.isLinear, fileHasAlpha {
            swift_c_error(png_ptr, "background color must be supplied to remove alpha/transparency")
        }

        swift_c_error(png_ptr, "png_image: colour-mapped output not implemented")
    }

    // What this does not do yet, and refuses rather than approximates.  The messages are short on
    // purpose: what a client is handed is a sixty four byte buffer, and a sentence cut off in the
    // middle of a word says less than it meant to.
    //
    // Every one of these changes the light rather than the arrangement: taking coverage away means
    // compositing, taking colour away means averaging, and moving between eight bits and sixteen means
    // moving between an encoding and the light it encodes.  The reference does most of these through a
    // wider intermediate than the ordinary requests can be made to use, and the results differ in the
    // low bits — so producing them would be producing something nearly right, which is worse than
    // saying so.
    let fileHasAlpha = header.colorType.hasAlpha || info.isValid(PNG_INFO_tRNS)

    // Removing coverage means compositing, and what onto is the client's answer — at eight bits.  At
    // sixteen the alpha-mode step already composites against black as part of turning the channel
    // into premultiplied light, so there is nothing left for a background to name; the reference does
    // not look at one there either.  Only the eight bit case needs one supplied — or, now, nothing at
    // all: naming none is itself an answer, the client's own buffer, and that case is built below
    // rather than refused.
    //
    // Not for an indexed source, and this one is not the same free extension every other colour-
    // mapped case in this file turned out to be: tried once, against the corpus rather than by
    // inspection, an indexed source through this exact path produced real wrong bytes, not the
    // refusal message this comment used to describe — png_set_expand alone was not the whole story
    // the way it was everywhere else, and finding what else differs is its own piece of work rather
    // than a small extension of this one.  Left refused, correctly, rather than shipped wrong.
    if !format.hasAlpha, fileHasAlpha, background == nil, !format.isLinear {
        guard !header.colorType.isIndexed,
            format.hasColor == header.colorType.hasColor || !format.hasColor else {
            swift_c_error(png_ptr, "png_image: removing alpha onto the buffer not implemented")
        }

        // What a file with no gAMA of its own is assumed to have been encoded with — the same
        // question requestConversion answers below, asked again here since a source with real
        // coverage to remove never reaches that call at all.
        let assumesLinearInput = header.bitDepth == 16
            && image.pointee.flags & png_uint_32(PNG_IMAGE_FLAG_16BIT_sRGB) == 0

        if format.hasColor == header.colorType.hasColor {
            return readComposite(
                image: image, png_ptr: png_ptr, info_ptr: info_ptr, header: header, format: format,
                assumesLinearInput: assumesLinearInput, buffer: buffer, rowStride: row_stride
            )
        }

        // Colour is being discarded as well as coverage — the only mismatch reaching here, since
        // the guard above refuses the opposite direction: png_set_rgb_to_gray and compositing can't
        // run in the same pass without the double gamma correction bug the reference works around
        // by doing this part itself — so this library does too, rather than asking the library to
        // do both at once.  See the caller's own no-background case above; this is the same idea,
        // averaged to one channel first.
        return readColorReducedComposite(
            image: image, png_ptr: png_ptr, info_ptr: info_ptr, header: header,
            assumesLinearInput: assumesLinearInput, background: nil, buffer: buffer,
            rowStride: row_stride
        )
    }

    // The same colour-and-coverage combination as above, but blended against a background the
    // client named instead of the client's own buffer.  Named or not is the same operation once the
    // colour is already gone, so both reach the one function.
    if !format.hasAlpha, fileHasAlpha, let background, !format.isLinear,
        !format.hasColor, header.colorType.hasColor, !header.colorType.isIndexed {
        let assumesLinearInput = header.bitDepth == 16
            && image.pointee.flags & png_uint_32(PNG_IMAGE_FLAG_16BIT_sRGB) == 0

        return readColorReducedComposite(
            image: image, png_ptr: png_ptr, info_ptr: info_ptr, header: header,
            assumesLinearInput: assumesLinearInput, background: background, buffer: buffer,
            rowStride: row_stride
        )
    }

    // Discarding colour is ordinary averaging — png_set_rgb_to_gray, the same call every other
    // caller of this library reaches for.  Kept alongside coverage the file already has and at
    // eight bits, that is all it is: nothing is being composited away or premultiplied, so the
    // double gamma correction the reference works around below has nothing to trip over — this
    // combination reaches the ordinary request below rather than being refused.
    if !format.hasColor, (header.colorType.hasColor || header.colorType.isIndexed), fileHasAlpha,
        !format.hasAlpha, !format.isLinear {
        swift_c_error(png_ptr, "png_image: discarding colour and alpha together not implemented")
    }

    // Sixteen bits is not the same as the eight bit cases above, kept or removed: there the
    // alpha-mode step premultiplies unconditionally once the file has coverage, whether or not the
    // channel survives to the output, and premultiplying is exactly the operation rgb-to-gray
    // cannot share a pass with — the reference works around this the same way it works around
    // discarding colour and coverage together at eight bits, by leaving the library's own
    // premultiply out of the pipeline and doing it once rgb-to-gray has already run.  There is no
    // background to ask for either way: sixteen bit output holds light, and light with no coverage
    // at all is black, not a colour a client gets to pick.
    if !format.hasColor, (header.colorType.hasColor || header.colorType.isIndexed), fileHasAlpha,
        format.isLinear {
        let assumesLinearInput = header.bitDepth == 16
            && image.pointee.flags & png_uint_32(PNG_IMAGE_FLAG_16BIT_sRGB) == 0

        return readColorReducedPremultiplied(
            image: image, png_ptr: png_ptr, info_ptr: info_ptr, header: header, format: format,
            assumesLinearInput: assumesLinearInput, buffer: buffer, rowStride: row_stride
        )
    }

    // What a file with no gAMA of its own is assumed to have been encoded with.  A sixteen bit file
    // is taken to hold light already, unless the client said otherwise through the flag the API
    // provides for exactly this; everything else is taken to be encoded for the usual display.
    let assumesLinearInput = header.bitDepth == 16
        && image.pointee.flags & png_uint_32(PNG_IMAGE_FLAG_16BIT_sRGB) == 0

    let passes = requestConversion(
        png_ptr,
        info_ptr,
        from: header,
        to: format,
        assumesLinearInput: assumesLinearInput,
        background: background
    )

    // The client may space its rows further apart than the pixels need, and may lay the image out
    // bottom-up by giving a negative stride.  Both are its business; what matters here is that every
    // row goes where it said.
    let minimum = Int(image.pointee.width) * format.channels * format.bytesPerChannel
    let stride = row_stride == 0 ? minimum : Int(row_stride) * format.bytesPerChannel
    let height = Int(image.pointee.height)

    guard abs(stride) >= minimum else {
        swift_c_error(png_ptr, "png_image: row stride too small")
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
    assumesLinearInput: Bool,
    background: png_const_colorp?
) -> Int {
    // Everything starts by becoming samples: an indexed row is indices, a transparent colour is not a
    // channel, and anything below eight bits is not a byte.
    png_set_expand(png_ptr)

    let fileHasAlpha = header.colorType.hasAlpha
        || (info_ptr.flatMap { InfoStore.from($0)?.isValid(PNG_INFO_tRNS) } ?? false)

    // Two calls, and the first is only about the *input*.
    //
    // What this call sets that the second cannot is the gamma the file is assumed to have been
    // encoded with when the file itself does not say — and only the first such call sets it, since a
    // file that carries its own gAMA is believed over any default.  So the assumption has to be
    // stated before the output is asked for, or the output request's own gamma becomes the input
    // assumption too, and every sample is then corrected by the wrong curve.  That is a whole-image
    // error rather than a low-bit one, which is what makes leaving it out obvious rather than subtle.
    png_set_alpha_mode_fixed(
        png_ptr,
        PNG_ALPHA_PNG,
        assumesLinearInput ? png_fixed_point(PNG_FP_1) : png_fixed_point(PNG_DEFAULT_sRGB)
    )

    // Now the depth and arrangement the client asked for.  Sixteen bit output is linear light, eight
    // bit output is encoded for a display, and this is where that is settled — the conversion between
    // them is the gamma machinery's, not a matter of moving bits.
    if format.isLinear {
        png_set_expand_16(png_ptr)

        // Associated (premultiplied) alpha when the file carries any coverage, matching the
        // reference's own choice: the colour channels come out already composited against black,
        // which is what makes a plain strip below — rather than a compose — the way to drop the
        // channel.  A file with no coverage has nothing to premultiply against.
        png_set_alpha_mode_fixed(
            png_ptr,
            fileHasAlpha ? PNG_ALPHA_STANDARD : PNG_ALPHA_PNG,
            png_fixed_point(PNG_FP_1)
        )
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

    if !format.hasAlpha, fileHasAlpha, format.isLinear {
        // The alpha-mode request above already composited the colour against black as part of
        // premultiplying it; the channel itself is all that is left to remove.
        png_set_strip_alpha(png_ptr)
    } else if !format.hasAlpha, fileHasAlpha, let background {
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

/// Takes an eight bit sample, scaled to sixteen bits, to sixteen bit linear light — the reference's
/// own `png_gamma_16bit_correct`, called here rather than looked up.
///
/// The two endpoints are fixed points of any gamma curve and are returned unchanged rather than
/// computed, which is the reference's own reasoning: it costs nothing, and it removes any question
/// of the arithmetic rounding them off the ends.
private func gamma16BitCorrect(_ value: UInt32, exponent: Double) -> UInt16 {
    guard value > 0, value < 65535 else { return UInt16(value) }

    let corrected = (65535 * pow(Double(value) / 65535, exponent) + 0.5).rounded(.down)

    return UInt16(corrected)
}

/// Reads an opaque greyscale file into a greyscale colour map: the narrowest slice of the
/// convenience API's colour-mapped output, and the one built first because it needs no compositing
/// and no cube — only, for a file whose `gAMA` names something other than sRGB or linear, a gamma
/// correction.
///
/// That correction turns out not to need the coarse, per-file table recorded as unavailable in
/// Conformance/known-transform-differences.txt.  That table belongs to the *ordinary* read
/// pipeline, which precomputes it once and looks every sample up so that a whole image is not one
/// call to `pow` per sample; the reference's simplified reader is not on that path; its own
/// `png_gamma_16bit_correct` calls `pow` directly, once per colour-map entry rather than once per
/// pixel — at most 256 calls, however large the image — so computing it exactly here matches the
/// reference exactly rather than approximating it.
///
/// Two cases fall out of what a file's gamma names:
///
/// - Close enough to sRGB (which is the assumption for a file with no `gAMA` chunk, and holds for
///   most that do have one too): the map's entries are what the display wants already, so entry `i`
///   is `i` scaled by the step between entries — nothing is corrected, because there is nothing to.
/// - Anything else, including exactly linear: a real correction, computed to the same precision the
///   reference's own `pow` call reaches.
/// What a file's gamma implies about correcting an eight bit encoded sample of its own into an
/// sRGB colour-map entry — worked out once per file rather than once per sample, since it depends
/// on nothing but the file's own `gAMA` chunk.
///
/// Two independent questions, not one, and it matters that they are asked in this order.  The
/// first is whether the file's gamma is worth correcting for at all — close enough to one (linear)
/// that it is not.  Only if it *is* worth correcting does the second question, whether it is close
/// enough to sRGB to already be what the map needs, get asked; a file whose gamma is near enough to
/// linear to skip the first test is never checked against sRGB at all, however far from it that
/// gamma happens to be.
private struct FileGammaCorrection {
    let isLinear: Bool
    let isSRGB: Bool
    let toLinearExponent: Double

    init(fileGamma: FixedPoint) {
        // The same fixed-point scale and the same threshold the engine's own gamma machinery uses
        // (Transforms/Gamma.swift), duplicated rather than exposed: PNG's opaque gamma value, not
        // a detail PNGCore should have any reason to share with the C boundary.
        let one: FixedPoint = 100_000
        let significanceThreshold: FixedPoint = 5_000

        func isSignificant(_ gamma: FixedPoint) -> Bool {
            gamma < one - significanceThreshold || gamma > one + significanceThreshold
        }

        self.isLinear = !isSignificant(fileGamma)

        // The reference's own test (png_gamma_not_sRGB): scale the file gamma up by the display
        // gamma sRGB assumes, 2.2, and ask whether *that* differs enough from one to matter —
        // sRGB's own encoding gamma is the one value where the two are reciprocals and the product
        // is one.
        let scaledForDisplay = FixedPoint((Int64(fileGamma) * 11 + 2) / 5)
        self.isSRGB = !self.isLinear && !isSignificant(scaledForDisplay)

        // The reciprocal of the file's own gamma, as an exponent: what takes an encoded sample to
        // linear light.  Rounded to the fixed-point scale first and only then divided back down to
        // a Double, matching the reference's own two-step rounding (png_reciprocal then
        // png_gamma_16bit_correct) — computing the reciprocal directly at full Double precision
        // looks like the same thing and is not: it lands close enough that only entries near a
        // rounding boundary move, but a few of every 256 do.  Only valid, and only needed, for a
        // gamma that is neither of the above — never evaluated otherwise, since 1/0 is not a
        // fraction.
        self.toLinearExponent = (1e10 / Double(fileGamma) + 0.5).rounded(.down) * 1e-5
    }

    /// Corrects one eight bit sample, already scaled to the map's own step between entries.
    func correct(_ value: UInt32) -> UInt8 {
        if self.isSRGB {
            // Already what the map needs: nothing to correct.
            return UInt8(value)
        } else if self.isLinear {
            // Already light, just not at sixteen bits yet — an exact scale, not a curve, and then
            // the ordinary encode to sRGB.
            return sRGBFromLinear(value &* 257 &* 255)
        } else {
            // A real correction: to sixteen bit linear light first, exactly as the reference's own
            // two-step path does, and only then to the sRGB byte the map holds — collapsing the
            // two would not give the same rounding.
            let linear = gamma16BitCorrect(value &* 257, exponent: self.toLinearExponent)

            return sRGBFromLinear(UInt32(linear) &* 255)
        }
    }

    /// Decodes one eight bit sample to sixteen bit linear light, the step `correct(_:)` folds into
    /// one byte for the common case of an opaque entry.  Compositing needs the light itself rather
    /// than the byte it eventually rounds to, since blending is only meaningful there — so this is
    /// the same three-way correction, stopped one step short.
    func toLinear16(_ value: UInt32) -> UInt32 {
        if self.isSRGB {
            return UInt32(sRGBToLinear(UInt8(value)))
        } else if self.isLinear {
            return value &* 257
        } else {
            return UInt32(gamma16BitCorrect(value &* 257, exponent: self.toLinearExponent))
        }
    }
}

private func readGrayColormap(
    image: png_imagep,
    png_ptr: png_structrp,
    info_ptr: png_inforp,
    info: InfoStore,
    header: Header,
    background: png_const_colorp?,
    buffer: UnsafeMutableRawPointer,
    rowStride: png_int_32,
    colormap: UnsafeMutableRawPointer?
) -> Int32 {
    guard let colormap else {
        swift_c_error(png_ptr, "png_image: no color-map for color-mapped image")
    }

    let format = SimplifiedFormat(raw: image.pointee.format)
    let fileGamma: FixedPoint = info.isValid(PNG_INFO_gAMA) ? info.gamma : 45455 // PNG_GAMMA_sRGB_INVERSE
    let correction = FileGammaCorrection(fileGamma: fileGamma)

    // A single grey value the file names as never opaque, not a channel of coverage varying pixel
    // to pixel — so whether it is one sample among 256 or the one index a whole run of them share,
    // there is exactly one map entry to treat differently, and the rows underneath never change:
    // a sample either is that value or it isn't, nothing here is ever partly covered.
    let transparentIndex = info.isValid(PNG_INFO_tRNS) ? Int(info.transparentColor.gray) : nil

    // Colour reaching this function has already been averaged away, or is about to be — see the
    // caller and the flag passed below — so the map is a plain grey ramp either way, and needs
    // building only the once.
    let entries = 1 << header.bitDepth
    let step = 255 / (entries - 1)
    let channels = format.channels
    let map = colormap.assumingMemoryBound(to: UInt8.self)

    for i in 0 ..< entries {
        let base = i * channels

        if i == transparentIndex {
            // Kept in the output, coverage needs no colour at all to be meaningful, so the
            // reference does not ask the client for one here: white, the same default it falls
            // back to everywhere a colour is wanted but none is required.  Removed, a colour is
            // required — there is no row-by-row buffer for a fixed map to fall back on, the same
            // rule the indexed case follows.
            guard format.hasAlpha || background != nil else {
                swift_c_error(png_ptr, "background color must be supplied to remove alpha/transparency")
            }

            // A background only matters once the client is asking for one to stand in for the
            // coverage it is losing; kept in the output, coverage needs no colour to be
            // meaningful, so a named background is not even consulted here — same as the
            // reference, which never reads it in this branch either.
            let colour = format.hasAlpha
                ? (255, 255, 255)
                : background.map { (UInt8($0.pointee.red), UInt8($0.pointee.green), UInt8($0.pointee.blue)) }!

            if format.hasColor {
                map[base] = colour.0
                map[base + 1] = colour.1
                map[base + 2] = colour.2
            } else {
                map[base] = colour.1
            }

            if format.hasAlpha {
                map[base + channels - 1] = 0
            }

            continue
        }

        let corrected = correction.correct(UInt32(i * step))

        // A grey value asked back as colour is the same value repeated across every channel —
        // there is only one light level here for red, green and blue to agree on.
        if format.hasColor {
            map[base] = corrected
            map[base + 1] = corrected
            map[base + 2] = corrected
        } else {
            map[base] = corrected
        }

        // Opaque: every entry but the one transparent value above, so every entry that asked for
        // an alpha channel gets full alpha here.
        if format.hasAlpha {
            map[base + channels - 1] = 255
        }
    }

    image.pointee.colormap_entries = png_uint_32(entries)

    return readIndexRows(
        image: image, png_ptr: png_ptr, info_ptr: info_ptr, header: header,
        buffer: buffer, rowStride: rowStride
    )
}

/// Reads an opaque RGB source into a plain grey colour map, discarding its colour.  Unlike the
/// grey-source case above, the map is not a correction of the raw file bytes: the file's samples
/// never reach the row as themselves, only as the result of averaging three of them together, and
/// that averaging already has to go through the gamma machinery to be correct — decode each to
/// light, average there, and re-encode — which is exactly what `png_set_rgb_to_gray` does. So the
/// row byte that comes out is already the client's answer in its own encoding, and the map is the
/// identity, the same way the reference's `make_gray_colormap` builds it: 256 entries of `i, i, i`.
private func readColorReducedGrayColormap(
    image: png_imagep,
    png_ptr: png_structrp,
    info_ptr: png_inforp,
    header: Header,
    buffer: UnsafeMutableRawPointer,
    rowStride: png_int_32,
    colormap: UnsafeMutableRawPointer?
) -> Int32 {
    guard let colormap else {
        swift_c_error(png_ptr, "png_image: no color-map for color-mapped image")
    }

    let format = SimplifiedFormat(raw: image.pointee.format)
    let channels = format.channels
    let map = colormap.assumingMemoryBound(to: UInt8.self)

    for i in 0 ..< 256 {
        let base = i * channels
        let value = UInt8(i)

        if format.hasColor {
            map[base] = value
            map[base + 1] = value
            map[base + 2] = value
        } else {
            map[base] = value
        }

        if format.hasAlpha {
            map[base + channels - 1] = 255
        }
    }

    image.pointee.colormap_entries = 256

    // What a file with no gAMA of its own is assumed to have been encoded with — the same default
    // requestConversion seeds for the ordinary reader, needed here for the same reason: rgb-to-gray's
    // decode step has to know what curve the samples it is decoding are in.
    let assumesLinearInput = header.bitDepth == 16
        && image.pointee.flags & png_uint_32(PNG_IMAGE_FLAG_16BIT_sRGB) == 0

    png_set_alpha_mode_fixed(
        png_ptr,
        PNG_ALPHA_PNG,
        assumesLinearInput ? png_fixed_point(PNG_FP_1) : png_fixed_point(PNG_DEFAULT_sRGB)
    )
    png_set_expand(png_ptr)
    png_set_rgb_to_gray(png_ptr, PNG_ERROR_ACTION_NONE, -1, -1)

    return readIndexRows(
        image: image, png_ptr: png_ptr, info_ptr: info_ptr, header: header,
        buffer: buffer, rowStride: rowStride
    )
}

/// Reads an indexed file into a colour map of its own — literally its palette, corrected for
/// gamma and, where the file's own tRNS table says an entry is not fully opaque, for coverage
/// too.  The narrowest of the colour-mapped cases, because a file that is already colour-mapped
/// needs no quantizing at all: its samples already are the indices a client wants, unchanged,
/// into a map that is a one-to-one correction of the one it already had.
///
/// Every entry, not the file's whole palette: a palette may hold more entries than any row
/// actually names, but the reference corrects and hands back every one up to two hundred and
/// fifty six regardless, and a client comparing the two colour maps directly would see the
/// difference if this stopped short.
private func readPaletteColormap(
    image: png_imagep,
    png_ptr: png_structrp,
    info_ptr: png_inforp,
    info: InfoStore,
    header: Header,
    background: png_const_colorp?,
    buffer: UnsafeMutableRawPointer,
    rowStride: png_int_32,
    colormap: UnsafeMutableRawPointer?
) -> Int32 {
    guard let colormap else {
        swift_c_error(png_ptr, "png_image: no color-map for color-mapped image")
    }

    let format = SimplifiedFormat(raw: image.pointee.format)
    let fileGamma: FixedPoint = info.isValid(PNG_INFO_gAMA) ? info.gamma : 45455 // PNG_GAMMA_sRGB_INVERSE
    let correction = FileGammaCorrection(fileGamma: fileGamma)

    let entries = min(info.palette.count, 256)
    let channels = format.channels
    let map = colormap.assumingMemoryBound(to: UInt8.self)

    // Blue and red swap places for a client that asked for BGR, the same as the colour cube.
    let redOffset = format.isReversed ? 2 : 0
    let blueOffset = format.isReversed ? 0 : 2

    let trans = info.transparentAlpha.elements
    let transCount = info.transparentCount
    let backgroundRGB = background.map {
        (r: UInt8($0.pointee.red), g: UInt8($0.pointee.green), b: UInt8($0.pointee.blue))
    }

    // One sample composited against a named background, in the light the file's own gamma
    // decodes it to rather than in the encoded bytes — the same rule readComposite and
    // readColorReducedComposite follow, reached here through the palette instead of a row.
    func blend(_ sample: UInt8, alpha: UInt8, against backgroundByte: UInt8) -> UInt8 {
        let fileLight = correction.toLinear16(UInt32(sample)) &* UInt32(alpha)
        let backgroundLight = UInt32(sRGBToLinear(backgroundByte)) &* UInt32(255 - alpha)

        return sRGBFromLinear(fileLight &+ backgroundLight)
    }

    for i in 0 ..< entries {
        let source = info.palette.elements[i]
        let base = i * channels
        let alpha: UInt8 = i < transCount ? trans[i] : 255

        if format.hasAlpha {
            // Coverage kept rather than removed: the file's own alpha for this entry travels
            // with its corrected colour, unchanged, the same as an opaque entry's constant 255
            // below — nothing here is composited away.
            map[base + redOffset] = correction.correct(UInt32(source.red))
            map[base + 1] = correction.correct(UInt32(source.green))
            map[base + blueOffset] = correction.correct(UInt32(source.blue))
            map[base + channels - 1] = alpha
        } else if alpha == 0, let backgroundRGB {
            // Wholly transparent: nothing of the file's own colour survives, so the entry is the
            // background outright rather than a blend of it with anything.
            map[base + redOffset] = backgroundRGB.r
            map[base + 1] = backgroundRGB.g
            map[base + blueOffset] = backgroundRGB.b
        } else if alpha < 255, let backgroundRGB {
            map[base + redOffset] = blend(source.red, alpha: alpha, against: backgroundRGB.r)
            map[base + 1] = blend(source.green, alpha: alpha, against: backgroundRGB.g)
            map[base + blueOffset] = blend(source.blue, alpha: alpha, against: backgroundRGB.b)
        } else {
            map[base + redOffset] = correction.correct(UInt32(source.red))
            map[base + 1] = correction.correct(UInt32(source.green))
            map[base + blueOffset] = correction.correct(UInt32(source.blue))
        }
    }

    image.pointee.colormap_entries = png_uint_32(entries)

    return readIndexRows(
        image: image, png_ptr: png_ptr, info_ptr: info_ptr, header: header,
        buffer: buffer, rowStride: rowStride
    )
}

/// Reads a file whose own bytes already are the colour-map index a client wants — a plain
/// greyscale or an indexed source, where nothing about the pixel data itself needs to change,
/// only the map it points into.  Packs sub-byte samples into whole bytes if the file's own depth
/// is narrower than that, since a client of this API is given index bytes to use, not bits to
/// unpack itself; does nothing else, because there is nothing else — every correction the map
/// needed happened when it was built, not here.
private func readIndexRows(
    image: png_imagep,
    png_ptr: png_structrp,
    info_ptr: png_inforp,
    header: Header,
    buffer: UnsafeMutableRawPointer,
    rowStride: png_int_32
) -> Int32 {
    if header.bitDepth < 8 {
        png_set_packing(png_ptr)
    }

    png_read_update_info(png_ptr, info_ptr)

    let width = Int(image.pointee.width)
    let height = Int(image.pointee.height)
    let stride = rowStride == 0 ? width : Int(rowStride)

    guard abs(stride) >= width else {
        swift_c_error(png_ptr, "png_image: row stride too small")
    }

    let first = stride < 0
        ? buffer.advanced(by: -stride * (height - 1))
        : buffer

    let passes = png_set_interlace_handling(png_ptr)

    for _ in 0 ..< passes {
        for row in 0 ..< height {
            let destination = first.advanced(by: stride * row).assumingMemoryBound(to: UInt8.self)

            png_read_row(png_ptr, destination, nil)
        }
    }

    png_read_end(png_ptr, nil)

    return 1
}

/// Reads a file with coverage of its own, into a client's own buffer, removing that coverage by
/// blending each pixel into whatever the buffer already held there rather than a colour the client
/// named — which is what asking for no colour at all, while the file has some, means.
///
/// The reference's own arrangement for this (`PNG_ALPHA_OPTIMIZED`) is already the engine's: an
/// opaque pixel is corrected as it always is, a wholly transparent one is left alone rather than
/// blended into nothing, and a partly covered one comes back as light rather than as an encoded
/// sample, still at eight bits — not sixteen, since compositing an eight bit value against another
/// only ever needs the precision the two of them have. The reference calls this a linear eight bit
/// value, which sounds grander than it is: it is a blend of two encoded bytes, weighted by
/// coverage, that has not been put back through the display's curve yet — that step happens once,
/// below, after the buffer's own byte is folded in, rather than twice.
private func readComposite(
    image: png_imagep,
    png_ptr: png_structrp,
    info_ptr: png_inforp,
    header: Header,
    format: SimplifiedFormat,
    assumesLinearInput: Bool,
    buffer: UnsafeMutableRawPointer,
    rowStride: png_int_32
) -> Int32 {
    png_set_expand(png_ptr)

    // The two-call sequence the ordinary reader also needs (see requestConversion): the first call
    // seeds the gamma a file with no gAMA of its own is assumed to have been encoded with, and only
    // the first such call sets it — the second, real request would otherwise become the assumption
    // too.  A sixteen bit source defaults to being assumed already linear; getting this wrong for
    // one is not a low-bit difference, it is every sample corrected by the wrong curve.
    png_set_alpha_mode_fixed(
        png_ptr, PNG_ALPHA_PNG,
        assumesLinearInput ? png_fixed_point(PNG_FP_1) : png_fixed_point(PNG_DEFAULT_sRGB)
    )
    png_set_alpha_mode_fixed(png_ptr, PNG_ALPHA_OPTIMIZED, png_fixed_point(PNG_DEFAULT_sRGB))
    png_set_scale_16(png_ptr)

    // Colour reduced to grey or the reverse is a separate, still-refused case (see the caller); the
    // shape asked for always matches the file's own here.
    if format.isReversed {
        png_set_bgr(png_ptr)
    }

    png_read_update_info(png_ptr, info_ptr)

    let width = Int(image.pointee.width)
    let height = Int(image.pointee.height)
    let colorChannels = format.hasColor ? 3 : 1
    let channels = colorChannels + 1
    let stride = rowStride == 0 ? width * colorChannels : Int(rowStride) * colorChannels

    guard abs(stride) >= width * colorChannels else {
        swift_c_error(png_ptr, "png_image: row stride too small")
    }

    let first = stride < 0
        ? buffer.advanced(by: -stride * (height - 1))
        : buffer

    let passes = png_set_interlace_handling(png_ptr)

    // The whole file's own colour-plus-coverage samples, not one row: an interlaced pass only
    // touches a scattered subset of an image's pixels, and png_read_row is what knows which —
    // composing straight into the client's buffer as each pass arrives would recompute every
    // pixel's blend on every pass, including the ones that pass never touched (see the same
    // reasoning, and the bug it once was, in readRGBColormap).
    let raw = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: width * height * channels)
    defer { raw.deallocate() }

    for _ in 0 ..< passes {
        for y in 0 ..< height {
            png_read_row(png_ptr, raw.baseAddress! + y * width * channels, nil)
        }
    }

    for y in 0 ..< height {
        let destination = first.advanced(by: stride * y).assumingMemoryBound(to: UInt8.self)
        let sourceRow = y * width * channels

        for x in 0 ..< width {
            let alpha = raw[sourceRow + x * channels + colorChannels]

            // Wholly transparent: nothing of the file's pixel survives to blend in, so the
            // buffer's own byte is already the answer and is left untouched.
            guard alpha > 0 else { continue }

            for c in 0 ..< colorChannels {
                let index = x * colorChannels + c
                let component = raw[sourceRow + x * channels + c]

                if alpha == 255 {
                    // Already corrected, the same as any other opaque pixel: nothing left to
                    // blend against.
                    destination[index] = component
                } else {
                    // The file's own light, scaled to the table's domain, plus what survives of
                    // the buffer's own byte — decoded to light first, since blending encoded
                    // bytes is not the same operation and does not agree with the reference.
                    let fileLight = UInt32(component) &* 65535
                    let bufferLight = UInt32(255 - alpha) &* UInt32(sRGBToLinear(destination[index]))
                    let blended = min(fileLight &+ bufferLight, 255 &* 65535)

                    destination[index] = sRGBFromLinear(blended)
                }
            }
        }
    }

    png_read_end(png_ptr, nil)

    return 1
}

/// Reads a file with coverage of its own and colour it will not keep, removing both at once by
/// averaging colour to grey and then blending that grey against a background — named, or the
/// client's own buffer when none is.  Kept apart from readComposite because the reference itself
/// keeps them apart: running its rgb-to-gray transform and its compositing in the same pass double
/// corrects for gamma, a bug it works around by doing the blend itself once rgb-to-gray has already
/// run rather than asking the library to do both — which is what this does too, in the same order.
private func readColorReducedComposite(
    image: png_imagep,
    png_ptr: png_structrp,
    info_ptr: png_inforp,
    header: Header,
    assumesLinearInput: Bool,
    background: png_const_colorp?,
    buffer: UnsafeMutableRawPointer,
    rowStride: png_int_32
) -> Int32 {
    png_set_expand(png_ptr)
    png_set_rgb_to_gray(png_ptr, PNG_ERROR_ACTION_NONE, -1, -1)

    // The two-call sequence readComposite also needs, and for the same reason: the first states
    // what a file with no gAMA of its own is assumed to have been encoded with, and only the first
    // such call sets it.  The second asks for the output gamma alone — PNG_ALPHA_PNG rather than
    // OPTIMIZED, since the blend itself happens below rather than in the library, which is the
    // whole point of being here instead of in requestConversion.
    png_set_alpha_mode_fixed(
        png_ptr, PNG_ALPHA_PNG,
        assumesLinearInput ? png_fixed_point(PNG_FP_1) : png_fixed_point(PNG_DEFAULT_sRGB)
    )
    png_set_alpha_mode_fixed(png_ptr, PNG_ALPHA_PNG, png_fixed_point(PNG_DEFAULT_sRGB))

    // The output here is always eight bits — see the caller — but the source may not be; narrowing
    // is the gamma machinery's job, the same as everywhere else it happens, not a matter of moving
    // bytes.
    png_set_scale_16(png_ptr)

    png_read_update_info(png_ptr, info_ptr)

    let width = Int(image.pointee.width)
    let height = Int(image.pointee.height)
    let stride = rowStride == 0 ? width : Int(rowStride)

    guard abs(stride) >= width else {
        swift_c_error(png_ptr, "png_image: row stride too small")
    }

    let first = stride < 0
        ? buffer.advanced(by: -stride * (height - 1))
        : buffer

    let passes = png_set_interlace_handling(png_ptr)
    let channels = 2 // grey, alpha

    // The whole file, not one row: an interlaced pass only touches a scattered subset of an
    // image's pixels — see the same reasoning in readComposite.
    let raw = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: width * height * channels)
    defer { raw.deallocate() }

    for _ in 0 ..< passes {
        for y in 0 ..< height {
            png_read_row(png_ptr, raw.baseAddress! + y * width * channels, nil)
        }
    }

    // Named in the sRGB the API speaks, at the depth the blend happens at — which is eight bits,
    // since a source with more never reaches here.  Grey output takes the green channel, the API's
    // own rule: green is most of what a viewer sees as brightness.
    let backgroundByte = background.map { UInt8($0.pointee.green) }
    let backgroundLight = backgroundByte.map { UInt32(sRGBToLinear($0)) }

    for y in 0 ..< height {
        let destination = first.advanced(by: stride * y).assumingMemoryBound(to: UInt8.self)
        let sourceRow = y * width * channels

        for x in 0 ..< width {
            let component = raw[sourceRow + x * channels]
            let alpha = raw[sourceRow + x * channels + 1]

            if alpha == 255 {
                // Already corrected, the same as any other opaque pixel: nothing left to blend
                // against.
                destination[x] = component
            } else if alpha == 0 {
                if let backgroundByte {
                    destination[x] = backgroundByte
                }
                // Else wholly transparent with nothing named to replace it: the buffer's own byte
                // is already the answer and is left untouched, the same rule readComposite follows.
            } else {
                // The file's own light, decoded first since blending encoded bytes is not the same
                // operation, plus what survives of whichever base — named or the buffer's own byte
                // — is being blended against.
                let fileLight = UInt32(sRGBToLinear(component)) &* UInt32(alpha)
                let baseLight = backgroundLight ?? UInt32(sRGBToLinear(destination[x]))
                let blended = fileLight &+ baseLight &* UInt32(255 - alpha)

                destination[x] = sRGBFromLinear(blended)
            }
        }
    }

    png_read_end(png_ptr, nil)

    return 1
}

/// Reads a file with coverage of its own and colour it will not keep, into a sixteen bit result.
/// Sixteen bits is not the eight bit case above with a wider sample: there the alpha-mode step
/// premultiplies unconditionally once the file has coverage, whether or not the channel survives
/// to the output, and premultiplying is exactly the operation rgb-to-gray cannot share a pass with
/// — the same double gamma correction bug that discarding colour at eight bits works around by
/// compositing separately.  The reference works around this one the same way it works around that
/// one: by leaving the library's own premultiply out of the pipeline entirely and doing it here,
/// once rgb-to-gray has already produced plain, unmultiplied grey-plus-alpha rows.  There is
/// nothing to name a background for — sixteen bit output holds light, and light with no coverage
/// at all is black, not a colour a client gets to pick.
private func readColorReducedPremultiplied(
    image: png_imagep,
    png_ptr: png_structrp,
    info_ptr: png_inforp,
    header: Header,
    format: SimplifiedFormat,
    assumesLinearInput: Bool,
    buffer: UnsafeMutableRawPointer,
    rowStride: png_int_32
) -> Int32 {
    png_set_expand(png_ptr)
    png_set_rgb_to_gray(png_ptr, PNG_ERROR_ACTION_NONE, -1, -1)

    // The two-call sequence every other coverage-aware reader here needs, and for the same reason:
    // the first states what a file with no gAMA of its own is assumed to have been encoded with.
    // The second asks for sixteen bit linear output and PNG_ALPHA_PNG rather than STANDARD — the
    // premultiply happens below instead, which is the whole point of being here.
    png_set_alpha_mode_fixed(
        png_ptr, PNG_ALPHA_PNG,
        assumesLinearInput ? png_fixed_point(PNG_FP_1) : png_fixed_point(PNG_DEFAULT_sRGB)
    )
    png_set_alpha_mode_fixed(png_ptr, PNG_ALPHA_PNG, png_fixed_point(PNG_FP_1))
    png_set_expand_16(png_ptr)

    if SimplifiedFormat.isLittleEndian {
        png_set_swap(png_ptr)
    }

    png_read_update_info(png_ptr, info_ptr)

    let width = Int(image.pointee.width)
    let height = Int(image.pointee.height)
    let outputChannels = format.hasAlpha ? 2 : 1
    let minimum = width * outputChannels * 2
    let stride = rowStride == 0 ? minimum : Int(rowStride) * 2

    guard abs(stride) >= minimum else {
        swift_c_error(png_ptr, "png_image: row stride too small")
    }

    let first = stride < 0
        ? buffer.advanced(by: -stride * (height - 1))
        : buffer

    let passes = png_set_interlace_handling(png_ptr)
    let sourceChannels = 2 // grey, alpha, from the file's own byte order once swapped above

    // The whole file, not one row: an interlaced pass only touches a scattered subset of an
    // image's pixels — see the same reasoning in readComposite.
    let raw = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: width * height * sourceChannels)
    defer { raw.deallocate() }

    raw.withMemoryRebound(to: UInt8.self) { bytes in
        for _ in 0 ..< passes {
            for y in 0 ..< height {
                png_read_row(png_ptr, bytes.baseAddress! + y * width * sourceChannels * 2, nil)
            }
        }
    }

    // Alpha first swaps the pair the same way it swaps a kept channel anywhere else, but the file
    // itself is never asked to reorder — there is nothing here for png_set_swap_alpha to reorder
    // before this function ever sees the row, so the placement is entirely this loop's business.
    let alphaFirst = format.hasAlpha && format.alphaFirst

    for y in 0 ..< height {
        let destination = first.advanced(by: stride * y).assumingMemoryBound(to: UInt16.self)
        let sourceRow = y * width * sourceChannels

        for x in 0 ..< width {
            let component = raw[sourceRow + x * sourceChannels]
            let alpha = raw[sourceRow + x * sourceChannels + 1]

            let premultiplied: UInt16

            if alpha == 0 {
                premultiplied = 0
            } else if alpha < 65535 {
                premultiplied = UInt16((UInt32(component) &* UInt32(alpha) &+ 32767) / 65535)
            } else {
                premultiplied = component
            }

            let base = x * outputChannels

            if format.hasAlpha {
                destination[base + (alphaFirst ? 1 : 0)] = premultiplied
                destination[base + (alphaFirst ? 0 : 1)] = alpha
            } else {
                destination[base] = premultiplied
            }
        }
    }

    png_read_end(png_ptr, nil)

    return 1
}

/// The one nearest-colour step every entry of the six-by-six-by-six colour cube shares: which of
/// its six levels a component is closest to, `0...5`.
///
/// The reference's own rounding (`PNG_DIV51`), not an obvious one: dividing by 51 and rounding
/// would put the boundary between two levels at the arithmetic midpoint of 51, which is not where
/// this puts it — `* 5 + 130) >> 8` is `/ 51.2` rounded, matching the levels' own spacing
/// (`0, 51, 102, 153, 204, 255` — four gaps of 51 and a fifth short one) rather than splitting 51
/// itself evenly.
private func div51(_ value: UInt8) -> UInt8 {
    UInt8((UInt32(value) &* 5 &+ 130) >> 8)
}

/// Reads a grey-plus-alpha file into a colour map graded by coverage rather than the file's own
/// bytes.  Two independent bytes cannot be a map index the way one channel can — every combination
/// of grey and alpha would need its own entry, sixty five thousand of them — so the reference
/// reduces to two hundred and thirty one graded levels of an opaque grey, one entry for the pixels
/// with no coverage at all, and twenty four more split six ways by grey and four ways by alpha for
/// the ones in between; which entry a pixel becomes is a classification into that layout, not a
/// correction of a byte already there, so the rows need their own pass the other colour-mapped
/// cases do not.
///
/// Kept or removed, that layout and the classification reaching it are identical — only what the
/// one entry and the twenty four settle into differs.  Coverage kept, colour was never asked for
/// even when the client wants it back, since every entry only ever repeats one grey level; the one
/// entry is wholly transparent and the twenty four hold the file's own grey raised to each of four
/// coarse alpha levels, unblended, since nothing has been composited yet.  Removed, colour is what
/// the client is asking for — a grey pixel blended against a background that is not itself a shade
/// of grey has a real colour, not a level of one — so the one entry becomes the background at full
/// precision and the twenty four become that same blend, done once per entry rather than once per
/// pixel.  Nothing else reaches this second half: a source keeping its alpha, or losing it against
/// a background that is grey (or an output that has nowhere to put colour anyway), settles it more
/// simply — see the two callers.
private func readGAColormap(
    image: png_imagep,
    png_ptr: png_structrp,
    info_ptr: png_inforp,
    header: Header,
    background: png_const_colorp?,
    buffer: UnsafeMutableRawPointer,
    rowStride: png_int_32,
    colormap: UnsafeMutableRawPointer?
) -> Int32 {
    guard let colormap else {
        swift_c_error(png_ptr, "png_image: no color-map for color-mapped image")
    }

    let format = SimplifiedFormat(raw: image.pointee.format)
    let channels = format.channels
    let map = colormap.assumingMemoryBound(to: UInt8.self)

    func writeEntry(_ index: Int, red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let base = index * channels

        if format.hasColor {
            map[base] = red
            map[base + 1] = green
            map[base + 2] = blue
        } else {
            map[base] = red
        }

        if format.hasAlpha {
            map[base + channels - 1] = alpha
        }
    }

    for i in 0 ..< 231 {
        let grey = UInt8((i * 256 + 115) / 231)
        writeEntry(i, red: grey, green: grey, blue: grey, alpha: 255)
    }

    if let background {
        // Removed against a background with real colour of its own: the background at full
        // precision stands in for a pixel with no coverage, and every graded level blends the
        // file's own light against it — decoded once per channel here, not once per pixel, since
        // there are only six grey levels and four alpha levels to ever ask for.
        let backgroundColour = (
            red: UInt8(background.pointee.red),
            green: UInt8(background.pointee.green),
            blue: UInt8(background.pointee.blue)
        )

        writeEntry(
            231, red: backgroundColour.red, green: backgroundColour.green,
            blue: backgroundColour.blue, alpha: 255
        )

        let backgroundLight = (
            red: UInt32(sRGBToLinear(backgroundColour.red)),
            green: UInt32(sRGBToLinear(backgroundColour.green)),
            blue: UInt32(sRGBToLinear(backgroundColour.blue))
        )

        func blend(_ grey: UInt8, alpha: UInt32, against backgroundLight: UInt32) -> UInt8 {
            let greyLight = UInt32(sRGBToLinear(grey)) &* alpha
            return sRGBFromLinear(greyLight &+ backgroundLight &* (255 &- alpha))
        }

        var index = 232
        for alphaLevel in 1 ..< 5 {
            let alpha = UInt32(alphaLevel * 51)

            for greyLevel in 0 ..< 6 {
                let grey = UInt8(greyLevel * 51)

                writeEntry(
                    index,
                    red: blend(grey, alpha: alpha, against: backgroundLight.red),
                    green: blend(grey, alpha: alpha, against: backgroundLight.green),
                    blue: blend(grey, alpha: alpha, against: backgroundLight.blue),
                    alpha: 255
                )
                index += 1
            }
        }
    } else {
        writeEntry(231, red: 255, green: 255, blue: 255, alpha: 0)

        var index = 232
        for alphaLevel in 1 ..< 5 {
            for greyLevel in 0 ..< 6 {
                let grey = UInt8(greyLevel * 51)
                writeEntry(index, red: grey, green: grey, blue: grey, alpha: UInt8(alphaLevel * 51))
                index += 1
            }
        }
    }

    image.pointee.colormap_entries = 256

    // Ordinary sRGB gamma correction and nothing else: no compositing happens on the way through,
    // so there is no double correction to work around here the way there is discarding colour —
    // the classification above is what turns coverage into an index, not a blend against anything.
    png_set_expand(png_ptr)

    let assumesLinearInput = header.bitDepth == 16
        && image.pointee.flags & png_uint_32(PNG_IMAGE_FLAG_16BIT_sRGB) == 0

    png_set_alpha_mode_fixed(
        png_ptr, PNG_ALPHA_PNG,
        assumesLinearInput ? png_fixed_point(PNG_FP_1) : png_fixed_point(PNG_DEFAULT_sRGB)
    )
    png_set_alpha_mode_fixed(png_ptr, PNG_ALPHA_PNG, png_fixed_point(PNG_DEFAULT_sRGB))
    png_set_scale_16(png_ptr)

    png_read_update_info(png_ptr, info_ptr)

    let width = Int(image.pointee.width)
    let height = Int(image.pointee.height)
    let stride = rowStride == 0 ? width : Int(rowStride)

    guard abs(stride) >= width else {
        swift_c_error(png_ptr, "png_image: row stride too small")
    }

    let first = stride < 0
        ? buffer.advanced(by: -stride * (height - 1))
        : buffer

    let passes = png_set_interlace_handling(png_ptr)

    // The whole file, not one row: an interlaced pass only touches a scattered subset of an
    // image's pixels — see the same reasoning in readComposite.
    let raw = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: width * height * 2)
    defer { raw.deallocate() }

    for _ in 0 ..< passes {
        for y in 0 ..< height {
            png_read_row(png_ptr, raw.baseAddress! + y * width * 2, nil)
        }
    }

    for y in 0 ..< height {
        let destination = first.advanced(by: stride * y).assumingMemoryBound(to: UInt8.self)
        let sourceRow = y * width * 2

        for x in 0 ..< width {
            let grey = raw[sourceRow + x * 2]
            let alpha = raw[sourceRow + x * 2 + 1]

            if alpha > 229 {
                destination[x] = UInt8((231 * Int(grey) + 128) >> 8)
            } else if alpha < 26 {
                destination[x] = 231
            } else {
                destination[x] = 226 &+ 6 &* div51(alpha) &+ div51(grey)
            }
        }
    }

    png_read_end(png_ptr, nil)

    return 1
}

/// Reads a grey-plus-alpha file into a colour map with its coverage already removed, blended
/// against a named background the library itself composites — a single fixed colour, not the
/// finer grading real coverage kept in the map would need, so the ordinary background-compositing
/// call already used for a source with no colour change at all does the whole job here too.  The
/// map is the identity: `png_set_background_fixed` leaves the row already in the sRGB the map
/// holds, the same reason `readColorReducedGrayColormap`'s map next door is.
private func readGrayAlphaComposedColormap(
    image: png_imagep,
    png_ptr: png_structrp,
    info_ptr: png_inforp,
    header: Header,
    background: png_const_colorp,
    buffer: UnsafeMutableRawPointer,
    rowStride: png_int_32,
    colormap: UnsafeMutableRawPointer?
) -> Int32 {
    guard let colormap else {
        swift_c_error(png_ptr, "png_image: no color-map for color-mapped image")
    }

    let format = SimplifiedFormat(raw: image.pointee.format)
    let channels = format.channels
    let map = colormap.assumingMemoryBound(to: UInt8.self)

    for i in 0 ..< 256 {
        let base = i * channels
        let value = UInt8(i)

        if format.hasColor {
            map[base] = value
            map[base + 1] = value
            map[base + 2] = value
        } else {
            map[base] = value
        }
    }

    image.pointee.colormap_entries = 256

    png_set_expand(png_ptr)

    let assumesLinearInput = header.bitDepth == 16
        && image.pointee.flags & png_uint_32(PNG_IMAGE_FLAG_16BIT_sRGB) == 0

    png_set_alpha_mode_fixed(
        png_ptr, PNG_ALPHA_PNG,
        assumesLinearInput ? png_fixed_point(PNG_FP_1) : png_fixed_point(PNG_DEFAULT_sRGB)
    )
    png_set_alpha_mode_fixed(png_ptr, PNG_ALPHA_PNG, png_fixed_point(PNG_DEFAULT_sRGB))
    png_set_scale_16(png_ptr)

    // Grey output takes the green channel, the API's own rule — green is most of what a viewer
    // sees as brightness, and it is what the map's own grey ramp is built in terms of either way.
    var colour = png_color_16()
    colour.red = png_uint_16(background.pointee.red)
    colour.green = png_uint_16(background.pointee.green)
    colour.blue = png_uint_16(background.pointee.blue)
    colour.gray = colour.green

    withUnsafePointer(to: &colour) {
        png_set_background_fixed(png_ptr, $0, PNG_BACKGROUND_GAMMA_SCREEN, 0, 0)
    }

    return readIndexRows(
        image: image, png_ptr: png_ptr, info_ptr: info_ptr, header: header,
        buffer: buffer, rowStride: rowStride
    )
}

/// Reads an opaque RGB or RGBA file into the reference's own fixed colour map: every combination
/// of six levels per channel, the same cube regardless of what the file holds, so that no analysis
/// of the image's own colours is needed — a client asking for this format is asking for a
/// reduction, not the best one findable, and the reference has one answer to what "this reduction"
/// means rather than as many as there are images.
///
/// Coverage is not handled here — see the caller — so this file's presence in `PNG_CMAP_RGB` also
/// says the file has none; the cube has no transparent entry to spare for it.
private func readRGBColormap(
    image: png_imagep,
    png_ptr: png_structrp,
    info_ptr: png_inforp,
    header: Header,
    buffer: UnsafeMutableRawPointer,
    rowStride: png_int_32,
    colormap: UnsafeMutableRawPointer?
) -> Int32 {
    guard let colormap else {
        swift_c_error(png_ptr, "png_image: no color-map for color-mapped image")
    }

    let format = SimplifiedFormat(raw: image.pointee.format)
    let entries = 216
    let map = colormap.assumingMemoryBound(to: UInt8.self)

    // Blue and red swap places for a client that asked for BGR; the cube's own indexing (below)
    // does not change, since that always works from the file's own component order regardless of
    // how a found entry's bytes are laid out.
    let redOffset = format.isReversed ? 2 : 0
    let blueOffset = format.isReversed ? 0 : 2

    for r in 0 ..< 6 {
        for g in 0 ..< 6 {
            for b in 0 ..< 6 {
                let entry = (r * 6 + g) * 6 + b
                let base = entry * 3

                map[base + redOffset] = UInt8(r * 51)
                map[base + 1] = UInt8(g * 51)
                map[base + blueOffset] = UInt8(b * 51)
            }
        }
    }

    image.pointee.colormap_entries = png_uint_32(entries)

    // Every source this handles becomes the same shape libpng hands the ordinary sRGB eight bit
    // reader: expand to samples, narrow sixteen bit ones, encode for sRGB.  There is no coverage
    // to add or remove and nothing to average, since the caller has already refused both.
    png_set_expand(png_ptr)
    png_set_scale_16(png_ptr)
    png_set_alpha_mode_fixed(png_ptr, PNG_ALPHA_PNG, png_fixed_point(PNG_DEFAULT_sRGB))

    png_read_update_info(png_ptr, info_ptr)

    return readRGBColormapRows(
        image: image, png_ptr: png_ptr, buffer: buffer, rowStride: rowStride
    )
}

/// Reads the opaque sRGB rows the cube's own index is a `div51` of — shared by the plain cube
/// above and by a source with real coverage of its own, once that coverage has already been
/// composited away by a named background that happened to land exactly on the cube's own grid,
/// which leaves this the same problem: opaque sRGB triples in, a `div51` classification out.
private func readRGBColormapRows(
    image: png_imagep,
    png_ptr: png_structrp,
    buffer: UnsafeMutableRawPointer,
    rowStride: png_int_32
) -> Int32 {
    let width = Int(image.pointee.width)
    let height = Int(image.pointee.height)
    let stride = rowStride == 0 ? width : Int(rowStride)

    guard abs(stride) >= width else {
        swift_c_error(png_ptr, "png_image: row stride too small")
    }

    let first = stride < 0
        ? buffer.advanced(by: -stride * (height - 1))
        : buffer

    let passes = png_set_interlace_handling(png_ptr)

    // The whole file's own sRGB triples, not one row: an interlaced pass only ever touches a
    // scattered subset of an image's pixels, and png_read_row is what knows which — it leaves
    // every pixel outside the current pass untouched in whatever buffer it is given, which is
    // what makes calling it once per row per pass build up the whole image correctly, the same
    // way the ordinary (non-colour-mapped) reader relies on when it hands the client's own row
    // buffer to every call. Converting straight to an index as each pass comes in, into a buffer
    // sized for one row rather than the whole image, would instead recompute every pixel's index
    // on every pass — including the ones that pass never touched, from whatever that row buffer
    // happened to hold last, which is not this image's data.
    let raw = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: width * height * 3)
    defer { raw.deallocate() }

    for _ in 0 ..< passes {
        for y in 0 ..< height {
            png_read_row(png_ptr, raw.baseAddress! + y * width * 3, nil)
        }
    }

    for y in 0 ..< height {
        let destination = first.advanced(by: stride * y).assumingMemoryBound(to: UInt8.self)
        let sourceRow = y * width * 3

        for x in 0 ..< width {
            let r = div51(raw[sourceRow + x * 3])
            let g = div51(raw[sourceRow + x * 3 + 1])
            let b = div51(raw[sourceRow + x * 3 + 2])

            destination[x] = (r * 6 + g) * 6 + b
        }
    }

    png_read_end(png_ptr, nil)

    return 1
}

/// Reads an RGB or RGBA source with real coverage of its own into the reference's cube, extended
/// with a hundred and twenty eight further entries a pixel's own alpha picks among rather than a
/// per-pixel blend, which is exactly the cost this coarse classification exists to avoid: one
/// wholly transparent (or, removed, the named background), and twenty seven graded by rounding
/// each channel to one of three levels — the top two bits, cheaply — for the pixels in between.
///
/// Kept or removed, that layout and the row-by-row classification reaching it are identical; only
/// what a removed pixel's coverage settles into differs, and only when a named background does not
/// already land exactly on the opaque cube's own grid does that difference need entries of its
/// own, rather than the ordinary background composite the plain opaque cube already uses.
private func readRGBAlphaColormap(
    image: png_imagep,
    png_ptr: png_structrp,
    info_ptr: png_inforp,
    header: Header,
    background: png_const_colorp?,
    buffer: UnsafeMutableRawPointer,
    rowStride: png_int_32,
    colormap: UnsafeMutableRawPointer?
) -> Int32 {
    guard let colormap else {
        swift_c_error(png_ptr, "png_image: no color-map for color-mapped image")
    }

    let format = SimplifiedFormat(raw: image.pointee.format)
    let map = colormap.assumingMemoryBound(to: UInt8.self)

    // Blue and red swap places for a client that asked for BGR, the same as the plain cube; the
    // rows this reads stay in the file's own order regardless, since the classification below
    // works from that order and only the map a found index points into need be reversed.
    let redOffset = format.isReversed ? 2 : 0
    let blueOffset = format.isReversed ? 0 : 2

    // Three channels, not four, once the output has nowhere to put an alpha at all — matching an
    // opaque cube's own entries, which are the ordinary three either way.
    let channels = format.channels

    func writeEntry(_ index: Int, red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let base = index * channels

        map[base + redOffset] = red
        map[base + 1] = green
        map[base + blueOffset] = blue

        if format.hasAlpha {
            map[base + 3] = alpha
        }
    }

    for r in 0 ..< 6 {
        for g in 0 ..< 6 {
            for b in 0 ..< 6 {
                writeEntry((r * 6 + g) * 6 + b, red: UInt8(r * 51), green: UInt8(g * 51),
                    blue: UInt8(b * 51), alpha: 255)
            }
        }
    }

    // A named background exactly on the cube's own grid composites no differently from an opaque
    // source: the ordinary background call already used for a plain cube leaves every pixel
    // already at one of the two hundred sixteen colours the ramp above holds, so no entry beyond
    // it, and no classification beyond `div51`, is ever needed. This is the one background value
    // the reference's own default happens to land on exactly: black.
    if !format.hasAlpha, let background {
        let backgroundColour = (
            red: UInt8(background.pointee.red),
            green: UInt8(background.pointee.green),
            blue: UInt8(background.pointee.blue)
        )
        let onGrid = div51(backgroundColour.red) &* 51 == backgroundColour.red
            && div51(backgroundColour.green) &* 51 == backgroundColour.green
            && div51(backgroundColour.blue) &* 51 == backgroundColour.blue

        if onGrid {
            image.pointee.colormap_entries = 216

            png_set_expand(png_ptr)

            let assumesLinearInput = header.bitDepth == 16
                && image.pointee.flags & png_uint_32(PNG_IMAGE_FLAG_16BIT_sRGB) == 0

            png_set_alpha_mode_fixed(
                png_ptr, PNG_ALPHA_PNG,
                assumesLinearInput ? png_fixed_point(PNG_FP_1) : png_fixed_point(PNG_DEFAULT_sRGB)
            )
            png_set_alpha_mode_fixed(png_ptr, PNG_ALPHA_PNG, png_fixed_point(PNG_DEFAULT_sRGB))
            png_set_scale_16(png_ptr)

            var colour = png_color_16()
            colour.red = png_uint_16(backgroundColour.red)
            colour.green = png_uint_16(backgroundColour.green)
            colour.blue = png_uint_16(backgroundColour.blue)
            colour.gray = colour.green

            withUnsafePointer(to: &colour) {
                png_set_background_fixed(png_ptr, $0, PNG_BACKGROUND_GAMMA_SCREEN, 0, 0)
            }

            png_read_update_info(png_ptr, info_ptr)

            return readRGBColormapRows(
                image: image, png_ptr: png_ptr, buffer: buffer, rowStride: rowStride
            )
        }
    }

    // The transparent or background entry, and the twenty seven a partly covered pixel rounds
    // into.  One decodes and re-encodes each channel at the fixed weight the reference's own
    // classification below assumes — half the file's own light, half whatever survives; the other
    // needs no such correction; it is already opaque, unused by anything but its own colour.
    func partial(_ component: UInt8, against backgroundComponent: UInt8) -> UInt8 {
        let fileLight = UInt32(sRGBToLinear(component)) &* 128
        let backgroundLight = UInt32(sRGBToLinear(backgroundComponent)) &* 127

        return sRGBFromLinear(fileLight &+ backgroundLight)
    }

    let backgroundIndex = 216

    if format.hasAlpha {
        writeEntry(backgroundIndex, red: 255, green: 255, blue: 255, alpha: 0)
    } else if let background {
        writeEntry(
            backgroundIndex, red: UInt8(background.pointee.red),
            green: UInt8(background.pointee.green), blue: UInt8(background.pointee.blue), alpha: 0
        )
    }

    var index = backgroundIndex + 1
    let levels: [UInt8] = [0, 127, 255]

    for r in levels {
        for g in levels {
            for b in levels {
                if format.hasAlpha {
                    writeEntry(index, red: r, green: g, blue: b, alpha: 128)
                } else if let background {
                    writeEntry(
                        index,
                        red: partial(r, against: UInt8(background.pointee.red)),
                        green: partial(g, against: UInt8(background.pointee.green)),
                        blue: partial(b, against: UInt8(background.pointee.blue)),
                        alpha: 0
                    )
                }

                index += 1
            }
        }
    }

    image.pointee.colormap_entries = png_uint_32(index)

    // No compositing in the pipeline here, kept or removed: the classification below is what
    // turns coverage into an index, the same reason readGAColormap needs none either — a
    // per-pixel blend is exactly what the coarse buckets above exist to avoid paying for.
    png_set_expand(png_ptr)

    let assumesLinearInput = header.bitDepth == 16
        && image.pointee.flags & png_uint_32(PNG_IMAGE_FLAG_16BIT_sRGB) == 0

    png_set_alpha_mode_fixed(
        png_ptr, PNG_ALPHA_PNG,
        assumesLinearInput ? png_fixed_point(PNG_FP_1) : png_fixed_point(PNG_DEFAULT_sRGB)
    )
    png_set_alpha_mode_fixed(png_ptr, PNG_ALPHA_PNG, png_fixed_point(PNG_DEFAULT_sRGB))
    png_set_scale_16(png_ptr)

    png_read_update_info(png_ptr, info_ptr)

    let width = Int(image.pointee.width)
    let height = Int(image.pointee.height)
    let stride = rowStride == 0 ? width : Int(rowStride)

    guard abs(stride) >= width else {
        swift_c_error(png_ptr, "png_image: row stride too small")
    }

    let first = stride < 0
        ? buffer.advanced(by: -stride * (height - 1))
        : buffer

    let passes = png_set_interlace_handling(png_ptr)

    // The whole file's own RGBA quadruples, not one row — the same reasoning as every other
    // colour-mapped case that reads more than an index at a time: an interlaced pass only ever
    // touches a scattered subset of an image's pixels.
    let raw = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: width * height * 4)
    defer { raw.deallocate() }

    for _ in 0 ..< passes {
        for y in 0 ..< height {
            png_read_row(png_ptr, raw.baseAddress! + y * width * 4, nil)
        }
    }

    for y in 0 ..< height {
        let destination = first.advanced(by: stride * y).assumingMemoryBound(to: UInt8.self)
        let sourceRow = y * width * 4

        for x in 0 ..< width {
            let r = raw[sourceRow + x * 4]
            let g = raw[sourceRow + x * 4 + 1]
            let b = raw[sourceRow + x * 4 + 2]
            let alpha = raw[sourceRow + x * 4 + 3]

            if alpha >= 196 {
                destination[x] = (div51(r) &* 6 &+ div51(g)) &* 6 &+ div51(b)
            } else if alpha < 64 {
                destination[x] = UInt8(backgroundIndex)
            } else {
                // Each channel rounds to whichever of its own top two bits are set — `00`, `01` or
                // `10`, and `11` — the same three levels `partial` above composed against, weighted
                // nine and three and one the way the reference's own bit tests are.
                var level = backgroundIndex + 1

                if r & 0x80 != 0 { level += 9 }
                if r & 0x40 != 0 { level += 9 }
                if g & 0x80 != 0 { level += 3 }
                if g & 0x40 != 0 { level += 3 }
                if b & 0x80 != 0 { level += 1 }
                if b & 0x40 != 0 { level += 1 }

                destination[x] = UInt8(level)
            }
        }
    }

    png_read_end(png_ptr, nil)

    return 1
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
public func swift_swift_image_write(
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

    let width = Int(image.pointee.width)
    let height = Int(image.pointee.height)

    guard width > 0, height > 0 else {
        swift_c_error(png_ptr, "png_image: no image to write")
    }

    // A colour-mapped write has nothing in common with the rest of this function below: the file
    // is indexed rather than sampled, which changes the header, needs a palette built from the
    // client's own map rather than a per-row transform, and writes the client's index bytes
    // through packing rather than any of the arrangements below.
    if format.isColormapped {
        return writeColormapImage(
            image: image, png_ptr: png_ptr, info_ptr: info_ptr, width: width, height: height,
            buffer: buffer, rowStride: row_stride, colormap: colormap
        )
    }

    // Sixteen bit input is light, and a sixteen bit file can hold it as it stands: the file simply
    // says so, through a gamma of one.  Asked to narrow it to eight, the light has to go through the
    // display's curve on the way down, which is what the vendored table in SRGBTable.swift is for.
    //
    // Either way coverage has to come back out of the colour, since these formats keep it multiplied
    // in and the format does not.  Both happen a row at a time below.
    let writes16Bit = format.isLinear && convert_to_8_bit == 0
    let narrows = format.isLinear && convert_to_8_bit != 0

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
        writes16Bit ? 16 : 8,
        colorType,
        PNG_INTERLACE_NONE,
        PNG_COMPRESSION_TYPE_DEFAULT,
        PNG_FILTER_TYPE_DEFAULT
    )

    // What space the samples are in, said in the file rather than left to be assumed.  A reader that
    // guesses gets this right anyway — the guess is the same — but a file that says so is readable by
    // something that does not guess the same way, which is the point of writing it down.
    let colorsIsSRGB = image.pointee.flags
        & png_uint_32(PNG_IMAGE_FLAG_COLORSPACE_NOT_sRGB) == 0

    if writes16Bit {
        // Light, held as it stands: a gamma of one says the samples are already linear.  The
        // primaries are still sRGB's, which the gamma alone would not say.
        png_set_gAMA_fixed(png_ptr, info_ptr, png_fixed_point(PNG_FP_1))

        if colorsIsSRGB {
            png_set_cHRM_fixed(
                png_ptr, info_ptr,
                31270, 32900,   // white
                64000, 33000,   // red
                30000, 60000,   // green
                15000, 6000     // blue
            )
        }
    } else if colorsIsSRGB {
        png_set_sRGB(png_ptr, info_ptr, PNG_sRGB_INTENT_PERCEPTUAL)
    } else {
        // Eight bit samples are encoded for a display whatever their primaries are, so the curve is
        // still worth writing down even when the sRGB chunk would be wrong.
        png_set_gAMA_fixed(png_ptr, info_ptr, 45455)
    }

    png_write_info(png_ptr, info_ptr)

    // The client's rows are in the arrangement it named, and the file's are in the format's own.  Both
    // of these are their own inverses, which is why the same calls serve here as when reading.
    //
    // Asked for after the header is written rather than before, which is the opposite of the reading
    // side and is the reference's own ordering: the header describes the file, and these describe the
    // rows on their way into it.
    if writes16Bit, SimplifiedFormat.isLittleEndian {
        // The client hands over numbers in this machine's order; the file stores them in the
        // format's.
        png_set_swap(png_ptr)
    }

    if format.isReversed {
        png_set_bgr(png_ptr)
    }

    if format.alphaFirst {
        png_set_swap_alpha(png_ptr)
    }

    let minimum = width * format.channels * format.bytesPerChannel
    let stride = row_stride == 0 ? minimum : Int(row_stride) * format.bytesPerChannel

    guard abs(stride) >= minimum else {
        swift_c_error(png_ptr, "png_image: row stride too small")
    }

    // A negative stride says the client holds the image bottom-up, which is its business: the file is
    // written top-down either way.
    let first = stride < 0
        ? buffer.advanced(by: -stride * (height - 1))
        : buffer

    if writes16Bit, format.hasAlpha {
        // The row has to be taken apart before it is written, so it needs somewhere to go: the
        // client's buffer is its own and is not written to.
        let samples = width * format.channels
        let staging = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: samples)
        defer { staging.deallocate() }

        for row in 0 ..< height {
            let source = first.advanced(by: stride * row)
                .assumingMemoryBound(to: UInt16.self)

            unpremultiply(
                source,
                into: staging.baseAddress!,
                width: width,
                colorChannels: format.hasColor ? 3 : 1,
                alphaFirst: format.alphaFirst
            )

            staging.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: samples * 2) {
                png_write_row(png_ptr, $0)
            }
        }
    } else if narrows {
        // Light on the way down to eight bits, and the coverage taken back out of it if there is
        // any.  One row's worth of bytes, since what leaves is half what arrives.
        let samples = width * format.channels
        let staging = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: samples)
        defer { staging.deallocate() }

        for row in 0 ..< height {
            let source = first.advanced(by: stride * row)
                .assumingMemoryBound(to: UInt16.self)

            narrow(
                source,
                into: staging.baseAddress!,
                width: width,
                colorChannels: format.hasColor ? 3 : 1,
                hasAlpha: format.hasAlpha,
                alphaFirst: format.alphaFirst
            )

            png_write_row(png_ptr, staging.baseAddress!)
        }
    } else {
        for row in 0 ..< height {
            let source = first.advanced(by: stride * row)
                .assumingMemoryBound(to: UInt8.self)

            png_write_row(png_ptr, source)
        }
    }

    png_write_end(png_ptr, info_ptr)

    return 1
}

/// Writes a colour-mapped image: an indexed file, built from the client's own index rows and a
/// palette taken from its colour map.  Kept apart from the rest of `swift_swift_image_write`
/// because none of what that does applies here — a colour map is not itself samples the ordinary
/// per-row arrangements have any business touching, and the file's own bit depth is chosen from
/// how many entries the map holds rather than assumed to be eight or sixteen.
private func writeColormapImage(
    image: png_imagep,
    png_ptr: png_structrp,
    info_ptr: png_inforp,
    width: Int,
    height: Int,
    buffer: UnsafeRawPointer,
    rowStride: png_int_32,
    colormap: UnsafeRawPointer?
) -> Int32 {
    guard let colormap, image.pointee.colormap_entries > 0 else {
        swift_c_error(png_ptr, "png_image: no color-map for color-mapped image")
    }

    // Every entry, not the file's rows, is what decides the depth: an index the client's own rows
    // never exceed still costs whatever a byte-packed map would cost to store if the map itself
    // holds more entries than the rows ever name, since nothing here inspects the rows to find out
    // any of them actually use the low ones.
    let entries = min(Int(image.pointee.colormap_entries), 256)
    let bitDepth: Int32 = entries > 16 ? 8 : (entries > 4 ? 4 : (entries > 2 ? 2 : 1))

    png_set_IHDR(
        png_ptr, info_ptr, png_uint_32(width), png_uint_32(height), bitDepth,
        PNG_COLOR_TYPE_PALETTE, PNG_INTERLACE_NONE,
        PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT
    )

    writeColormapPalette(
        image: image, png_ptr: png_ptr, info_ptr: info_ptr, colormap: colormap, entries: entries
    )

    // What space the map's own colours are in, said in the file the same way the ordinary
    // (non-colour-mapped) writer says it — a colour map is never sixteen bit light the way a plain
    // row can be, so there is no gamma-of-one case to consider here.
    let colorsIsSRGB = image.pointee.flags
        & png_uint_32(PNG_IMAGE_FLAG_COLORSPACE_NOT_sRGB) == 0

    if colorsIsSRGB {
        png_set_sRGB(png_ptr, info_ptr, PNG_sRGB_INTENT_PERCEPTUAL)
    } else {
        png_set_gAMA_fixed(png_ptr, info_ptr, 45455)
    }

    png_write_info(png_ptr, info_ptr)

    // The rows the client hands over are already byte-packed indices regardless of how few entries
    // the map holds; a file with sixteen or fewer needs them packed down to the depth just chosen.
    if entries <= 16 {
        png_set_packing(png_ptr)
    }

    let stride = rowStride == 0 ? width : Int(rowStride)

    guard abs(stride) >= width else {
        swift_c_error(png_ptr, "png_image: row stride too small")
    }

    let first = stride < 0
        ? buffer.advanced(by: -stride * (height - 1))
        : buffer

    for row in 0 ..< height {
        let source = first.advanced(by: stride * row).assumingMemoryBound(to: UInt8.self)

        png_write_row(png_ptr, source)
    }

    png_write_end(png_ptr, info_ptr)

    return 1
}

/// Builds the palette, and the transparency table if any entry is not fully opaque, a
/// colour-mapped write's indices point into — the reference's own `png_image_set_PLTE`.  A colour
/// map is read here exactly once per entry rather than once per pixel, which is what makes the
/// reference's own coarse per-map correction affordable in a way a per-pixel one would not be.
private func writeColormapPalette(
    image: png_imagep,
    png_ptr: png_structrp,
    info_ptr: png_inforp,
    colormap: UnsafeRawPointer,
    entries: Int
) {
    let format = SimplifiedFormat(raw: image.pointee.format)
    let channels = format.channels

    // AFIRST only ever reorders an alpha channel that exists; a map with none has nothing for it
    // to move.
    let alphaFirst = format.alphaFirst && format.hasAlpha
    let blueOffset = format.isReversed ? 0 : 2
    let redOffset = format.isReversed ? 2 : 0

    var palette = [png_color](repeating: png_color(red: 0, green: 0, blue: 0), count: entries)
    var trans = [UInt8](repeating: 255, count: entries)
    var transparentCount = 0

    if format.isLinear {
        // Sixteen bit light, premultiplied the same way a row would be if the format carried
        // coverage — undone here once per entry with the reference's own reciprocal, the same
        // arithmetic `unpremultiply` uses for a row, collapsed to the single sRGB byte a palette
        // entry holds rather than a corrected sixteen bit sample.
        let source = colormap.assumingMemoryBound(to: UInt16.self)

        for i in 0 ..< entries {
            let base = i * channels

            if !format.hasAlpha {
                if format.hasColor {
                    palette[i].red = sRGBFromLinear(255 &* UInt32(source[base + redOffset]))
                    palette[i].green = sRGBFromLinear(255 &* UInt32(source[base + 1]))
                    palette[i].blue = sRGBFromLinear(255 &* UInt32(source[base + blueOffset]))
                } else {
                    let value = sRGBFromLinear(255 &* UInt32(source[base]))
                    palette[i].red = value
                    palette[i].green = value
                    palette[i].blue = value
                }
            } else {
                let alpha = source[base + (alphaFirst ? 0 : channels - 1)]
                let colourOffset = alphaFirst ? 1 : 0
                let alphaByte = unpremultipliedAlphaByte(alpha)

                trans[i] = alphaByte
                if alphaByte < 255 { transparentCount = i + 1 }

                // Rounded to eight bits and back before it decides whether a reciprocal is worth
                // computing at all — the reference's own two-step shortcut, not an equivalent
                // rewrite of it: an alpha whose eight bit rounding lands on zero or two hundred
                // fifty five skips the reciprocal even where the raw sixteen bit value alone would
                // not have, and every channel below has to see the same skip to agree with it.
                let reciprocal: UInt32 = (alphaByte > 0 && alphaByte < 255)
                    ? (((UInt32(0xFFFF) &* 0xFF) << 7) &+ UInt32(alpha >> 1)) / UInt32(alpha)
                    : 0

                if format.hasColor {
                    palette[i].red = unpremultiply(
                        source[base + colourOffset + redOffset], alpha: alpha, reciprocal: reciprocal
                    )
                    palette[i].green = unpremultiply(
                        source[base + colourOffset + 1], alpha: alpha, reciprocal: reciprocal
                    )
                    palette[i].blue = unpremultiply(
                        source[base + colourOffset + blueOffset], alpha: alpha, reciprocal: reciprocal
                    )
                } else {
                    let value = unpremultiply(
                        source[base + colourOffset], alpha: alpha, reciprocal: reciprocal
                    )
                    palette[i].red = value
                    palette[i].green = value
                    palette[i].blue = value
                }
            }
        }
    } else {
        let source = colormap.assumingMemoryBound(to: UInt8.self)

        for i in 0 ..< entries {
            let base = i * channels

            switch channels {
            case 4:
                let alpha = source[base + (alphaFirst ? 0 : 3)]
                trans[i] = alpha
                if alpha < 255 { transparentCount = i + 1 }

                fallthrough

            case 3:
                let colourOffset = alphaFirst ? 1 : 0

                palette[i].red = source[base + colourOffset + redOffset]
                palette[i].green = source[base + colourOffset + 1]
                palette[i].blue = source[base + colourOffset + blueOffset]

            case 2:
                let alpha = source[base + (alphaFirst ? 0 : 1)]
                trans[i] = alpha
                if alpha < 255 { transparentCount = i + 1 }

                fallthrough

            case 1:
                let value = source[base + (channels == 2 && alphaFirst ? 1 : 0)]
                palette[i].red = value
                palette[i].green = value
                palette[i].blue = value

            default:
                break
            }
        }
    }

    palette.withUnsafeBufferPointer {
        png_set_PLTE(png_ptr, info_ptr, $0.baseAddress, Int32(entries))
    }

    if transparentCount > 0 {
        trans.withUnsafeBufferPointer {
            png_set_tRNS(png_ptr, info_ptr, $0.baseAddress, Int32(transparentCount), nil)
        }
    }
}

/// The eight bit sRGB byte a sixteen bit premultiplied sample undoes to, one channel of one
/// colour-map entry at a time.  Full intensity once a sample cannot be recovered — at or above its
/// own coverage, the reference's own rule wherever a premultiplied sample is undone — and rounded
/// rather than computed exactly below the level an eight bit result could ever show it at.
private func unpremultiply(_ component: UInt16, alpha: UInt16, reciprocal: UInt32) -> UInt8 {
    guard component < alpha, alpha >= 128 else {
        return 255
    }

    guard component > 0 else {
        return 0
    }

    if alpha < 65407 {
        // Scaled by 255*65535 and then seven bits further, matching the reciprocal's own scale,
        // rounded to the nearest before the final shift back down to that.  The reciprocal itself
        // is the caller's: computed once per entry rather than once per channel, and skipped
        // (zero) wherever the entry's own eight bit alpha said it was not worth it — a decision
        // every channel here has to see the same way to agree with the reference.
        let scaled = (UInt32(component) &* reciprocal &+ 64) >> 7

        return sRGBFromLinear(scaled)
    }

    return sRGBFromLinear(UInt32(component) &* 255)
}

/// The eight bit alpha a colour-map entry's own coverage rounds to — `PNG_DIV257`, the reference's
/// own reciprocal rounding of a sixteen bit value down to eight, not a plain shift.
private func unpremultipliedAlphaByte(_ alpha: UInt16) -> UInt8 {
    UInt8((UInt32(alpha) &+ 128) / 257)
}

/// Takes the coverage back out of the colour, which is what the format stores.
///
/// The linear formats hold colour already multiplied by coverage — convenient to composite with and
/// not what a file holds, so it has to be undone on the way in.  The arithmetic is exact and is the
/// reference's own: a reciprocal to fifteen bits of precision, which is enough that every sample
/// divides and rounds to the same number rather than to one near it.
///
/// The layout is left alone.  A row whose coverage comes first stays that way and is reordered by the
/// ordinary request, the same as a row that needed nothing undone.
private func unpremultiply(
    _ source: UnsafePointer<UInt16>,
    into destination: UnsafeMutablePointer<UInt16>,
    width: Int,
    colorChannels: Int,
    alphaFirst: Bool
) {
    let stride = colorChannels + 1

    // Where the coverage sits relative to the colour, so that one loop serves both arrangements.
    let alphaOffset = alphaFirst ? 0 : colorChannels
    let colorOffset = alphaFirst ? 1 : 0

    for pixel in 0 ..< width {
        let base = pixel * stride
        let alpha = source[base + alphaOffset]

        destination[base + alphaOffset] = alpha

        // Only worth computing between the two ends: nothing covered divides by zero, and fully
        // covered is already the answer.
        let reciprocal: UInt32 = alpha > 0 && alpha < 65535
            ? ((UInt32(0xFFFF) << 15) + UInt32(alpha >> 1)) / UInt32(alpha)
            : 0

        for channel in 0 ..< colorChannels {
            let index = base + colorOffset + channel
            let component = source[index]

            if component >= alpha {
                // Including the fully transparent pixel, whose colour is unrecoverable.  Full
                // intensity rather than none: a transparent run next to a nearly transparent one
                // compresses better without a cliff between them, and nothing displays either.
                destination[index] = 65535
            } else if component > 0, alpha < 65535 {
                destination[index] = UInt16((UInt32(component) * reciprocal + 16384) >> 15)
            } else {
                destination[index] = component
            }
        }
    }
}

/// Takes light down to eight bits, undoing the pre-multiplication on the way if there is coverage.
///
/// Two things happen per sample and the order matters: the coverage comes out first, in light, and
/// only then does the result go through the display's curve.  Doing it the other way round would be
/// dividing encoded numbers, which are not proportional to anything.
///
/// The arithmetic is the reference's throughout, including where it declines to be exact.  A sample
/// at or above its own coverage is full intensity rather than the ratio, and coverage that would
/// round to nothing takes the colour with it — both so that a nearly transparent run does not
/// develop a cliff against a fully transparent one, which costs compression and shows nothing.
private func narrow(
    _ source: UnsafePointer<UInt16>,
    into destination: UnsafeMutablePointer<UInt8>,
    width: Int,
    colorChannels: Int,
    hasAlpha: Bool,
    alphaFirst: Bool
) {
    guard hasAlpha else {
        // Nothing multiplied in, so the samples only have to be scaled into the range the table is
        // built over and looked up.
        for sample in 0 ..< width * colorChannels {
            destination[sample] = sRGBFromLinear(UInt32(source[sample]) &* 255)
        }

        return
    }

    let stride = colorChannels + 1
    let alphaOffset = alphaFirst ? 0 : colorChannels
    let colorOffset = alphaFirst ? 1 : 0

    for pixel in 0 ..< width {
        let base = pixel * stride
        let alpha = UInt32(source[base + alphaOffset])

        // The eight bit coverage the file will carry, rounded the way the reference rounds it.
        let alphaByte = UInt8(truncatingIfNeeded: (alpha &* 255 &+ 32895) >> 16)

        destination[base + alphaOffset] = alphaByte

        // Only between the two ends, as when staying at sixteen bits — and to a different scale,
        // since the result feeds the table rather than another sixteen bit sample.
        let reciprocal: UInt32 = alphaByte > 0 && alphaByte < 255
            ? (((0xFFFF &* 0xFF) << 7) &+ (alpha >> 1)) / alpha
            : 0

        for channel in 0 ..< colorChannels {
            let index = base + colorOffset + channel
            var component = UInt32(source[index])

            if component >= alpha || alpha < 128 {
                // Including a fully transparent pixel, whose colour is unrecoverable.
                destination[index] = 255
            } else if component > 0 {
                // Coverage that rounds to full is left alone rather than divided by very nearly one,
                // which would cost a count for nothing.  65407 is the first value that rounds up.
                if alpha < 65407 {
                    component = (component &* reciprocal &+ 64) >> 7
                } else {
                    component &*= 255
                }

                destination[index] = sRGBFromLinear(component)
            } else {
                destination[index] = 0
            }
        }
    }
}
