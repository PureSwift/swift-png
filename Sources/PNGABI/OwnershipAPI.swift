// OwnershipAPI.swift - who frees what
//
// Most of what an info structure holds was allocated by this library and is released with it.  A
// client may want otherwise: to take a palette it was given and keep it after the structure is gone,
// or to hand one over and have the library take responsibility.  These are the two calls that move
// that responsibility, and the one that acts on it.
//
// What makes this worth care is that both sides free through the same allocator, so a block freed
// twice is freed twice — and a block freed by neither is simply lost.

import CPNG
import PNG

/// Says who will free the named data.
///
/// The library's own answer is that it will, when the structure is destroyed.  A client that says
/// otherwise is taking the block: this library stops tracking it, and stops freeing it.
@c @implementation
public func png_data_freer(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ freer: Int32,
    _ mask: png_uint_32
) {
    guard let info_ptr, let info = InfoStore.from(info_ptr) else { return }

    switch freer {
    case PNG_DESTROY_WILL_FREE_DATA:
        info.reclaimOwnership(of: mask)

    case PNG_USER_WILL_FREE_DATA:
        info.relinquishOwnership(of: mask)

    default:
        guard let png_ptr else { return }

        swift_c_error(
            png_structp(mutating: png_ptr),
            "Unknown freer parameter in png_data_freer"
        )
    }
}

/// Frees the named data now.
///
/// Data the client has taken responsibility for is left where it is: this library lets go of it
/// rather than freeing it, which is the whole point of having been told.
///
/// A client may call this more than once for the same data, and does — so everything freed here is
/// also forgotten, and a second call has nothing to do.
@c @implementation
public func png_free_data(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ mask: png_uint_32,
    _ num: Int32
) {
    guard let info_ptr, let info = InfoStore.from(info_ptr) else { return }

    info.freeData(mask, index: Int(num))
}
