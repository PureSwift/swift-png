// AsciiNumbers.swift - numbers as the format writes them
//
// One chunk stores its numbers as text: the physical scale, whose values can be anything from a
// wavelength to a distance between stars and so cannot be held in any fixed-point form the rest of the
// format uses.  So it holds decimal strings, and a writer has to produce them.
//
// Which means agreeing on formatting, and formatting is not a detail here.  Two libraries that write
// the same number differently write different files, and a client comparing them would see a
// difference that is not one.  So this is the reference's algorithm rather than anything a formatting
// library would produce: five significant digits, a leading zero omitted, trailing zeros dropped, and
// an exponent used only when it is shorter than writing the digits out.

public enum AsciiNumbers {
    /// The number of significant digits the reference keeps.
    ///
    /// Not a choice: it is what makes "0.3333333" come back as ".33333" rather than as itself, and a
    /// client that round-trips a value through the chunk sees exactly this much of it survive.
    public static let precision = 5

    /// Formats a fixed-point value exactly, as the reference's fixed-point path does.
    ///
    /// Exactly, because there is nothing to lose: the value is already five decimal places and no more,
    /// so writing all of them is both shortest and lossless.  Trailing zeros go, and so does the zero
    /// before the point — "0.5" is written ".5".
    public static func string(fixed value: FixedPoint) -> [UInt8] {
        var digits: [UInt8] = []
        var magnitude = UInt32(value.magnitude)

        if value < 0 {
            digits.append(UInt8(ascii: "-"))
        }

        let whole = magnitude / 100_000
        var fraction = magnitude % 100_000

        if whole > 0 {
            digits += Self.decimal(UInt32(whole))
        }

        guard fraction > 0 else {
            if whole == 0 { digits.append(UInt8(ascii: "0")) }
            return digits
        }

        digits.append(UInt8(ascii: "."))

        // Five places, most significant first, with the run of zeros at the end left off.
        var places: [UInt8] = []

        for _ in 0 ..< 5 {
            places.append(UInt8(ascii: "0") + UInt8(fraction / 10_000))
            fraction = (fraction % 10_000) * 10
        }

        while places.last == UInt8(ascii: "0") {
            places.removeLast()
        }

        magnitude = 0

        return digits + places
    }

    /// Formats a floating-point value the way the reference does.
    ///
    /// The algorithm is its own and is reproduced rather than improved on.  Five significant digits are
    /// taken, rounded; the result is written plainly when the exponent is small enough for that to be
    /// no longer than the exponent form, and as digits with an exponent otherwise.
    public static func string(floating value: Double, precision: Int = AsciiNumbers.precision) -> [UInt8] {
        guard value.isFinite else { return [] }
        guard value != 0 else { return [UInt8(ascii: "0")] }

        var digits: [UInt8] = []
        var magnitude = value

        if magnitude < 0 {
            digits.append(UInt8(ascii: "-"))
            magnitude = -magnitude
        }

        // The decimal exponent, and the digits as an integer of `precision` places.  Taken by scaling
        // rather than by repeated division so that the rounding happens once.
        var exponent = 0

        while magnitude >= 10 {
            magnitude /= 10
            exponent += 1
        }

        while magnitude < 1 {
            magnitude *= 10
            exponent -= 1
        }

        var scaled = Int((magnitude * Self.power(of: precision - 1)).rounded())

        // Rounding can carry into a place that was not there, which moves the point.
        if scaled >= Int(Self.power(of: precision)) {
            scaled /= 10
            exponent += 1
        }

        var significant = Self.decimal(UInt32(scaled))

        while significant.count > 1, significant.last == UInt8(ascii: "0") {
            significant.removeLast()
        }

        // Plainly or with an exponent, whichever is shorter — and plainly when they tie, which is what
        // makes a whole number look like one.
        let plain = Self.plain(significant, exponent: exponent)
        let scientific = Self.scientific(significant, exponent: exponent)

        return digits + (plain.count <= scientific.count ? plain : scientific)
    }

    /// The digits written out, with the point where the exponent puts it.
    private static func plain(_ significant: [UInt8], exponent: Int) -> [UInt8] {
        // The point sits after this many digits.
        let pointAt = exponent + 1

        if pointAt <= 0 {
            // Smaller than one: a point, then the zeros the exponent calls for, then the digits.  The
            // zero before the point is left off, which is the reference's spelling.
            return [UInt8(ascii: ".")]
                + [UInt8](repeating: UInt8(ascii: "0"), count: -pointAt)
                + significant
        }

        if pointAt >= significant.count {
            // A whole number, with whatever zeros the exponent calls for after the digits.
            return significant
                + [UInt8](repeating: UInt8(ascii: "0"), count: pointAt - significant.count)
        }

        return Array(significant[0 ..< pointAt]) + [UInt8(ascii: ".")]
            + Array(significant[pointAt...])
    }

    /// The digits with an exponent after them.
    ///
    /// The exponent is counted from the last digit rather than the first: the digits are written as a
    /// whole number and the exponent says where the point goes relative to its end, so five digits and
    /// a value of a ten-thousandth is "12346E-8" rather than "1.2346E-4".  That is the reference's
    /// spelling, and it is also the shorter one, since it needs no point.
    private static func scientific(_ significant: [UInt8], exponent: Int) -> [UInt8] {
        var result = significant
        let scaled = exponent - (significant.count - 1)

        result.append(UInt8(ascii: "E"))

        if scaled < 0 {
            result.append(UInt8(ascii: "-"))
        }

        return result + Self.decimal(UInt32(abs(scaled)))
    }

    private static func power(of exponent: Int) -> Double {
        var result = 1.0

        for _ in 0 ..< exponent {
            result *= 10
        }

        return result
    }

    /// An unsigned value as its decimal digits.
    public static func decimal(_ value: UInt32) -> [UInt8] {
        guard value > 0 else { return [UInt8(ascii: "0")] }

        var digits: [UInt8] = []
        var remaining = value

        while remaining > 0 {
            digits.append(UInt8(ascii: "0") + UInt8(remaining % 10))
            remaining /= 10
        }

        return digits.reversed()
    }

    /// Whether a string is one of these at all.
    ///
    /// The format's own syntax, which is narrower than what most number parsers accept and narrower
    /// than what this file's reader accepts: no space either side, nothing after the number, and no
    /// minus sign — a scale is a length and a negative length is not a value the chunk can hold.  A
    /// leading plus is allowed, which looks inconsistent and is what the reference accepts.
    ///
    /// Checked rather than parsed because the string is stored as the client gave it: what a client
    /// writes is what the file carries, so the only question is whether it may.
    public static func isValid(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var index = 0

        func digit() -> Bool {
            guard index < bytes.count else { return false }

            return bytes[index] >= UInt8(ascii: "0") && bytes[index] <= UInt8(ascii: "9")
        }

        if index < bytes.count, bytes[index] == UInt8(ascii: "+") { index += 1 }

        var sawDigit = false

        while digit() { index += 1; sawDigit = true }

        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1

            while digit() { index += 1; sawDigit = true }
        }

        guard sawDigit else { return false }

        if index < bytes.count,
           bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1

            if index < bytes.count,
               bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }

            var sawExponentDigit = false

            while digit() { index += 1; sawExponentDigit = true }

            guard sawExponentDigit else { return false }
        }

        // Nothing may follow: a string that begins with a number and goes on to say something else is
        // not a number that happens to have a comment.
        return index == bytes.count
    }

    /// The same for a terminated string, which is how the API hands them over.
    public static func isValid(terminated bytes: UnsafePointer<CChar>) -> Bool {
        var length = 0

        while bytes[length] != 0 { length += 1 }

        return bytes.withMemoryRebound(to: UInt8.self, capacity: length) {
            Self.isValid(UnsafeBufferPointer(start: $0, count: length))
        }
    }

    /// Reads one of these back, for the accessors that hand a client a number rather than a string.
    ///
    /// Deliberately forgiving about the forms it accepts, since what it is reading is whatever some
    /// other encoder wrote: a leading zero or not, an exponent or not, either case of the exponent
    /// letter.  It is strict about one thing only — a string that is not a number at all is refused
    /// rather than read as zero.
    public static func number(from bytes: UnsafeBufferPointer<UInt8>) -> Double? {
        var index = 0
        var sign = 1.0
        var value = 0.0
        var sawDigit = false

        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

        if peek() == UInt8(ascii: "-") { sign = -1; index += 1 }
        else if peek() == UInt8(ascii: "+") { index += 1 }

        while let byte = peek(), byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
            value = value * 10 + Double(byte - UInt8(ascii: "0"))
            sawDigit = true
            index += 1
        }

        if peek() == UInt8(ascii: ".") {
            index += 1
            var place = 0.1

            while let byte = peek(), byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                value += Double(byte - UInt8(ascii: "0")) * place
                place /= 10
                sawDigit = true
                index += 1
            }
        }

        guard sawDigit else { return nil }

        if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
            index += 1
            var exponentSign = 1
            var exponent = 0
            var sawExponentDigit = false

            if peek() == UInt8(ascii: "-") { exponentSign = -1; index += 1 }
            else if peek() == UInt8(ascii: "+") { index += 1 }

            while let byte = peek(), byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                exponent = exponent * 10 + Int(byte - UInt8(ascii: "0"))
                sawExponentDigit = true
                index += 1
            }

            guard sawExponentDigit else { return nil }

            for _ in 0 ..< exponent {
                value = exponentSign < 0 ? value / 10 : value * 10
            }
        }

        return sign * value
    }
}
