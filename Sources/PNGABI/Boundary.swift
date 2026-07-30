// Boundary.swift - where the engine meets the C API
//
// Two jobs. It resolves a `png_structp` to the engine objects hanging off it, and
// it turns a thrown failure into the client's error handler.
//
// The order in `attempt` is the whole point of the arrangement. The engine throws,
// which unwinds every engine frame normally, releasing whatever they held. Only
// then, with nothing of ours left on the stack, does control reach the client's
// handler — which will very likely longjmp straight past us to wherever the client
// called setjmp.

import CPNG
import PNGCore

/// Runs an engine operation and reports a failure the way the C API does.
///
/// Nothing in the calling frame may own memory at the point this is called, since
/// the error path does not return.
func attempt(_ png_ptr: png_structrp?, _ body: (PngContext) throws -> Void) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    do {
        try body(context)
    } catch let diagnostic as Diagnostic {
        report(diagnostic, to: png_ptr)
    } catch {
        spng_c_error(png_ptr, "internal error")
    }
}

/// As ``attempt(_:_:)``, for operations that need the info structure too.
func attempt(
    _ png_ptr: png_structrp?,
    _ info_ptr: png_inforp?,
    _ body: (PngContext, InfoStore) throws -> Void
) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    guard let info_ptr, let info = InfoStore.from(info_ptr) else {
        spng_c_error(png_ptr, "no info structure")
    }

    do {
        try body(context, info)
    } catch let diagnostic as Diagnostic {
        report(diagnostic, to: png_ptr)
    } catch {
        spng_c_error(png_ptr, "internal error")
    }
}

/// Hands a diagnostic to the client, as an error or a warning as its severity says.
///
/// Chunk-attributed messages are prefixed the way the reference implementation
/// prefixes them, since clients display these.
private func report(_ diagnostic: Diagnostic, to png_ptr: png_structrp) {
    // Staged into the structure's own buffer first, because the dispatchers take a
    // terminated string and a Swift literal's termination is an implementation
    // detail rather than a guarantee.
    let message = diagnostic.borrowedMessage ?? stage(diagnostic.message, into: png_ptr)

    guard var chunkName = diagnostic.chunk?.text else {
        switch diagnostic.severity {
        case .error: spng_c_error(png_ptr, message)
        case .benign: spng_c_benign_error(png_ptr, message)
        case .warning: spng_c_warning(png_ptr, message)
        }
        return
    }

    withUnsafePointer(to: &chunkName) { name in
        let chunk = UnsafeRawPointer(name).assumingMemoryBound(to: CChar.self)

        switch diagnostic.severity {
        case .error: spng_c_chunk_error(png_ptr, chunk, message)
        case .benign, .warning: spng_c_chunk_warning(png_ptr, chunk, message)
        }
    }
}

/// Copies a message into the control structure's own buffer and returns a
/// terminated pointer to it.
///
/// The engine's messages are string literals, whose null termination is an
/// implementation detail rather than a guarantee, so they are terminated here
/// explicitly.
private func stage(
    _ message: StaticString,
    into png_ptr: png_structrp
) -> UnsafePointer<CChar> {
    let capacity = Int(SPNG_MESSAGE_MAX) - 1

    let source = message.hasPointerRepresentation ? message.utf8Start : nil
    let count = min(source == nil ? 0 : message.utf8CodeUnitCount, capacity)

    return withUnsafeMutablePointer(to: &png_ptr.pointee.message) { storage in
        let base = UnsafeMutableRawPointer(storage)
            .assumingMemoryBound(to: CChar.self)

        if let source {
            for index in 0 ..< count {
                base[index] = CChar(bitPattern: source[index])
            }
        }
        base[count] = 0

        return UnsafePointer(base)
    }
}

extension PngContext {
    /// The engine object hanging off a control structure.
    static func from(_ png_ptr: png_const_structrp) -> PngContext? {
        guard let opaque = png_ptr.pointee.swift_ctx else { return nil }
        return Unmanaged<PngContext>.fromOpaque(opaque).takeUnretainedValue()
    }
}

extension InfoStore {
    static func from(_ info_ptr: png_const_inforp) -> InfoStore? {
        guard let opaque = info_ptr.pointee.swift_ctx else { return nil }
        return Unmanaged<InfoStore>.fromOpaque(opaque).takeUnretainedValue()
    }
}

extension ChunkName {
    /// The type code as five bytes, terminated, for the diagnostic prefix.
    var text: (CChar, CChar, CChar, CChar, CChar) {
        let (a, b, c, d) = self.bytes
        return (
            CChar(bitPattern: a),
            CChar(bitPattern: b),
            CChar(bitPattern: c),
            CChar(bitPattern: d),
            0
        )
    }
}
