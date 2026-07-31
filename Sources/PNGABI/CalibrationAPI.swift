// CalibrationAPI.swift - the two chunks that describe rather than depict
//
// One says what the samples measure, for an image that is a set of readings rather than a picture.
// The other suggests palettes, for a decoder that has to show the image with fewer colours than it
// has.  Neither changes a pixel, and both are lists of strings and numbers a client hands over and
// gets back.
//
// What is awkward about both is the shape of the answer.  A client is given pointers into this
// library's own memory and is entitled to read them until it sets something else — so the arrays it
// reads are built here, out of storage the info structure owns, rather than assembled on a frame.

import CPNG
import PNGCore

@c @implementation
public func png_set_pCAL(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ purpose: png_const_charp?,
    _ X0: png_int_32,
    _ X1: png_int_32,
    _ type: Int32,
    _ nparams: Int32,
    _ units: png_const_charp?,
    _ params: png_charpp?
) {
    guard let png_ptr, let info_ptr, let info = InfoStore.from(info_ptr) else { return }

    // The four equations the format defines.  A fifth is not an equation this library could apply, and
    // writing it would produce a file no decoder could read, so it is refused rather than stored.
    guard let equation = Calibration.Equation(rawValue: UInt8(truncatingIfNeeded: type)) else {
        spng_c_error(png_structp(mutating: png_ptr), "Invalid pCAL equation type")
    }

    guard Int(nparams) == equation.parameterCount else {
        spng_c_error(png_structp(mutating: png_ptr), "Invalid pCAL parameter count")
    }

    updateAllocating(png_ptr, info_ptr) { info in
        var calibration = Calibration()

        calibration.purpose = try TextStorage.copying(purpose, host: info.host)
        calibration.unit = try TextStorage.copying(units, host: info.host)
        calibration.x0 = X0
        calibration.x1 = X1
        calibration.equation = equation.rawValue

        for index in 0 ..< Int(nparams) {
            calibration.parameters.append(
                try TextStorage.copying(params?[index], host: info.host)
            )
        }

        info.calibration.deallocate(host: info.host)
        info.calibration = calibration
        info.markValid(PNG_INFO_pCAL)
    }
}

@c @implementation
public func png_get_pCAL(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ purpose: UnsafeMutablePointer<png_charp?>?,
    _ X0: UnsafeMutablePointer<png_int_32>?,
    _ X1: UnsafeMutablePointer<png_int_32>?,
    _ type: UnsafeMutablePointer<Int32>?,
    _ nparams: UnsafeMutablePointer<Int32>?,
    _ units: UnsafeMutablePointer<png_charp?>?,
    _ params: UnsafeMutablePointer<png_charpp?>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_pCAL) else { return 0 }

        // The array of pointers is rebuilt here rather than kept in step with the strings, because it
        // is a view of them: what the client reads has to be the same bytes it would get any other way.
        guard (try? info.buildCalibrationPointers()) != nil else { return 0 }

        purpose?.pointee = info.calibration.purpose.address
        X0?.pointee = info.calibration.x0
        X1?.pointee = info.calibration.x1
        type?.pointee = Int32(info.calibration.equation)
        nparams?.pointee = Int32(info.calibration.parameters.count)
        units?.pointee = info.calibration.unit.address
        params?.pointee = info.calibration.parameterPointers.address

        return png_uint_32(PNG_INFO_pCAL)
    }
}

@c @implementation
public func png_set_sPLT(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ entries: png_const_sPLT_tp?,
    _ nentries: Int32
) {
    guard let entries, nentries > 0 else { return }

    updateAllocating(png_ptr, info_ptr) { info in
        for index in 0 ..< Int(nentries) {
            let source = entries[index]
            var palette = SuggestedPalette()

            palette.name = try TextStorage.copying(source.name, host: info.host)
            palette.depth = source.depth

            let count = Int(source.nentries)

            if count > 0, let from = source.entries {
                palette.entries = try EscapingBuffer<png_sPLT_entry_layout>.allocated(count, host: info.host)

                for entry in 0 ..< count {
                    var copy = png_sPLT_entry_layout()

                    copy.red = from[entry].red
                    copy.green = from[entry].green
                    copy.blue = from[entry].blue
                    copy.alpha = from[entry].alpha
                    copy.frequency = from[entry].frequency

                    palette.entries.elements[entry] = copy
                }
            }

            info.suggestedPalettes.append(palette)
        }

        info.markValid(PNG_INFO_sPLT)
    }
}

@c @implementation
public func png_get_sPLT(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ entries: UnsafeMutablePointer<png_sPLT_tp?>?
) -> Int32 {
    query(info_ptr, 0) { info in
        guard !info.suggestedPalettes.isEmpty else { return 0 }
        guard (try? info.buildSuggestedPaletteArray()) != nil else { return 0 }

        entries?.pointee = UnsafeMutableRawPointer(info.suggestedPaletteArray.address)?
            .assumingMemoryBound(to: png_sPLT_t.self)

        return Int32(info.suggestedPalettes.count)
    }
}
