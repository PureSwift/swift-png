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
        // the same free addition it is for the palette case, for the same reason: every entry is
        // opaque either way.
        if !format.isLinear, header.colorType == .grayscale, header.bitDepth <= 8, !fileHasAlpha {
            return readGrayColormap(
                image: image, png_ptr: png_ptr, info_ptr: info_ptr, info: info, header: header,
                buffer: buffer, rowStride: row_stride, colormap: colormap
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

        // Coverage in the output but not the source is still fine here, unlike the other two
        // cases: every entry is opaque either way, so an alpha channel the client asked for is
        // just a constant 255 alongside the colour rather than something that has to be composed.
        if format.hasColor, !format.isLinear, header.colorType.isIndexed, !fileHasAlpha {
            return readPaletteColormap(
                image: image, png_ptr: png_ptr, info_ptr: info_ptr, info: info, header: header,
                buffer: buffer, rowStride: row_stride, colormap: colormap
            )
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
    // rather than refused.  Not for an indexed source, and not combined with colour reduced to grey
    // or the reverse — both stay their own, still-refused cases.
    if !format.hasAlpha, fileHasAlpha, background == nil, !format.isLinear {
        guard !header.colorType.isIndexed,
            format.hasColor == header.colorType.hasColor else {
            swift_c_error(png_ptr, "png_image: removing alpha onto the buffer not implemented")
        }

        // What a file with no gAMA of its own is assumed to have been encoded with — the same
        // question requestConversion answers below, asked again here since a source with real
        // coverage to remove never reaches that call at all.
        let assumesLinearInput = header.bitDepth == 16
            && image.pointee.flags & png_uint_32(PNG_IMAGE_FLAG_16BIT_sRGB) == 0

        return readComposite(
            image: image, png_ptr: png_ptr, info_ptr: info_ptr, header: header, format: format,
            assumesLinearInput: assumesLinearInput, buffer: buffer, rowStride: row_stride
        )
    }

    // Discarding colour is ordinary averaging — png_set_rgb_to_gray, the same call every other
    // caller of this library reaches for.  Kept alongside coverage the file already has and at
    // eight bits, that is all it is: nothing is being composited away or premultiplied, so the
    // double gamma correction the reference works around below has nothing to trip over — this
    // combination reaches the ordinary request below rather than being refused.  Sixteen bits is
    // not the same: there the alpha-mode step premultiplies unconditionally, whether or not the
    // channel survives to the output, and premultiplying is exactly the operation rgb-to-gray
    // cannot share a pass with — so linear output stays refused alongside removing the channel.
    if !format.hasColor, (header.colorType.hasColor || header.colorType.isIndexed), fileHasAlpha,
        (!format.hasAlpha || format.isLinear) {
        swift_c_error(png_ptr, "png_image: discarding colour and alpha together not implemented")
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
}

private func readGrayColormap(
    image: png_imagep,
    png_ptr: png_structrp,
    info_ptr: png_inforp,
    info: InfoStore,
    header: Header,
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

    // Colour reaching this function has already been averaged away, or is about to be — see the
    // caller and the flag passed below — so the map is a plain grey ramp either way, and needs
    // building only the once.
    let entries = 1 << header.bitDepth
    let step = 255 / (entries - 1)
    let channels = format.channels
    let map = colormap.assumingMemoryBound(to: UInt8.self)

    for i in 0 ..< entries {
        let corrected = correction.correct(UInt32(i * step))
        let base = i * channels

        // A grey value asked back as colour is the same value repeated across every channel —
        // there is only one light level here for red, green and blue to agree on.
        if format.hasColor {
            map[base] = corrected
            map[base + 1] = corrected
            map[base + 2] = corrected
        } else {
            map[base] = corrected
        }

        // Opaque: the caller has already refused any file with a tRNS chunk, so there is no
        // coverage to report and every entry that asked for an alpha channel gets full alpha.
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

/// Reads an opaque indexed file into a colour map of its own — literally its palette, corrected
/// for gamma, with an index of a client's own choosing.  The narrowest of the three colour-mapped
/// cases built so far, because a file that is already colour-mapped needs no quantizing at all:
/// its samples already are the indices a client wants, unchanged, into a map that is a one-to-one
/// correction of the one it already had.
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

    for i in 0 ..< entries {
        let source = info.palette.elements[i]
        let base = i * channels

        map[base + redOffset] = correction.correct(UInt32(source.red))
        map[base + 1] = correction.correct(UInt32(source.green))
        map[base + blueOffset] = correction.correct(UInt32(source.blue))

        // Opaque: the caller has already refused any file with a tRNS chunk, so there is no
        // coverage to report and every entry that asked for an alpha channel gets full alpha.
        if format.hasAlpha {
            map[base + 3] = 255
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

    guard !format.isColormapped else {
        swift_c_error(png_ptr, "png_image: colour-mapped input not implemented")
    }

    // Sixteen bit input is light, and a sixteen bit file can hold it as it stands: the file simply
    // says so, through a gamma of one.  Asked to narrow it to eight, the light has to go through the
    // display's curve on the way down, which is what the vendored table in SRGBTable.swift is for.
    //
    // Either way coverage has to come back out of the colour, since these formats keep it multiplied
    // in and the format does not.  Both happen a row at a time below.
    let writes16Bit = format.isLinear && convert_to_8_bit == 0
    let narrows = format.isLinear && convert_to_8_bit != 0

    let width = Int(image.pointee.width)
    let height = Int(image.pointee.height)

    guard width > 0, height > 0 else {
        swift_c_error(png_ptr, "png_image: no image to write")
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
