// OptionsAPI.swift - the switches that are not about the image
//
// What a client turns on and off here is how the library behaves rather than what the picture is:
// which optional behaviours to allow, how strict to be about a check, and which of the format's
// extensions to tolerate.  None of them changes a decoded pixel unless something is wrong.
//
// The numbering is sparse on purpose: the even numbers are options and the odd ones are reserved for
// the same option's "supported" question, which is why an unset one reads as zero and an unrecognised
// one has a value of its own.

import CPNG
import PNGCore

/// Turns one of the library's own behaviours on or off, reporting what it was.
///
/// The answer is the previous setting rather than the new one, which reads oddly until you want it: a
/// client that means to restore what it found needs to be told what that was.
@c @implementation
public func png_set_option(_ png_ptr: png_structrp?, _ option: Int32, _ onoff: Int32) -> Int32 {
    guard let png_ptr, let context = PngContext.from(png_ptr) else {
        return PNG_OPTION_INVALID
    }

    // Only the even numbers are options at all, and only up to the highest the library defines.
    guard option >= 0, option < PNG_OPTION_NEXT, option % 2 == 0 else {
        return PNG_OPTION_INVALID
    }

    let index = Int(option) / 2
    let previous = context.options[index]

    context.options[index] = onoff == PNG_OPTION_ON
        ? PNG_OPTION_ON
        : (onoff == PNG_OPTION_OFF ? PNG_OPTION_OFF : PNG_OPTION_UNSET)

    return previous
}

/// Allows the extensions a related format defines, and reports which of them this library has.
///
/// Two exist: an empty palette, which that format uses to say "the one you already have", and a set of
/// filters it added.  A client asking for others is told what it actually got rather than refused —
/// the answer is the request narrowed to what is on offer.
@c @implementation
public func png_permit_mng_features(
    _ png_ptr: png_structrp?,
    _ mng_features_permitted: png_uint_32
) -> png_uint_32 {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return 0 }

    let supported = png_uint_32(PNG_FLAG_MNG_EMPTY_PLTE | PNG_FLAG_MNG_FILTER_64)

    context.mngFeatures = mng_features_permitted & supported

    return context.mngFeatures
}

/// Two calls that no longer do anything.
///
/// They chose between ways of guessing which filter would compress best.  The guessing is now fixed —
/// the sum of the differences, and nothing else — so these are kept for the programs that call them
/// and do nothing, silently, which is what the reference does.
@c @implementation
public func png_set_filter_heuristics(
    _ png_ptr: png_structrp?,
    _ heuristic_method: Int32,
    _ num_weights: Int32,
    _ filter_weights: png_const_doublep?,
    _ filter_costs: png_const_doublep?
) {}

@c @implementation
public func png_set_filter_heuristics_fixed(
    _ png_ptr: png_structrp?,
    _ heuristic_method: Int32,
    _ num_weights: Int32,
    _ filter_weights: UnsafePointer<png_fixed_point>?,
    _ filter_costs: UnsafePointer<png_fixed_point>?
) {}

/// Watches for a palette index the palette does not have.
///
/// Off by default on writing and on when reading, because the two are different questions: a file
/// being read may contain anything, and a file being written was built by the client.
@c @implementation
public func png_set_check_for_invalid_index(_ png_ptr: png_structrp?, _ allowed: Int32) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    context.checksPaletteIndices = allowed != 0
}

/// Starts the decompressor over.
///
/// For a client that has abandoned one stream and wants the structure for another.  What it does not
/// do is undo anything else: the image state is where it was.
@c @implementation
public func png_reset_zstream(_ png_ptr: png_structrp?) -> Int32 {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return -2 }

    return Int32(context.resetDecompression())
}


/// Where in the file the library currently is.
///
/// For a client watching from inside its own read or write callback, which is handed a count of bytes
/// and nothing else: without this it cannot tell a chunk's header from its contents.
@c @implementation
public func png_get_io_state(_ png_ptr: png_const_structrp?) -> png_uint_32 {
    guard let png_ptr, let context = PngContext.from(png_structp(mutating: png_ptr)) else {
        return 0
    }

    return context.ioState
}

/// Which chunk that is, as its four bytes packed into a number.
@c @implementation
public func png_get_io_chunk_type(_ png_ptr: png_const_structrp?) -> png_uint_32 {
    guard let png_ptr, let context = PngContext.from(png_structp(mutating: png_ptr)) else {
        return 0
    }

    return context.ioChunkName.packed
}
