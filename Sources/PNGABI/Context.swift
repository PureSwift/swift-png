// Context.swift - attaching and detaching the engine's state
//
// The C shim allocates and releases the control structures; these are the two
// points where the Swift objects hanging off them come and go.  They are called
// from C, so they are `@c` exports, though the export list keeps them out of the
// finished library's symbol table.
//
// The `Host` built here is the seam that lets the engine allocate and read without
// knowing anything about the C API.  Each entry is a non-capturing closure, which
// compiles to a plain function pointer: nothing reference-counted can hide behind
// one, and a client jumping out of the callback it wraps leaves nothing of ours on
// the stack.

import CPNG
import PNGCore

private func makeHost(_ png_ptr: png_structrp) -> Host {
    Host(
        owner: UnsafeMutableRawPointer(png_ptr),
        allocate: { owner, size in
            spng_c_malloc(owner?.pngStruct, png_alloc_size_t(size))
        },
        deallocate: { owner, memory in
            spng_c_free(owner?.pngStruct, memory)
        },
        read: { owner, destination, count in
            spng_c_call_read(owner?.pngStruct, destination, size_t(count))
        },
        warn: { owner, message, length in
            spng_c_warning_bytes(
                owner?.pngStruct,
                UnsafeRawPointer(message)?.assumingMemoryBound(to: CChar.self),
                size_t(length)
            )
        }
    )
}

extension UnsafeMutableRawPointer {
    /// The control structure a `Host.Owner` refers to.
    fileprivate var pngStruct: png_structp {
        self.assumingMemoryBound(to: png_struct.self)
    }
}

@c
public func spng_swift_context_create(_ png_ptr: png_structrp?, _ is_read: Int32) -> Int32 {
    guard let png_ptr else { return 0 }

    let context = PngContext(host: makeHost(png_ptr), isReading: is_read != 0)

    // Retained, and released by the destructor.  The control structure is the only
    // owner, which is what lets a client jump from anywhere and still have
    // png_destroy_read_struct reclaim everything.
    png_ptr.pointee.swift_ctx = Unmanaged.passRetained(context).toOpaque()

    return 1
}

@c
public func spng_swift_context_destroy(_ png_ptr: png_structrp?) {
    guard let png_ptr, let opaque = png_ptr.pointee.swift_ctx else { return }

    png_ptr.pointee.swift_ctx = nil

    let context = Unmanaged<PngContext>.fromOpaque(opaque)

    // Released before the reference is dropped, because the buffers were allocated
    // through the allocator in the control structure, which the caller is about to
    // free.
    context.takeUnretainedValue().release()
    context.release()
}

@c
public func spng_swift_info_create(
    _ info_ptr: png_inforp?,
    _ png_ptr: png_const_structrp?
) -> Int32 {
    guard let info_ptr else { return 0 }

    info_ptr.pointee.swift_ctx = Unmanaged.passRetained(InfoStore()).toOpaque()

    return 1
}

@c
public func spng_swift_info_destroy(
    _ info_ptr: png_inforp?,
    _ png_ptr: png_const_structrp?
) {
    guard let info_ptr, let opaque = info_ptr.pointee.swift_ctx else { return }

    info_ptr.pointee.swift_ctx = nil
    Unmanaged<InfoStore>.fromOpaque(opaque).release()
}

@c
public func spng_swift_info_reset(
    _ info_ptr: png_inforp?,
    _ png_ptr: png_const_structrp?
) {
    guard let info_ptr, let info = InfoStore.from(info_ptr) else { return }

    info.reset()
}
