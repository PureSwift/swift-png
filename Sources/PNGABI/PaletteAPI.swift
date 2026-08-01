// PaletteAPI.swift - the payloads whose address the client is given
//
// These differ from the value accessors in one way that matters: they hand the client a
// pointer into our storage rather than a copy.  The client may keep that pointer for as
// long as the info structure lives, and may even take ownership of the block, so the
// memory behind it comes from the client's own allocator and is not moved once reported.
//
// The setters copy.  A client that passes a palette expects to be able to free its own
// array afterwards, which is only true if we took a copy of it.

import CPNG
import PNG

/// Runs an update that allocates, reporting a failure through the control structure.
///
/// Unlike the value setters, these can fail: they copy the client's data into memory from
/// the client's allocator, and that allocation can fail.
func updateAllocating(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ body: (InfoStore) throws -> Void
) {
    guard let info_ptr, let info = InfoStore.from(info_ptr) else { return }

    do {
        try body(info)
    } catch let diagnostic as Diagnostic {
        // The published signature has no way to report a failure, so it goes through the
        // control structure's error path, as every other failure does.
        guard let png_ptr else { return }
        report(diagnostic, to: png_structp(mutating: png_ptr))
    } catch {
        guard let png_ptr else { return }
        spng_c_error(png_structp(mutating: png_ptr), "out of memory")
    }
}

// -- palette -----------------------------------------------------------------

/// The palette, reported as a pointer into our storage.
///
/// `png_color` has the same layout as the three bytes stored per entry, so the array is
/// handed over as it stands rather than copied into a second table.
@c @implementation
public func png_get_PLTE(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ palette: UnsafeMutablePointer<png_colorp?>?,
    _ num_palette: UnsafeMutablePointer<Int32>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_PLTE), let address = info.palette.address else {
            return 0
        }

        palette?.pointee = UnsafeMutableRawPointer(address)
            .assumingMemoryBound(to: png_color.self)
        num_palette?.pointee = Int32(info.palette.count)

        return png_uint_32(PNG_INFO_PLTE)
    }
}

@c @implementation
public func png_set_PLTE(
    _ png_ptr: png_structrp?,
    _ info_ptr: png_inforp?,
    _ palette: png_const_colorp?,
    _ num_palette: Int32
) {
    updateAllocating(png_ptr.map { png_const_structrp($0) }, info_ptr) { info in
        guard let palette, num_palette > 0 else { return }

        guard num_palette <= 256 else {
            throw Diagnostic("Invalid palette size", chunk: .plte)
        }

        let count = Int(num_palette)
        var storage = try EscapingBuffer<Rgb8>.allocated(count, host: info.host)
        let entries = storage.elements

        for index in 0 ..< count {
            entries[index] = Rgb8(
                red: palette[index].red,
                green: palette[index].green,
                blue: palette[index].blue
            )
        }

        info.palette.deallocate(host: info.host)
        info.palette = storage
        info.markValid(PNG_INFO_PLTE)
    }
}

// -- transparency ------------------------------------------------------------

/// Transparency, in whichever of its two forms the image calls for.
///
/// An indexed image gets the alpha table; anything else gets a single colour. The two are
/// reported through the same call, with the unused pointer left alone.
@c @implementation
public func png_get_tRNS(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ trans_alpha: UnsafeMutablePointer<png_bytep?>?,
    _ num_trans: UnsafeMutablePointer<Int32>?,
    _ trans_color: UnsafeMutablePointer<png_color_16p?>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_tRNS) else { return 0 }

        let hasTable = info.transparentCount > 0 && info.transparentAlpha.address != nil

        if hasTable, let address = info.transparentAlpha.address {
            trans_alpha?.pointee = address
            num_trans?.pointee = Int32(info.transparentCount)
        } else {
            // A non-indexed image has a colour rather than a table, and the reference still reports a
            // count of one — unless the transparency has already been folded into a channel, in which
            // case there is nothing left to count.
            //
            // The table pointer is cleared rather than left as the client had it, and that matters
            // more than it looks: the count is reported either way, so a client that reads the table
            // because the count is not zero reads whatever was on its stack.
            trans_alpha?.pointee = nil
            num_trans?.pointee = info.transparencyConsumed ? 0 : 1
        }

        // The colour is reported either way.  For an indexed image it is zeroed rather than
        // absent, which is what the reference hands over, and a client that reads it
        // unconditionally gets something defined.
        guard let table = try? info.reserveExportTable(
            .transparentColor,
            byteCount: MemoryLayout<png_color_16>.stride
        ) else {
            return hasTable ? png_uint_32(PNG_INFO_tRNS) : 0
        }

        let entry = table.assumingMemoryBound(to: png_color_16.self)
        let color = info.transparentColor

        entry.pointee.index = color.index
        entry.pointee.red = color.red
        entry.pointee.green = color.green
        entry.pointee.blue = color.blue
        entry.pointee.gray = color.gray

        trans_color?.pointee = png_color_16p(entry)

        return png_uint_32(PNG_INFO_tRNS)
    }
}

@c @implementation
public func png_set_tRNS(
    _ png_ptr: png_structrp?,
    _ info_ptr: png_inforp?,
    _ trans_alpha: png_const_bytep?,
    _ num_trans: Int32,
    _ trans_color: png_const_color_16p?
) {
    updateAllocating(png_ptr.map { png_const_structrp($0) }, info_ptr) { info in
        if let trans_alpha, num_trans > 0 {
            let count = Int(num_trans)

            guard count <= 256 else {
                throw Diagnostic("Invalid", chunk: .trns)
            }

            var storage = try EscapingBuffer<UInt8>.allocated(count, host: info.host)
            storage.elements.baseAddress!.update(from: trans_alpha, count: count)

            info.transparentAlpha.deallocate(host: info.host)
            info.transparentAlpha = storage
            info.transparentCount = count
        }

        if let trans_color {
            var color = Rgb16()
            color.index = trans_color.pointee.index
            color.red = trans_color.pointee.red
            color.green = trans_color.pointee.green
            color.blue = trans_color.pointee.blue
            color.gray = trans_color.pointee.gray

            info.transparentColor = color
        }

        info.markValid(PNG_INFO_tRNS)
    }
}

// -- background --------------------------------------------------------------

@c @implementation
public func png_get_bKGD(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ background: UnsafeMutablePointer<png_color_16p?>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_bKGD) else { return 0 }

        guard let table = try? info.reserveExportTable(
            .background,
            byteCount: MemoryLayout<png_color_16>.stride
        ) else {
            return 0
        }

        let entry = table.assumingMemoryBound(to: png_color_16.self)
        let value = info.background

        entry.pointee.index = value.index
        entry.pointee.red = value.red
        entry.pointee.green = value.green
        entry.pointee.blue = value.blue
        entry.pointee.gray = value.gray

        background?.pointee = png_color_16p(entry)

        return png_uint_32(PNG_INFO_bKGD)
    }
}

@c @implementation
public func png_set_bKGD(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ background: png_const_color_16p?
) {
    guard let info_ptr, let info = InfoStore.from(info_ptr), let background else { return }

    var value = Rgb16()
    value.index = background.pointee.index
    value.red = background.pointee.red
    value.green = background.pointee.green
    value.blue = background.pointee.blue
    value.gray = background.pointee.gray

    info.background = value
    info.markValid(PNG_INFO_bKGD)
}

// -- histogram ---------------------------------------------------------------

@c @implementation
public func png_get_hIST(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ hist: UnsafeMutablePointer<png_uint_16p?>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_hIST), let address = info.histogram.address else {
            return 0
        }

        hist?.pointee = address

        return png_uint_32(PNG_INFO_hIST)
    }
}

@c @implementation
public func png_set_hIST(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ hist: png_const_uint_16p?
) {
    updateAllocating(png_ptr.map { png_const_structrp($0) }, info_ptr) { info in
        guard let hist, !info.palette.isEmpty else { return }

        // One frequency per palette entry, so the palette has to be set first; there is no
        // other way to know how many to copy.
        let count = info.palette.count
        var storage = try EscapingBuffer<UInt16>.allocated(count, host: info.host)
        storage.elements.baseAddress!.update(from: hist, count: count)

        info.histogram.deallocate(host: info.host)
        info.histogram = storage
        info.markValid(PNG_INFO_hIST)
    }
}

// -- colour profile ----------------------------------------------------------

@c @implementation
public func png_get_iCCP(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ name: png_charpp?,
    _ compression_type: UnsafeMutablePointer<Int32>?,
    _ profile: png_bytepp?,
    _ proflen: UnsafeMutablePointer<png_uint_32>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_iCCP) else { return 0 }

        name?.pointee = info.profileName.address
        compression_type?.pointee = Int32(info.profileCompression)
        profile?.pointee = info.profile.address

        proflen?.pointee = png_uint_32(info.profile.count)

        return png_uint_32(PNG_INFO_iCCP)
    }
}

@c @implementation
public func png_set_iCCP(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ name: png_const_charp?,
    _ compression_type: Int32,
    _ profile: png_const_bytep?,
    _ proflen: png_uint_32
) {
    updateAllocating(png_ptr, info_ptr) { info in
        guard let profile, proflen > 0 else { return }

        let count = Int(proflen)

        // Both allocated before either is recorded, so a failure in the second leaves the
        // previous profile intact rather than a name with no profile behind it.
        let storedName = try TextStorage.copying(name, host: info.host)
        var storedProfile: EscapingBuffer<UInt8>

        do {
            storedProfile = try EscapingBuffer<UInt8>.allocated(count, host: info.host)
        } catch {
            storedName.deallocate(host: info.host)
            throw error
        }

        storedProfile.elements.baseAddress!.update(from: profile, count: count)

        info.profileName.deallocate(host: info.host)
        info.profile.deallocate(host: info.host)

        info.profileName = storedName
        info.profile = storedProfile
        info.profileCompression = UInt8(truncatingIfNeeded: compression_type)
        info.markValid(PNG_INFO_iCCP)
    }
}

// -- camera metadata ---------------------------------------------------------

@c @implementation
public func png_get_eXIf_1(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ num_exif: UnsafeMutablePointer<png_uint_32>?,
    _ exif: UnsafeMutablePointer<png_bytep?>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_eXIf), let address = info.exif.address else { return 0 }

        num_exif?.pointee = png_uint_32(info.exif.count)
        exif?.pointee = address

        return png_uint_32(PNG_INFO_eXIf)
    }
}

@c @implementation
public func png_set_eXIf_1(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ num_exif: png_uint_32,
    _ exif: png_bytep?
) {
    updateAllocating(png_ptr, info_ptr) { info in
        guard let exif, num_exif > 0 else { return }

        let count = Int(num_exif)
        var storage = try EscapingBuffer<UInt8>.allocated(count, host: info.host)
        storage.elements.baseAddress!.update(from: exif, count: count)

        info.exif.deallocate(host: info.host)
        info.exif = storage
        info.markValid(PNG_INFO_eXIf)
    }
}

// -- physical scale ----------------------------------------------------------

@c @implementation
public func png_get_sCAL_s(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ unit: UnsafeMutablePointer<Int32>?,
    _ width: png_charpp?,
    _ height: png_charpp?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_sCAL) else { return 0 }

        unit?.pointee = Int32(info.scale.unit)

        width?.pointee = info.scale.width.address
        height?.pointee = info.scale.height.address

        return png_uint_32(PNG_INFO_sCAL)
    }
}

@c @implementation
public func png_set_sCAL_s(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ unit: Int32,
    _ swidth: png_const_charp?,
    _ sheight: png_const_charp?
) {
    // Checked before anything is stored, and refused rather than corrected: the string is kept as the
    // client gave it, so a string the format does not allow would reach the file unchanged.
    for (bytes, what) in [(swidth, "width"), (sheight, "height")] {
        guard let bytes, !AsciiNumbers.isValid(terminated: bytes) else { continue }
        guard let png_ptr else { return }

        spng_c_error(
            png_structp(mutating: png_ptr),
            what == "width" ? "Invalid sCAL width" : "Invalid sCAL height"
        )
    }

    updateAllocating(png_ptr, info_ptr) { info in
        let storedWidth = try TextStorage.copying(swidth, host: info.host)
        let storedHeight: TextStorage

        do {
            storedHeight = try TextStorage.copying(sheight, host: info.host)
        } catch {
            storedWidth.deallocate(host: info.host)
            throw error
        }

        info.scale.width.deallocate(host: info.host)
        info.scale.height.deallocate(host: info.host)

        info.scale.unit = UInt8(truncatingIfNeeded: unit)
        info.scale.width = storedWidth
        info.scale.height = storedHeight
        info.markValid(PNG_INFO_sCAL)
    }
}

// -- the physical scale, as numbers rather than strings ----------------------
//
// The chunk holds text, and these are the accessors for clients that would rather not deal with it.
// Reading one is a parse; writing one is a format, and the formatting is the reference's own — five
// significant digits, a leading zero omitted, an exponent only when it is shorter — because two
// libraries that write the same number differently write different files.

@c @implementation
public func png_get_sCAL(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ unit: UnsafeMutablePointer<Int32>?,
    _ width: UnsafeMutablePointer<Double>?,
    _ height: UnsafeMutablePointer<Double>?
) -> png_uint_32 {
    query(png_inforp(mutating: info_ptr), 0) { info in
        guard info.isValid(PNG_INFO_sCAL),
              let read = info.scaleAsNumbers else { return 0 }

        unit?.pointee = Int32(info.scale.unit)
        width?.pointee = read.width
        height?.pointee = read.height

        return png_uint_32(PNG_INFO_sCAL)
    }
}

@c @implementation
public func png_get_sCAL_fixed(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ unit: UnsafeMutablePointer<Int32>?,
    _ width: UnsafeMutablePointer<png_fixed_point>?,
    _ height: UnsafeMutablePointer<png_fixed_point>?
) -> png_uint_32 {
    query(png_inforp(mutating: info_ptr), 0) { info in
        guard info.isValid(PNG_INFO_sCAL),
              let read = info.scaleAsNumbers else { return 0 }

        unit?.pointee = Int32(info.scale.unit)
        width?.pointee = png_fixed_point((read.width * 100_000).rounded())
        height?.pointee = png_fixed_point((read.height * 100_000).rounded())

        return png_uint_32(PNG_INFO_sCAL)
    }
}

@c @implementation
public func png_set_sCAL(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ unit: Int32,
    _ width: Double,
    _ height: Double
) {
    setScale(
        png_ptr,
        info_ptr,
        unit: unit,
        width: AsciiNumbers.string(floating: width),
        height: AsciiNumbers.string(floating: height),
        rejects: !(width > 0) || !(height > 0)
    )
}

@c @implementation
public func png_set_sCAL_fixed(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ unit: Int32,
    _ width: png_fixed_point,
    _ height: png_fixed_point
) {
    setScale(
        png_ptr,
        info_ptr,
        unit: unit,
        width: AsciiNumbers.string(fixed: width),
        height: AsciiNumbers.string(fixed: height),
        rejects: width <= 0 || height <= 0
    )
}

/// Stores an already-formatted scale, refusing one the format cannot express.
///
/// A scale of zero or less is not a scale, and the reference declines it with a word rather than
/// writing a chunk no decoder could use.  The two values are refused independently, which is why the
/// caller says whether either was bad rather than this working it out from the strings.
private func setScale(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    unit: Int32,
    width: [UInt8],
    height: [UInt8],
    rejects: Bool
) {
    guard !rejects else {
        if let png_ptr {
            spng_c_warning(png_structp(mutating: png_ptr), "Invalid sCAL width ignored")
        }

        return
    }

    var widthText = width + [0]
    var heightText = height + [0]

    widthText.withUnsafeMutableBufferPointer { widthBytes in
        heightText.withUnsafeMutableBufferPointer { heightBytes in
            png_set_sCAL_s(
                png_ptr,
                info_ptr,
                unit,
                UnsafeRawPointer(widthBytes.baseAddress!).assumingMemoryBound(to: CChar.self),
                UnsafeRawPointer(heightBytes.baseAddress!).assumingMemoryBound(to: CChar.self)
            )
        }
    }
}

// -- the older exif accessors ------------------------------------------------
//
// These cannot work and the reference says so.  Neither carries a length, and the data is not
// terminated, so neither the library nor the client can say how much of it there is.  The pair that
// take a count replaced them; these warn and do nothing, which is what the reference does and what a
// client built against it will already be handling.

@c @implementation
public func png_get_eXIf(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ exif: UnsafeMutablePointer<png_bytep?>?
) -> png_uint_32 {
    if let png_ptr {
        spng_c_warning(png_structp(mutating: png_ptr), "png_get_eXIf does not work; use png_get_eXIf_1")
    }

    return 0
}

@c @implementation
public func png_set_eXIf(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ exif: png_bytep?
) {
    if let png_ptr {
        spng_c_warning(png_structp(mutating: png_ptr), "png_set_eXIf does not work; use png_set_eXIf_1")
    }
}
