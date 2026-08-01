// TransformAPI.swift - asking for the rows to be reshaped
//
// Each of these records a request and returns.  None of them does any work, and none of them
// depends on the others having been called or not: the requests are resolved together once the
// image is known, and applied in an order this file has no say in.
//
// That is why they are so short, and it is deliberate. A client may call them in any order, twice,
// or in combinations that contradict each other, and the resolution has to be the same either way.
// Putting the logic here would make the answer depend on the call order.

import CPNG
import PNG

/// Records a request against the control structure.
private func request(_ png_ptr: png_structrp?, _ flags: TransformFlags) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }
    context.transformFlags.insert(flags)
}

// -- expanding ---------------------------------------------------------------

/// Turns whatever the file holds into samples: palette entries into colours, low-depth greyscale
/// into eight bit, a transparent colour into an alpha channel.
///
/// Which of those apply depends on the image, which is why one call covers all three: a client
/// asking for this wants pixels and has stopped caring what the file contained.
@c @implementation
public func png_set_expand(_ png_ptr: png_structrp?) {
    request(png_ptr, [.expand, .expandTransparency, .expandGrayTo8])
}

@c @implementation
public func png_set_palette_to_rgb(_ png_ptr: png_structrp?) {
    request(png_ptr, [.expand, .expandTransparency])
}

/// Widens greyscale samples narrower than a byte.
///
/// Asks for the palette expansion as well, which is what the reference does: an indexed image passed
/// to this comes back as colour rather than unchanged.  It does not ask for the transparency to
/// become a channel, so an image with a transparent colour keeps it as one.
@c @implementation
public func png_set_expand_gray_1_2_4_to_8(_ png_ptr: png_structrp?) {
    request(png_ptr, [.expandGrayTo8, .expand])
}

@c @implementation
public func png_set_tRNS_to_alpha(_ png_ptr: png_structrp?) {
    request(png_ptr, [.expand, .expandTransparency])
}

/// Widens eight bit samples to sixteen.
@c @implementation
public func png_set_expand_16(_ png_ptr: png_structrp?) {
    request(png_ptr, [.expand16, .expand, .expandTransparency])
}

// -- narrowing ---------------------------------------------------------------

/// Narrows sixteen bit samples by discarding the low byte.
@c @implementation
public func png_set_strip_16(_ png_ptr: png_structrp?) {
    request(png_ptr, .strip16)
}

/// Narrows sixteen bit samples by scaling them.
///
/// Not the same as discarding the low byte, and the difference is why both exist: scaling maps the
/// full range onto the full range, so the brightest sample stays the brightest.
@c @implementation
public func png_set_scale_16(_ png_ptr: png_structrp?) {
    request(png_ptr, .scale16)
}

@c @implementation
public func png_set_strip_alpha(_ png_ptr: png_structrp?) {
    request(png_ptr, .stripAlpha)
}

// -- rearranging -------------------------------------------------------------

/// Replaces a grey channel with three equal colour channels.
///
/// Asks for the palette expansion as well, which is what the reference does: an indexed image passed
/// to this comes back as colour, by way of its palette rather than by tripling an index.  The
/// transparency is left as it is.
@c @implementation
public func png_set_gray_to_rgb(_ png_ptr: png_structrp?) {
    request(png_ptr, [.grayToRgb, .expand])
}

/// Spreads samples narrower than a byte one to a byte, without scaling them.
@c @implementation
public func png_set_packing(_ png_ptr: png_structrp?) {
    request(png_ptr, .packing)
}

/// Reverses the order of samples within a byte.
@c @implementation
public func png_set_packswap(_ png_ptr: png_structrp?) {
    request(png_ptr, .packSwap)
}

@c @implementation
public func png_set_bgr(_ png_ptr: png_structrp?) {
    request(png_ptr, .bgr)
}

/// Exchanges the two bytes of each sixteen bit sample.
@c @implementation
public func png_set_swap(_ png_ptr: png_structrp?) {
    request(png_ptr, .swapBytes)
}

@c @implementation
public func png_set_swap_alpha(_ png_ptr: png_structrp?) {
    request(png_ptr, .swapAlpha)
}

@c @implementation
public func png_set_invert_alpha(_ png_ptr: png_structrp?) {
    request(png_ptr, .invertAlpha)
}

@c @implementation
public func png_set_invert_mono(_ png_ptr: png_structrp?) {
    request(png_ptr, .invertMono)
}

/// Moves samples up so that a narrower original range fills the stored depth.
///
/// Only does anything for an image whose significant bits chunk said the samples were widened from
/// something narrower; the chunk is what says how far to move them.
@c @implementation
public func png_set_shift(_ png_ptr: png_structrp?, _ true_bits: png_const_color_8p?) {
    guard let png_ptr, let context = PngContext.from(png_ptr), let true_bits else { return }

    // The amounts come from the client here rather than from the file, so they are recorded where
    // the transform will look for them.
    var bits = SignificantBits()
    bits.red = true_bits.pointee.red
    bits.green = true_bits.pointee.green
    bits.blue = true_bits.pointee.blue
    bits.gray = true_bits.pointee.gray
    bits.alpha = true_bits.pointee.alpha

    // Checked here rather than when the pipeline is built, which is where it would be cheaper and
    // where the reference does not do it.  The difference shows whenever another call would also
    // complain: a client is told about the first mistake it made, in the order it made them.
    //
    do {
        try context.validateShift(bits)
    } catch let diagnostic as Diagnostic {
        report(diagnostic, to: png_ptr)
    } catch {
        swift_c_error(png_ptr, "internal error")
    }

    context.shiftBits = bits
    context.transformFlags.insert(.shift)
}

// -- adding a channel --------------------------------------------------------

/// Adds a channel of constant value, which does not count as alpha.
///
/// A client that wants the extra channel treated as alpha calls `png_set_add_alpha` instead. The
/// bytes written are the same; what differs is what the row then reports itself to be.
@c @implementation
public func png_set_filler(
    _ png_ptr: png_structrp?,
    _ filler: png_uint_32,
    _ filler_loc: Int32
) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    context.fillerValue = filler
    context.fillerAfterColor = filler_loc == PNG_FILLER_AFTER
    context.transformFlags.insert(.filler)
}

@c @implementation
public func png_set_add_alpha(
    _ png_ptr: png_structrp?,
    _ filler: png_uint_32,
    _ filler_loc: Int32
) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    context.fillerValue = filler
    context.fillerAfterColor = filler_loc == PNG_FILLER_AFTER
    context.transformFlags.insert(.addAlpha)
}

// -- resolving ---------------------------------------------------------------

/// Resolves the requested transforms and updates the image description to match.
///
/// A client calls this to find out what its rows will look like — how many bytes, how many channels,
/// what colour type — because it has to allocate before it can read. Everything the accessors report
/// afterwards describes the rows the client is about to receive rather than the ones the file holds.
@c @implementation
public func png_read_update_info(_ png_ptr: png_structrp?, _ info_ptr: png_inforp?) {
    attempt(png_ptr, info_ptr) { context, info in
        try context.updateInfoForClient(info)
    }
}

// -- gamma -------------------------------------------------------------------

/// Says what exponent the client's display expects, and what the file's samples were encoded with.
///
/// The file's exponent is overridden unconditionally, even when the file said otherwise. That is
/// deliberate on the API's part: a client calling this has a reason to distrust or replace what the
/// file claimed, and a call that silently deferred to the file would be unpredictable.
///
/// A file encoded at 1/2.2 shown on a display expecting 2.2 needs no correction, and nothing is
/// applied in that case — the two exponents multiply to one.
@c @implementation
public func png_set_gamma_fixed(
    _ png_ptr: png_structrp?,
    _ scrn_gamma: png_fixed_point,
    _ file_gamma: png_fixed_point
) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    context.gamma.screenGamma = scrn_gamma
    context.gamma.fileGamma = file_gamma
    context.transformFlags.insert(.gamma)
}

@c @implementation
public func png_set_gamma(
    _ png_ptr: png_structrp?,
    _ scrn_gamma: Double,
    _ file_gamma: Double
) {
    png_set_gamma_fixed(
        png_ptr,
        png_fixed_point((scrn_gamma * 100_000).rounded()),
        png_fixed_point((file_gamma * 100_000).rounded())
    )
}

// -- discarding colour -------------------------------------------------------

/// Collapses the three colour channels into one, with the given weights.
///
/// The weights are how much each channel contributes to the brightness a viewer perceives, and the
/// defaults are not an even split: green carries most of it and blue very little. A negative weight
/// asks for the defaults.
///
/// `error_action` decides what a pixel that was not already grey means. A client converting an image
/// it believes is greyscale already can ask to be told, which turns the conversion into a check.
@c @implementation
public func png_set_rgb_to_gray_fixed(
    _ png_ptr: png_structrp?,
    _ error_action: Int32,
    _ red: png_fixed_point,
    _ green: png_fixed_point
) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    context.rgbToGray.request(RgbToGrayState.ErrorAction(rawValue: error_action) ?? .none)

    // Supplied as fractions scaled by 100000 and held as weights out of 32768, which is what lets the
    // sum be integer arithmetic.
    if red >= 0, green >= 0 {
        context.rgbToGray.red = Int32((Double(red) * 32768 / 100_000).rounded())
        context.rgbToGray.green = Int32((Double(green) * 32768 / 100_000).rounded())
    }

    context.transformFlags.insert(.rgbToGray)
}

@c @implementation
public func png_set_rgb_to_gray(
    _ png_ptr: png_structrp?,
    _ error_action: Int32,
    _ red: Double,
    _ green: Double
) {
    // A negative weight means "use the defaults", and has to survive the conversion as one.
    png_set_rgb_to_gray_fixed(
        png_ptr,
        error_action,
        red < 0 ? -1 : png_fixed_point((red * 100_000).rounded()),
        green < 0 ? -1 : png_fixed_point((green * 100_000).rounded())
    )
}

/// Whether the conversion met a pixel that was not already grey.
///
/// Non-zero once any has been seen, which is how a client tells whether the conversion lost anything.
@c @implementation
public func png_get_rgb_to_gray_status(_ png_ptr: png_const_structrp?) -> png_byte {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return 0 }
    return context.rgbToGray.sawColor ? 1 : 0
}

// -- compositing -------------------------------------------------------------

/// Lays the image over a background colour, so that what comes back has no alpha channel.
///
/// The colour is expected at the image's own depth — nought to 255 for an eight bit image, the full
/// range for a sixteen bit one — unless `need_expand` says it is given in the file's terms, in which
/// case it may be a palette index or a value at a depth the row will be widened out of.
///
/// `background_gamma_code` says what space the colour itself is in, because one already in the
/// display's space must not be corrected along with the image.
@c @implementation
public func png_set_background_fixed(
    _ png_ptr: png_structrp?,
    _ background_color: png_const_color_16p?,
    _ background_gamma_code: Int32,
    _ need_expand: Int32,
    _ background_gamma: png_fixed_point
) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }
    guard let background_color else { return }

    var color = Rgb16()
    color.index = background_color.pointee.index
    color.red = background_color.pointee.red
    color.green = background_color.pointee.green
    color.blue = background_color.pointee.blue
    color.gray = background_color.pointee.gray

    context.compose.color = color
    context.compose.gammaCode =
        ComposeState.GammaCode(rawValue: background_gamma_code) ?? .unknown
    context.compose.gamma = background_gamma
    context.compose.needsExpanding = need_expand != 0

    context.transformFlags.insert(.compose)
}

@c @implementation
public func png_set_background(
    _ png_ptr: png_structrp?,
    _ background_color: png_const_color_16p?,
    _ background_gamma_code: Int32,
    _ need_expand: Int32,
    _ background_gamma: Double
) {
    png_set_background_fixed(
        png_ptr,
        background_color,
        background_gamma_code,
        need_expand,
        png_fixed_point((background_gamma * 100_000).rounded())
    )
}

// -- the alpha arrangement ---------------------------------------------------

/// Says how the client wants colour and coverage arranged, and what its display expects.
///
/// The format keeps the two independent: a pixel's colour is what it would be if opaque. Compositing
/// wants them already multiplied and as light, so a client about to draw asks for that instead.
///
/// This also settles the gamma when the file did not. A file with no gamma chunk is taken to have been
/// encoded for the display the client just named, which is what makes the default arrangement a no-op
/// rather than a guess — and it is the easier way to default the file's gamma that the API intends.
@c @implementation
public func png_set_alpha_mode_fixed(
    _ png_ptr: png_structrp?,
    _ mode: Int32,
    _ output_gamma_requested: png_fixed_point
) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    let alphaMode = AlphaMode(rawValue: mode) ?? .png

    // Two of the values this takes are names rather than numbers, and they are negative so that they
    // cannot be mistaken for one: the display the format assumes when a file says nothing, and the one
    // an older generation of machines had.  The second is not the 1.8 its name suggests — it is 2.2
    // divided by 1.45, which is what those machines actually did — and both were measured against the
    // reference rather than taken from the name.
    let output_gamma: png_fixed_point

    switch output_gamma_requested {
    case -1: output_gamma = 220_000
    case -2: output_gamma = 151_724
    default: output_gamma = output_gamma_requested
    }

    // Every arrangement but the format's own is a blend against black, so it wants the compositing
    // machinery for itself — and refuses to share it.  A client that has already named a background,
    // or already asked for an arrangement, is told rather than quietly having one request win.
    //
    // Which makes the pair order-dependent: naming a background after an arrangement is accepted and
    // replaces the black, while doing it the other way round is an error.  That is the reference's
    // behaviour, and a client meeting it is being told its two requests do not compose.
    if alphaMode != .png,
       context.transformFlags.contains(.compose) || context.alphaModeComposes {
        swift_c_error(png_ptr, "conflicting calls to set alpha mode and background")
    }

    context.alphaMode = alphaMode
    context.alphaModeComposes = context.alphaModeComposes || alphaMode != .png

    // Taken from what the client said, before the arrangement gets to override it below: the default is
    // that the file was encoded for the display the client just named, whatever the library then does
    // with the samples on the way there.
    //
    // Only a default — a file that said what it was encoded with is believed.
    if context.gamma.fileGamma == 0, output_gamma > 0 {
        context.gamma.fileGamma = png_fixed_point((1e10 / Double(output_gamma)).rounded())
    }

    // The premultiplied arrangement is defined in light, so its output is linear by definition and what
    // the client asked for is overridden.  The others keep the client's encoding: the optimized
    // arrangement needs it for the opaque pixels it leaves alone, and the broken one for the coverage
    // it puts through the curve.
    context.gamma.screenGamma = alphaMode == .premultiplied ? 100_000 : output_gamma

    context.transformFlags.insert([.alphaMode, .gamma])
}

@c @implementation
public func png_set_alpha_mode(
    _ png_ptr: png_structrp?,
    _ mode: Int32,
    _ output_gamma: Double
) {
    png_set_alpha_mode_fixed(
        png_ptr,
        mode,
        png_fixed_point((output_gamma * 100_000).rounded())
    )
}


// -- a transform of the client's own -----------------------------------------

/// Installs a transform the client runs itself, after everything the library does.
///
/// The row it is handed is the library's own buffer, so a client may change the samples in place;
/// what it must not do is write past what it declared, which is what the declaration below is for.
@c @implementation
public func png_set_read_user_transform_fn(
    _ png_ptr: png_structrp?,
    _ read_user_transform_fn: png_user_transform_ptr?
) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    png_ptr.pointee.read_user_transform_fn = read_user_transform_fn

    // Passing nothing takes the request away again, which matters because the request is what makes
    // the row buffer large enough for a shape the client declared.
    if read_user_transform_fn == nil {
        context.transformFlags.remove(.userTransform)
    } else {
        context.transformFlags.insert(.userTransform)
    }
}

/// Installs a transform the client runs itself on the way out, before anything the library does.
///
/// The mirror of the reading one, with one difference worth naming: what it declared through
/// `png_set_user_transform_info` has no effect here.  The row it is handed is the one the file will
/// store, and the row it leaves is written as it stands.
@c @implementation
public func png_set_write_user_transform_fn(
    _ png_ptr: png_structrp?,
    _ write_user_transform_fn: png_user_transform_ptr?
) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    png_ptr.pointee.write_user_transform_fn = write_user_transform_fn

    if write_user_transform_fn == nil {
        context.transformFlags.remove(.userTransform)
    } else {
        context.transformFlags.insert(.userTransform)
    }
}

/// Says what the client's own transform will leave a row looking like, and gives it a pointer of its
/// own to find its way back to whatever it needs.
///
/// The library cannot work the shape out for itself, since the transform is the client's code, so
/// this is taken at its word: it settles the row size reported by `png_read_update_info` and the
/// buffer the row is decoded into.  Zero for either means the client is not changing that one.
@c @implementation
public func png_set_user_transform_info(
    _ png_ptr: png_structrp?,
    _ user_transform_ptr: png_voidp?,
    _ user_transform_depth: Int32,
    _ user_transform_channels: Int32
) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    png_ptr.pointee.user_transform_ptr = user_transform_ptr
    png_ptr.pointee.user_transform_depth = png_byte(truncatingIfNeeded: user_transform_depth)
    png_ptr.pointee.user_transform_channels = png_byte(truncatingIfNeeded: user_transform_channels)

    context.userTransformDepth = Int(user_transform_depth)
    context.userTransformChannels = Int(user_transform_channels)
}

@c @implementation
public func png_get_user_transform_ptr(_ png_ptr: png_const_structrp?) -> png_voidp? {
    png_ptr?.pointee.user_transform_ptr
}
