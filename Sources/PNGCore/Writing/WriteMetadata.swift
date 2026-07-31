// WriteMetadata.swift - the chunks either side of the image data
//
// What the file says about itself: how it was encoded, what it should be shown against, where it came
// from.  None of it is needed to decode the pixels, and all of it changes what the pixels mean.
//
// The order is not free.  Some chunks refer into the palette and are meaningless before it; some
// describe the image data and are meaningless after it.  The format sets out which is which, and this
// file is arranged in that order rather than in any order that would read more tidily — a writer that
// emitted them in a convenient order would produce files that decoders are entitled to reject.
//
// Only what the client actually set is written.  The validity bits say which that is, and they are the
// same bits `png_get_valid` reports, so what comes out is exactly what a client would be told is there.

extension SequentialWriter {
    /// The chunks that must precede the palette.
    ///
    /// These describe the colour the palette entries are in, so a decoder needs them before it has
    /// entries to interpret.
    func writeBeforePalette(_ info: InfoStore, context: PngContext) throws {
        if info.isValid(InfoStore.Valid.gama) {
            try self.writeFixed(.gama, info.gamma, context: context)
        }

        if info.isValid(InfoStore.Valid.chrm) {
            try self.write(.chrm, context: context, count: 32) { bytes in
                let c = info.chromaticity

                Self.put32(bytes, 0, UInt32(bitPattern: c.whiteX))
                Self.put32(bytes, 4, UInt32(bitPattern: c.whiteY))
                Self.put32(bytes, 8, UInt32(bitPattern: c.redX))
                Self.put32(bytes, 12, UInt32(bitPattern: c.redY))
                Self.put32(bytes, 16, UInt32(bitPattern: c.greenX))
                Self.put32(bytes, 20, UInt32(bitPattern: c.greenY))
                Self.put32(bytes, 24, UInt32(bitPattern: c.blueX))
                Self.put32(bytes, 28, UInt32(bitPattern: c.blueY))
            }
        }

        if info.isValid(InfoStore.Valid.srgb) {
            try self.write(.srgb, context: context, count: 1) { bytes in
                bytes[0] = info.srgbIntent
            }
        }

        // The colour profile, which is compressed and can be large — the one chunk before the palette
        // that is not a handful of numbers.
        if info.isValid(InfoStore.Valid.iccp) {
            try self.writeProfile(info, context: context)
        }

        if info.isValid(InfoStore.Valid.sbit), let header = context.header {
            // One byte per channel the image actually has, which is what makes this chunk's length
            // depend on the colour type rather than being fixed.
            let bits = info.significantBits
            var values: [UInt8] = []

            if header.colorType.hasColor || header.colorType.isIndexed {
                values += [bits.red, bits.green, bits.blue]
            } else {
                values.append(bits.gray)
            }

            if header.colorType.hasAlpha {
                values.append(bits.alpha)
            }

            try self.write(.sbit, context: context, count: values.count) { bytes in
                for index in values.indices {
                    bytes[index] = values[index]
                }
            }
        }
    }

    /// The chunks that must follow the palette and precede the image data.
    func writeAfterPalette(_ info: InfoStore, context: PngContext) throws {
        guard let header = context.header else { return }

        // Transparency, which for an indexed image is one alpha per entry and for the others is the
        // single colour that is to be seen through.
        if info.isValid(InfoStore.Valid.trns) {
            if header.colorType.isIndexed {
                let alphas = info.transparentAlpha.elements
                let count = min(alphas.count, info.transparentCount)

                if count > 0 {
                    try self.write(.trns, context: context, count: count) { bytes in
                        for index in 0 ..< count {
                            bytes[index] = alphas[index]
                        }
                    }
                }
            } else if header.colorType.hasColor {
                try self.write(.trns, context: context, count: 6) { bytes in
                    Self.put16(bytes, 0, info.transparentColor.red)
                    Self.put16(bytes, 2, info.transparentColor.green)
                    Self.put16(bytes, 4, info.transparentColor.blue)
                }
            } else {
                try self.write(.trns, context: context, count: 2) { bytes in
                    Self.put16(bytes, 0, info.transparentColor.gray)
                }
            }
        }

        if info.isValid(InfoStore.Valid.bkgd) {
            // Three forms, chosen by what the image is: an index into the palette, one grey, or a
            // colour.  The same structure carries all three, so the colour type decides which of its
            // fields mean anything.
            if header.colorType.isIndexed {
                try self.write(.bkgd, context: context, count: 1) { bytes in
                    bytes[0] = info.background.index
                }
            } else if header.colorType.hasColor {
                try self.write(.bkgd, context: context, count: 6) { bytes in
                    Self.put16(bytes, 0, info.background.red)
                    Self.put16(bytes, 2, info.background.green)
                    Self.put16(bytes, 4, info.background.blue)
                }
            } else {
                try self.write(.bkgd, context: context, count: 2) { bytes in
                    Self.put16(bytes, 0, info.background.gray)
                }
            }
        }

        if info.isValid(InfoStore.Valid.hist) {
            let entries = info.histogram.elements

            if entries.count > 0 {
                try self.write(.hist, context: context, count: entries.count * 2) { bytes in
                    for index in 0 ..< entries.count {
                        Self.put16(bytes, index * 2, entries[index])
                    }
                }
            }
        }

        if info.isValid(InfoStore.Valid.phys) {
            try self.write(.phys, context: context, count: 9) { bytes in
                Self.put32(bytes, 0, info.physicalDimensions.pixelsPerUnitX)
                Self.put32(bytes, 4, info.physicalDimensions.pixelsPerUnitY)
                bytes[8] = info.physicalDimensions.unit
            }
        }

        if info.isValid(InfoStore.Valid.offs) {
            try self.write(.offs, context: context, count: 9) { bytes in
                Self.put32(bytes, 0, UInt32(bitPattern: info.offset.x))
                Self.put32(bytes, 4, UInt32(bitPattern: info.offset.y))
                bytes[8] = info.offset.unit
            }
        }

        // The scale, whose numbers are text: a width, a terminator, and a height that is not
        // terminated because the chunk's length says where it ends.
        if info.isValid(InfoStore.Valid.scal) {
            let width = info.scale.width.bytes
            let height = info.scale.height.bytes

            if width.count > 0, height.count > 0 {
                try self.write(
                    .scal,
                    context: context,
                    count: 1 + width.count + 1 + height.count
                ) { bytes in
                    bytes[0] = info.scale.unit
                    Self.copy(width, into: bytes, at: 1)
                    bytes[1 + width.count] = 0
                    Self.copy(height, into: bytes, at: 2 + width.count)
                }
            }
        }

        if info.isValid(InfoStore.Valid.time) {
            try self.writeTime(info, context: context)
        }

        if info.isValid(InfoStore.Valid.exif) {
            let bytes = info.exif.elements

            if bytes.count > 0 {
                try self.write(.exif, context: context, count: bytes.count) { destination in
                    for index in 0 ..< bytes.count {
                        destination[index] = bytes[index]
                    }
                }
            }
        }
    }

    /// The colour profile: a name, a compression method, and the profile itself deflated.
    private func writeProfile(_ info: InfoStore, context: PngContext) throws {
        let name = info.profileName.bytes
        let profile = info.profile.elements

        guard name.count >= 1, name.count <= 79, profile.count > 0 else { return }

        let compressed = try self.compressed(
            UnsafeBufferPointer(start: profile.baseAddress, count: profile.count),
            context: context
        )

        defer { compressed.buffer.deallocate(host: context.host) }

        let body = UnsafeBufferPointer(
            start: compressed.buffer.bytes.baseAddress,
            count: compressed.count
        )

        try self.write(
            .iccp,
            context: context,
            count: name.count + 2 + compressed.count
        ) { bytes in
            Self.copy(name, into: bytes, at: 0)
            bytes[name.count] = 0
            bytes[name.count + 1] = info.profileCompression
            Self.copy(body, into: bytes, at: name.count + 2)
        }
    }

    /// The timestamp, whose fields are the one place the format uses a two byte year.
    private func writeTime(_ info: InfoStore, context: PngContext) throws {
        try self.write(.time, context: context, count: 7) { bytes in
            Self.put16(bytes, 0, info.timestamp.year)
            bytes[2] = info.timestamp.month
            bytes[3] = info.timestamp.day
            bytes[4] = info.timestamp.hour
            bytes[5] = info.timestamp.minute
            bytes[6] = info.timestamp.second
        }
    }

    /// A chunk whose only content is one fixed-point number.
    private func writeFixed(
        _ name: ChunkName,
        _ value: FixedPoint,
        context: PngContext
    ) throws {
        try self.write(name, context: context, count: 4) { bytes in
            Self.put32(bytes, 0, UInt32(bitPattern: value))
        }
    }

    /// Builds a chunk's contents in the context's scratch buffer and writes it.
    ///
    /// The buffer is the context's rather than a fresh one for the reason every buffer here is: the
    /// write goes through the client's callback, and a client may jump out of it.
    func write(
        _ name: ChunkName,
        context: PngContext,
        count: Int,
        fill: (UnsafeMutableBufferPointer<UInt8>) -> Void
    ) throws {
        guard count > 0 else { return }

        try context.reserve(\.scratch, count)

        let bytes = UnsafeMutableBufferPointer(
            start: context.scratch.bytes.baseAddress,
            count: count
        )

        fill(bytes)

        var writer = context.chunkWriter
        writer.write(name, UnsafeBufferPointer(bytes))
    }

    static func put16(_ bytes: UnsafeMutableBufferPointer<UInt8>, _ offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
    }
}
