// HeaderProblems.swift - what can be wrong with an image header
//
// A bad IHDR is not reported as one failure.  Every problem found is reported as
// its own warning, and only then does the parse fail, with a single generic
// message.  A client that installed a warning handler therefore learns exactly what
// was wrong, which is more use than the error alone; this reproduces that.
//
// The problems are collected in a set rather than thrown one at a time because a
// header can be wrong in several ways at once, and all of them are reported. The set
// is a plain integer, so gathering it allocates nothing and there is nothing to
// abandon if a client jumps out of its warning handler part way through.

extension Header {
    /// Everything wrong with a header, gathered before any of it is reported.
    public struct Problems: OptionSet, Sendable {
        public let rawValue: UInt16

        public init(rawValue: UInt16) {
            self.rawValue = rawValue
        }

        public static let zeroWidth = Self(rawValue: 1 << 0)
        public static let zeroHeight = Self(rawValue: 1 << 1)
        public static let oversized = Self(rawValue: 1 << 2)
        public static let badBitDepth = Self(rawValue: 1 << 3)
        public static let badColorType = Self(rawValue: 1 << 4)
        public static let badCombination = Self(rawValue: 1 << 5)
        public static let badCompressionMethod = Self(rawValue: 1 << 6)
        public static let badFilterMethod = Self(rawValue: 1 << 7)
        public static let badInterlaceMethod = Self(rawValue: 1 << 8)

        /// Reports each problem as its own warning.
        ///
        /// The order is fixed, because a client that logs these sees them in it.
        ///
        /// Nothing is owned across a call here: a client may jump out of its warning
        /// handler at any of them, and the caller has already gathered everything it
        /// needs into this value.
        func report(to host: Host) {
            if self.contains(.zeroWidth) {
                host.warn("Image width is zero in IHDR")
            }
            if self.contains(.zeroHeight) {
                host.warn("Image height is zero in IHDR")
            }
            if self.contains(.oversized) {
                host.warn("Invalid image size in IHDR")
            }
            if self.contains(.badBitDepth) {
                host.warn("Invalid bit depth in IHDR")
            }
            if self.contains(.badColorType) {
                host.warn("Invalid color type in IHDR")
            }
            if self.contains(.badCombination) {
                host.warn("Invalid color type/bit depth combination in IHDR")
            }
            if self.contains(.badCompressionMethod) {
                host.warn("Unknown compression method in IHDR")
            }
            if self.contains(.badFilterMethod) {
                // Two warnings for the one fault, matching the reference, which
                // checks the field twice on the way through.
                host.warn("Unknown filter method in IHDR")
                host.warn("Invalid filter method in IHDR")
            }
            if self.contains(.badInterlaceMethod) {
                host.warn("Unknown interlace method in IHDR")
            }
        }
    }
}
