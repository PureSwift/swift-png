// MetadataAPI.swift - reading and writing the optional chunk contents
//
// Every one of these follows the same contract, which is worth stating once rather than
// repeating in each doc comment.  A getter answers a bitmask saying whether it had
// anything to report, writes through only the pointers the client passed, and answers
// zero rather than failing when the chunk was absent.  A setter records the value and
// marks the chunk present.
//
// The rationals have two spellings each.  The file stores them as integers scaled by
// 100000, and the API offers both that integer and a converted double; both read the same
// stored integer, so the two answers cannot drift apart.

import CPNG
import PNGCore

/// Runs a query against the info structure, answering `fallback` when there is nothing to
/// query.
private func query<Value>(
    _ info_ptr: png_const_inforp?,
    _ fallback: Value,
    _ body: (InfoStore) -> Value
) -> Value {
    guard let info_ptr, let info = InfoStore.from(info_ptr) else { return fallback }
    return body(info)
}

/// Runs an update against the info structure.
private func update(_ info_ptr: png_inforp?, _ body: (InfoStore) -> Void) {
    guard let info_ptr, let info = InfoStore.from(info_ptr) else { return }
    body(info)
}

/// Converts a stored rational to the double the API also offers.
private func scaled(_ value: FixedPoint) -> Double {
    Double(value) / fixedPointScale
}

/// Converts a client's double to the integer the file stores.
private func unscaled(_ value: Double) -> FixedPoint {
    FixedPoint((value * fixedPointScale).rounded())
}

// -- gamma -------------------------------------------------------------------

@c @implementation
public func png_get_gAMA_fixed(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ file_gamma: UnsafeMutablePointer<png_fixed_point>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_gAMA) else { return 0 }
        file_gamma?.pointee = info.gamma
        return png_uint_32(PNG_INFO_gAMA)
    }
}

@c @implementation
public func png_get_gAMA(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ file_gamma: UnsafeMutablePointer<Double>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_gAMA) else { return 0 }
        file_gamma?.pointee = scaled(info.gamma)
        return png_uint_32(PNG_INFO_gAMA)
    }
}

@c @implementation
public func png_set_gAMA_fixed(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ file_gamma: png_fixed_point
) {
    update(info_ptr) { info in
        info.gamma = file_gamma
        info.markValid(PNG_INFO_gAMA)
    }
}

@c @implementation
public func png_set_gAMA(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ file_gamma: Double
) {
    png_set_gAMA_fixed(png_ptr, info_ptr, unscaled(file_gamma))
}

// -- chromaticity ------------------------------------------------------------

@c @implementation
public func png_get_cHRM_fixed(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ white_x: UnsafeMutablePointer<png_fixed_point>?,
    _ white_y: UnsafeMutablePointer<png_fixed_point>?,
    _ red_x: UnsafeMutablePointer<png_fixed_point>?,
    _ red_y: UnsafeMutablePointer<png_fixed_point>?,
    _ green_x: UnsafeMutablePointer<png_fixed_point>?,
    _ green_y: UnsafeMutablePointer<png_fixed_point>?,
    _ blue_x: UnsafeMutablePointer<png_fixed_point>?,
    _ blue_y: UnsafeMutablePointer<png_fixed_point>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_cHRM) else { return 0 }

        let value = info.chromaticity
        white_x?.pointee = value.whiteX
        white_y?.pointee = value.whiteY
        red_x?.pointee = value.redX
        red_y?.pointee = value.redY
        green_x?.pointee = value.greenX
        green_y?.pointee = value.greenY
        blue_x?.pointee = value.blueX
        blue_y?.pointee = value.blueY

        return png_uint_32(PNG_INFO_cHRM)
    }
}

@c @implementation
public func png_get_cHRM(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ white_x: UnsafeMutablePointer<Double>?,
    _ white_y: UnsafeMutablePointer<Double>?,
    _ red_x: UnsafeMutablePointer<Double>?,
    _ red_y: UnsafeMutablePointer<Double>?,
    _ green_x: UnsafeMutablePointer<Double>?,
    _ green_y: UnsafeMutablePointer<Double>?,
    _ blue_x: UnsafeMutablePointer<Double>?,
    _ blue_y: UnsafeMutablePointer<Double>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_cHRM) else { return 0 }

        let value = info.chromaticity
        white_x?.pointee = scaled(value.whiteX)
        white_y?.pointee = scaled(value.whiteY)
        red_x?.pointee = scaled(value.redX)
        red_y?.pointee = scaled(value.redY)
        green_x?.pointee = scaled(value.greenX)
        green_y?.pointee = scaled(value.greenY)
        blue_x?.pointee = scaled(value.blueX)
        blue_y?.pointee = scaled(value.blueY)

        return png_uint_32(PNG_INFO_cHRM)
    }
}

@c @implementation
public func png_set_cHRM_fixed(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ white_x: png_fixed_point,
    _ white_y: png_fixed_point,
    _ red_x: png_fixed_point,
    _ red_y: png_fixed_point,
    _ green_x: png_fixed_point,
    _ green_y: png_fixed_point,
    _ blue_x: png_fixed_point,
    _ blue_y: png_fixed_point
) {
    update(info_ptr) { info in
        var value = Chromaticity()
        value.whiteX = white_x
        value.whiteY = white_y
        value.redX = red_x
        value.redY = red_y
        value.greenX = green_x
        value.greenY = green_y
        value.blueX = blue_x
        value.blueY = blue_y

        info.chromaticity = value
        info.markValid(PNG_INFO_cHRM)
    }
}

@c @implementation
public func png_set_cHRM(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ white_x: Double,
    _ white_y: Double,
    _ red_x: Double,
    _ red_y: Double,
    _ green_x: Double,
    _ green_y: Double,
    _ blue_x: Double,
    _ blue_y: Double
) {
    png_set_cHRM_fixed(
        png_ptr, info_ptr,
        unscaled(white_x), unscaled(white_y),
        unscaled(red_x), unscaled(red_y),
        unscaled(green_x), unscaled(green_y),
        unscaled(blue_x), unscaled(blue_y)
    )
}

// -- rendering intent --------------------------------------------------------

@c @implementation
public func png_get_sRGB(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ file_srgb_intent: UnsafeMutablePointer<Int32>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_sRGB) else { return 0 }
        file_srgb_intent?.pointee = Int32(info.srgbIntent)
        return png_uint_32(PNG_INFO_sRGB)
    }
}

@c @implementation
public func png_set_sRGB(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ srgb_intent: Int32
) {
    update(info_ptr) { info in
        info.srgbIntent = UInt8(truncatingIfNeeded: srgb_intent)
        info.markValid(PNG_INFO_sRGB)
    }
}

// -- significant bits --------------------------------------------------------

@c @implementation
public func png_get_sBIT(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ sig_bit: UnsafeMutablePointer<png_color_8p?>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_sBIT) else { return 0 }

        // Reported as a pointer to a structure, so one is built in storage the info
        // structure owns rather than in a frame that is about to end.
        guard let table = try? info.reserveExportTable(
            .significantBits,
            byteCount: MemoryLayout<png_color_8>.stride
        ) else {
            return 0
        }

        let entry = table.assumingMemoryBound(to: png_color_8.self)
        let bits = info.significantBits

        entry.pointee.red = bits.red
        entry.pointee.green = bits.green
        entry.pointee.blue = bits.blue
        entry.pointee.gray = bits.gray
        entry.pointee.alpha = bits.alpha

        sig_bit?.pointee = png_color_8p(entry)

        return png_uint_32(PNG_INFO_sBIT)
    }
}

@c @implementation
public func png_set_sBIT(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ sig_bit: png_const_color_8p?
) {
    update(info_ptr) { info in
        guard let sig_bit else { return }

        var bits = SignificantBits()
        bits.red = sig_bit.pointee.red
        bits.green = sig_bit.pointee.green
        bits.blue = sig_bit.pointee.blue
        bits.gray = sig_bit.pointee.gray
        bits.alpha = sig_bit.pointee.alpha

        info.significantBits = bits
        info.markValid(PNG_INFO_sBIT)
    }
}

// -- physical dimensions -----------------------------------------------------

@c @implementation
public func png_get_pHYs(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ res_x: UnsafeMutablePointer<png_uint_32>?,
    _ res_y: UnsafeMutablePointer<png_uint_32>?,
    _ unit_type: UnsafeMutablePointer<Int32>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_pHYs) else { return 0 }

        let value = info.physicalDimensions
        res_x?.pointee = value.pixelsPerUnitX
        res_y?.pointee = value.pixelsPerUnitY
        unit_type?.pointee = Int32(value.unit)

        return png_uint_32(PNG_INFO_pHYs)
    }
}

@c @implementation
public func png_set_pHYs(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ res_x: png_uint_32,
    _ res_y: png_uint_32,
    _ unit_type: Int32
) {
    update(info_ptr) { info in
        var value = PhysicalDimensions()
        value.pixelsPerUnitX = res_x
        value.pixelsPerUnitY = res_y
        value.unit = UInt8(truncatingIfNeeded: unit_type)

        info.physicalDimensions = value
        info.markValid(PNG_INFO_pHYs)
    }
}

/// The resolution as pixels per inch.
///
/// Converted only when the file recorded metres.  For an unspecified unit the stored
/// numbers are passed through unchanged, because there is no ratio to apply and inventing
/// one would misreport what the file said.
@c @implementation
public func png_get_pHYs_dpi(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ res_x: UnsafeMutablePointer<png_uint_32>?,
    _ res_y: UnsafeMutablePointer<png_uint_32>?,
    _ unit_type: UnsafeMutablePointer<Int32>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_pHYs) else { return 0 }

        let value = info.physicalDimensions
        res_x?.pointee = metresToInches(value.pixelsPerUnitX, unit: value.unit)
        res_y?.pointee = metresToInches(value.pixelsPerUnitY, unit: value.unit)
        unit_type?.pointee = Int32(value.unit)

        return png_uint_32(PNG_INFO_pHYs)
    }
}

/// Pixels per metre expressed as pixels per inch, or unchanged for any other unit.
private func metresToInches(_ perMetre: png_uint_32, unit: UInt8) -> png_uint_32 {
    guard unit == 1 else { return perMetre }
    return png_uint_32((Double(perMetre) * 0.0254).rounded())
}

@c @implementation
public func png_get_x_pixels_per_meter(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_pHYs), info.physicalDimensions.unit == 1 else { return 0 }
        return info.physicalDimensions.pixelsPerUnitX
    }
}

@c @implementation
public func png_get_y_pixels_per_meter(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_pHYs), info.physicalDimensions.unit == 1 else { return 0 }
        return info.physicalDimensions.pixelsPerUnitY
    }
}

/// The resolution when it is the same in both directions, and zero when it is not.
@c @implementation
public func png_get_pixels_per_meter(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_pHYs), info.physicalDimensions.unit == 1 else { return 0 }

        let value = info.physicalDimensions
        guard value.pixelsPerUnitX == value.pixelsPerUnitY else { return 0 }

        return value.pixelsPerUnitX
    }
}

@c @implementation
public func png_get_pixels_per_inch(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_uint_32 {
    let perMetre = png_get_pixels_per_meter(png_ptr, info_ptr)
    return png_uint_32((Double(perMetre) * 0.0254).rounded())
}

@c @implementation
public func png_get_x_pixels_per_inch(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_uint_32 {
    let perMetre = png_get_x_pixels_per_meter(png_ptr, info_ptr)
    return png_uint_32((Double(perMetre) * 0.0254).rounded())
}

@c @implementation
public func png_get_y_pixels_per_inch(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_uint_32 {
    let perMetre = png_get_y_pixels_per_meter(png_ptr, info_ptr)
    return png_uint_32((Double(perMetre) * 0.0254).rounded())
}

/// The ratio of pixel height to width, which a viewer needs to avoid distorting an image
/// whose pixels were not square.
@c @implementation
public func png_get_pixel_aspect_ratio(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> Float {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_pHYs) else { return 0 }

        let value = info.physicalDimensions
        guard value.pixelsPerUnitX > 0, value.pixelsPerUnitY > 0 else { return 0 }

        return Float(Double(value.pixelsPerUnitY) / Double(value.pixelsPerUnitX))
    }
}

@c @implementation
public func png_get_pixel_aspect_ratio_fixed(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_fixed_point {
    let ratio = png_get_pixel_aspect_ratio(png_ptr, info_ptr)
    guard ratio != 0 else { return 0 }
    return unscaled(Double(ratio))
}

// -- offset ------------------------------------------------------------------

@c @implementation
public func png_get_oFFs(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ offset_x: UnsafeMutablePointer<png_int_32>?,
    _ offset_y: UnsafeMutablePointer<png_int_32>?,
    _ unit_type: UnsafeMutablePointer<Int32>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_oFFs) else { return 0 }

        let value = info.offset
        offset_x?.pointee = value.x
        offset_y?.pointee = value.y
        unit_type?.pointee = Int32(value.unit)

        return png_uint_32(PNG_INFO_oFFs)
    }
}

@c @implementation
public func png_set_oFFs(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ offset_x: png_int_32,
    _ offset_y: png_int_32,
    _ unit_type: Int32
) {
    update(info_ptr) { info in
        var value = ImageOffset()
        value.x = offset_x
        value.y = offset_y
        value.unit = UInt8(truncatingIfNeeded: unit_type)

        info.offset = value
        info.markValid(PNG_INFO_oFFs)
    }
}

/// The offset in the unit asked for, and zero when the file recorded it in the other one.
@c @implementation
public func png_get_x_offset_microns(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_int_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_oFFs), info.offset.unit == 1 else { return 0 }
        return info.offset.x
    }
}

@c @implementation
public func png_get_y_offset_microns(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_int_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_oFFs), info.offset.unit == 1 else { return 0 }
        return info.offset.y
    }
}

@c @implementation
public func png_get_x_offset_pixels(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_int_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_oFFs), info.offset.unit == 0 else { return 0 }
        return info.offset.x
    }
}

@c @implementation
public func png_get_y_offset_pixels(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_int_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_oFFs), info.offset.unit == 0 else { return 0 }
        return info.offset.y
    }
}

@c @implementation
public func png_get_x_offset_inches(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> Float {
    Float(Double(png_get_x_offset_microns(png_ptr, info_ptr)) * 0.00003937)
}

@c @implementation
public func png_get_y_offset_inches(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> Float {
    Float(Double(png_get_y_offset_microns(png_ptr, info_ptr)) * 0.00003937)
}

@c @implementation
public func png_get_x_offset_inches_fixed(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_fixed_point {
    unscaled(Double(png_get_x_offset_inches(png_ptr, info_ptr)))
}

@c @implementation
public func png_get_y_offset_inches_fixed(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?
) -> png_fixed_point {
    unscaled(Double(png_get_y_offset_inches(png_ptr, info_ptr)))
}

// -- time --------------------------------------------------------------------

@c @implementation
public func png_get_tIME(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ mod_time: UnsafeMutablePointer<png_timep?>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_tIME) else { return 0 }

        guard let table = try? info.reserveExportTable(
            .timestamp,
            byteCount: MemoryLayout<png_time>.stride
        ) else {
            return 0
        }

        let entry = table.assumingMemoryBound(to: png_time.self)
        let value = info.timestamp

        entry.pointee.year = value.year
        entry.pointee.month = value.month
        entry.pointee.day = value.day
        entry.pointee.hour = value.hour
        entry.pointee.minute = value.minute
        entry.pointee.second = value.second

        mod_time?.pointee = png_timep(entry)

        return png_uint_32(PNG_INFO_tIME)
    }
}

@c @implementation
public func png_set_tIME(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ mod_time: png_const_timep?
) {
    update(info_ptr) { info in
        guard let mod_time else { return }

        var value = Timestamp()
        value.year = mod_time.pointee.year
        value.month = mod_time.pointee.month
        value.day = mod_time.pointee.day
        value.hour = mod_time.pointee.hour
        value.minute = mod_time.pointee.minute
        value.second = mod_time.pointee.second

        info.timestamp = value
        info.markValid(PNG_INFO_tIME)
    }
}

// -- high dynamic range signalling -------------------------------------------

@c @implementation
public func png_get_cICP(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ colour_primaries: UnsafeMutablePointer<png_byte>?,
    _ transfer_function: UnsafeMutablePointer<png_byte>?,
    _ matrix_coefficients: UnsafeMutablePointer<png_byte>?,
    _ video_full_range_flag: UnsafeMutablePointer<png_byte>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_cICP) else { return 0 }

        let value = info.codePoints
        colour_primaries?.pointee = value.colorPrimaries
        transfer_function?.pointee = value.transferFunction
        matrix_coefficients?.pointee = value.matrixCoefficients
        video_full_range_flag?.pointee = value.videoFullRangeFlag

        return png_uint_32(PNG_INFO_cICP)
    }
}

@c @implementation
public func png_set_cICP(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ colour_primaries: png_byte,
    _ transfer_function: png_byte,
    _ matrix_coefficients: png_byte,
    _ video_full_range_flag: png_byte
) {
    update(info_ptr) { info in
        var value = CodingIndependentCodePoints()
        value.colorPrimaries = colour_primaries
        value.transferFunction = transfer_function
        value.matrixCoefficients = matrix_coefficients
        value.videoFullRangeFlag = video_full_range_flag

        info.codePoints = value
        info.markValid(PNG_INFO_cICP)
    }
}

@c @implementation
public func png_get_cLLI_fixed(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ maxCLL: png_uint_32p?,
    _ maxFALL: png_uint_32p?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_cLLI) else { return 0 }

        maxCLL?.pointee = info.contentLightLevel.maxContentLightLevel
        maxFALL?.pointee = info.contentLightLevel.maxFrameAverageLightLevel

        return png_uint_32(PNG_INFO_cLLI)
    }
}

/// The light levels as candela per square metre.
///
/// Scaled by 10000 in the file, which is a different scale from the colour chunks'
/// 100000, so the conversion here is not the shared one.
@c @implementation
public func png_get_cLLI(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ maxCLL: UnsafeMutablePointer<Double>?,
    _ maxFALL: UnsafeMutablePointer<Double>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_cLLI) else { return 0 }

        maxCLL?.pointee = Double(info.contentLightLevel.maxContentLightLevel) / 10_000
        maxFALL?.pointee = Double(info.contentLightLevel.maxFrameAverageLightLevel) / 10_000

        return png_uint_32(PNG_INFO_cLLI)
    }
}

@c @implementation
public func png_set_cLLI_fixed(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ maxCLL: png_uint_32,
    _ maxFALL: png_uint_32
) {
    update(info_ptr) { info in
        var value = ContentLightLevel()
        value.maxContentLightLevel = maxCLL
        value.maxFrameAverageLightLevel = maxFALL

        info.contentLightLevel = value
        info.markValid(PNG_INFO_cLLI)
    }
}

@c @implementation
public func png_set_cLLI(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ maxCLL: Double,
    _ maxFALL: Double
) {
    png_set_cLLI_fixed(
        png_ptr, info_ptr,
        png_uint_32((maxCLL * 10_000).rounded()),
        png_uint_32((maxFALL * 10_000).rounded())
    )
}

@c @implementation
public func png_get_mDCV_fixed(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ int_white_x: UnsafeMutablePointer<png_fixed_point>?,
    _ int_white_y: UnsafeMutablePointer<png_fixed_point>?,
    _ int_red_x: UnsafeMutablePointer<png_fixed_point>?,
    _ int_red_y: UnsafeMutablePointer<png_fixed_point>?,
    _ int_green_x: UnsafeMutablePointer<png_fixed_point>?,
    _ int_green_y: UnsafeMutablePointer<png_fixed_point>?,
    _ int_blue_x: UnsafeMutablePointer<png_fixed_point>?,
    _ int_blue_y: UnsafeMutablePointer<png_fixed_point>?,
    _ maxLuminance: png_uint_32p?,
    _ minLuminance: png_uint_32p?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_mDCV) else { return 0 }

        let value = info.masteringDisplay

        // The chunk stores chromaticity scaled by 50000; the published form uses the same
        // 100000 scale as every other colour chunk, so it is twice the stored value.
        int_white_x?.pointee = FixedPoint(value.whiteX) * 2
        int_white_y?.pointee = FixedPoint(value.whiteY) * 2
        int_red_x?.pointee = FixedPoint(value.redX) * 2
        int_red_y?.pointee = FixedPoint(value.redY) * 2
        int_green_x?.pointee = FixedPoint(value.greenX) * 2
        int_green_y?.pointee = FixedPoint(value.greenY) * 2
        int_blue_x?.pointee = FixedPoint(value.blueX) * 2
        int_blue_y?.pointee = FixedPoint(value.blueY) * 2

        maxLuminance?.pointee = value.maxLuminance
        minLuminance?.pointee = value.minLuminance

        return png_uint_32(PNG_INFO_mDCV)
    }
}

/// The mastering display as real numbers.
@c @implementation
public func png_get_mDCV(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_const_inforp?,
    _ white_x: UnsafeMutablePointer<Double>?,
    _ white_y: UnsafeMutablePointer<Double>?,
    _ red_x: UnsafeMutablePointer<Double>?,
    _ red_y: UnsafeMutablePointer<Double>?,
    _ green_x: UnsafeMutablePointer<Double>?,
    _ green_y: UnsafeMutablePointer<Double>?,
    _ blue_x: UnsafeMutablePointer<Double>?,
    _ blue_y: UnsafeMutablePointer<Double>?,
    _ maxLuminance: UnsafeMutablePointer<Double>?,
    _ minLuminance: UnsafeMutablePointer<Double>?
) -> png_uint_32 {
    query(info_ptr, 0) { info in
        guard info.isValid(PNG_INFO_mDCV) else { return 0 }

        let value = info.masteringDisplay

        // Stored scaled by 50000 for the chromaticity and 10000 for the luminance.
        white_x?.pointee = Double(value.whiteX) / 50_000
        white_y?.pointee = Double(value.whiteY) / 50_000
        red_x?.pointee = Double(value.redX) / 50_000
        red_y?.pointee = Double(value.redY) / 50_000
        green_x?.pointee = Double(value.greenX) / 50_000
        green_y?.pointee = Double(value.greenY) / 50_000
        blue_x?.pointee = Double(value.blueX) / 50_000
        blue_y?.pointee = Double(value.blueY) / 50_000

        maxLuminance?.pointee = Double(value.maxLuminance) / 10_000
        minLuminance?.pointee = Double(value.minLuminance) / 10_000

        return png_uint_32(PNG_INFO_mDCV)
    }
}

@c @implementation
public func png_set_mDCV_fixed(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ int_white_x: png_fixed_point,
    _ int_white_y: png_fixed_point,
    _ int_red_x: png_fixed_point,
    _ int_red_y: png_fixed_point,
    _ int_green_x: png_fixed_point,
    _ int_green_y: png_fixed_point,
    _ int_blue_x: png_fixed_point,
    _ int_blue_y: png_fixed_point,
    _ maxLuminance: png_uint_32,
    _ minLuminance: png_uint_32
) {
    update(info_ptr) { info in
        var value = MasteringDisplayColorVolume()

        // Halved back to the scale the chunk stores.
        value.whiteX = UInt16(truncatingIfNeeded: int_white_x / 2)
        value.whiteY = UInt16(truncatingIfNeeded: int_white_y / 2)
        value.redX = UInt16(truncatingIfNeeded: int_red_x / 2)
        value.redY = UInt16(truncatingIfNeeded: int_red_y / 2)
        value.greenX = UInt16(truncatingIfNeeded: int_green_x / 2)
        value.greenY = UInt16(truncatingIfNeeded: int_green_y / 2)
        value.blueX = UInt16(truncatingIfNeeded: int_blue_x / 2)
        value.blueY = UInt16(truncatingIfNeeded: int_blue_y / 2)

        value.maxLuminance = maxLuminance
        value.minLuminance = minLuminance

        info.masteringDisplay = value
        info.markValid(PNG_INFO_mDCV)
    }
}

@c @implementation
public func png_set_mDCV(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ white_x: Double,
    _ white_y: Double,
    _ red_x: Double,
    _ red_y: Double,
    _ green_x: Double,
    _ green_y: Double,
    _ blue_x: Double,
    _ blue_y: Double,
    _ maxLuminance: Double,
    _ minLuminance: Double
) {
    png_set_mDCV_fixed(
        png_ptr, info_ptr,
        unscaled(white_x), unscaled(white_y),
        unscaled(red_x), unscaled(red_y),
        unscaled(green_x), unscaled(green_y),
        unscaled(blue_x), unscaled(blue_y),
        png_uint_32((maxLuminance * 10_000).rounded()),
        png_uint_32((minLuminance * 10_000).rounded())
    )
}
