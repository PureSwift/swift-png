// TimeAPI.swift - the one field a file holds as a moment
//
// The timestamp chunk holds broken-down time, and a client usually has something else: a `time_t`, or
// the structure the C library breaks one into.  These convert between them, and one more turns the
// chunk's fields into the line a mail header would carry.
//
// The last of those is where the care is.  The fields come out of a file and a file can say anything,
// so every one of them is checked before it is used — a month of thirteen is not a month, and printing
// it as one would be inventing a date the file did not contain.

import CPNG
import PNGCore

/// The month names the header form uses, which are English and fixed.
///
/// Fixed because the format is: a date written for a machine to parse is not a date to translate.
private let monthNames: [StaticString] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

/// Writes the timestamp into a caller's buffer, which must hold at least 29 bytes.
///
/// Returns zero for a timestamp that is not a date.  The buffer is left alone in that case rather than
/// filled with something plausible: a client that ignores the result should not find a date there.
@c @implementation
public func png_convert_to_rfc1123_buffer(
    _ out: UnsafeMutablePointer<CChar>?,
    _ ptime: png_const_timep?
) -> Int32 {
    guard let out, let ptime else { return 0 }

    let time = ptime.pointee

    guard time.month >= 1, time.month <= 12,
          time.day >= 1, time.day <= 31,
          time.hour <= 23,
          time.minute <= 59,
          // Sixty is a second a minute can have: the day is occasionally lengthened by one.
          time.second <= 60 else {
        return 0
    }

    var text: [UInt8] = []

    text += AsciiNumbers.decimal(UInt32(time.day))
    text.append(UInt8(ascii: " "))

    let month = monthNames[Int(time.month) - 1]

    for index in 0 ..< month.utf8CodeUnitCount {
        text.append(month.utf8Start[index])
    }

    text.append(UInt8(ascii: " "))
    text += AsciiNumbers.decimal(UInt32(time.year))
    text.append(UInt8(ascii: " "))
    text += Digits.twoDigits(time.hour)
    text.append(UInt8(ascii: ":"))
    text += Digits.twoDigits(time.minute)
    text.append(UInt8(ascii: ":"))
    text += Digits.twoDigits(time.second)

    // The offset from universal time, which is always none: the chunk holds universal time and says so
    // rather than leaving a reader to guess.
    for byte in " +0000".utf8 {
        text.append(byte)
    }

    text.append(0)

    for index in text.indices {
        out[index] = CChar(bitPattern: text[index])
    }

    return 1
}

/// Fills in the fields from what the C library broke a moment into.
///
/// The two disagree about how to count in two places, and both are here: a year counted from 1900, and
/// a month counted from zero.
@c @implementation
public func png_convert_from_struct_tm(_ ptime: png_timep?, _ ttime: UnsafePointer<tm>?) {
    guard let ptime, let ttime else { return }

    ptime.pointee.year = png_uint_16(1900 + ttime.pointee.tm_year)
    ptime.pointee.month = png_byte(ttime.pointee.tm_mon + 1)
    ptime.pointee.day = png_byte(ttime.pointee.tm_mday)
    ptime.pointee.hour = png_byte(ttime.pointee.tm_hour)
    ptime.pointee.minute = png_byte(ttime.pointee.tm_min)
    ptime.pointee.second = png_byte(ttime.pointee.tm_sec)
}

/// The same from a moment the C library has not broken down yet.
///
/// Broken down as universal time rather than local, which is not a detail: the chunk is defined to
/// hold universal time, and filling it from a local clock would record a moment that never happened.
@c @implementation
public func png_convert_from_time_t(_ ptime: png_timep?, _ ttime: time_t) {
    guard let ptime else { return }

    var moment = ttime
    var broken = tm()

    gmtime_r(&moment, &broken)

    withUnsafePointer(to: &broken) {
        png_convert_from_struct_tm(ptime, $0)
    }
}

/// The header form, written into a buffer the structure owns.
///
/// Deprecated in the API it comes from, and for a reason worth repeating: what it returns points into
/// the control structure, so a client that calls it twice has the first answer overwritten under it.
@c @implementation
public func png_convert_to_rfc1123(
    _ png_ptr: png_structrp?,
    _ ptime: png_const_timep?
) -> png_const_charp? {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return nil }

    guard let text = try? context.timestampBuffer() else { return nil }

    return png_convert_to_rfc1123_buffer(text, ptime) != 0 ? png_const_charp(text) : nil
}

private enum Digits {
    /// Two digits, with a leading zero where a number would have none.
    static func twoDigits(_ value: png_byte) -> [UInt8] {
        [UInt8(ascii: "0") + value / 10, UInt8(ascii: "0") + value % 10]
    }
}
