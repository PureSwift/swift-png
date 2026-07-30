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
import PNGCore

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
