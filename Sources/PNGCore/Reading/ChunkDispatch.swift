// ChunkDispatch.swift - deciding what to do with each chunk
//
// The reader walks the chunk structure; this decides what each one means.  It is
// separate from the walk because the two answer different questions, and because the
// same dispatch serves the chunks before the image data and the chunks after it.
//
// A malformed optional chunk is not a malformed file.  The whole point of an ancillary
// chunk is that a decoder may ignore it, so one that cannot be parsed is reported and
// dropped, and the image still decodes.  That is a deliberate asymmetry with the
// critical chunks, where a fault is fatal.

extension SequentialReader {
    /// Whether a chunk is one this library understands.
    static func isRecognised(_ name: ChunkName) -> Bool {
        switch name {
        case .ihdr, .plte, .idat, .iend,
             .trns, .gama, .chrm, .srgb, .iccp, .sbit, .bkgd, .hist,
             .cicp, .clli, .mdcv,
             .text, .ztxt, .itxt,
             .phys, .offs, .scal, .time, .exif,
             .pcal, .splt:
            return true
        default:
            return false
        }
    }

    /// Parses a recognised optional chunk from a payload already read into memory.
    ///
    /// Throws only for a fault the caller should treat as fatal. A fault in the chunk's
    /// own contents is reported as a warning and the chunk dropped, since a decoder is
    /// entitled to ignore any of these.
    func parseOptional(
        _ name: ChunkName,
        payload: UnsafeBufferPointer<UInt8>,
        info: InfoStore,
        host: Host
    ) throws {
        do {
            switch name {
            case .plte: try info.parsePalette(payload)
            case .trns: try info.parseTransparency(payload)
            case .bkgd: try info.parseBackground(payload)
            case .hist: try info.parseHistogram(payload)

            case .gama: try info.parseGamma(payload)
            case .chrm: try info.parseChromaticity(payload)
            case .srgb: try info.parseSrgb(payload)
            case .sbit: try info.parseSignificantBits(payload)
            case .iccp: try info.parseColorProfile(payload)

            case .cicp: try info.parseCodePoints(payload)
            case .clli: try info.parseContentLightLevel(payload)
            case .mdcv: try info.parseMasteringDisplay(payload)

            case .phys: try info.parsePhysicalDimensions(payload)
            case .offs: try info.parseOffset(payload)
            case .scal: try info.parseScale(payload)
            case .time: try info.parseTimestamp(payload)
            case .exif: try info.parseExif(payload)

            case .pcal: try info.parseCalibration(payload)
            case .splt: try info.parseSuggestedPalette(payload)

            case .text: try info.parseText(payload)
            case .ztxt: try info.parseCompressedText(payload)
            case .itxt: try info.parseInternationalText(payload)

            default:
                break
            }
        } catch let diagnostic as Diagnostic {
            // The palette is the exception: an indexed image cannot be decoded without
            // one, so a bad palette is fatal where a bad anything-else is not.
            if name == .plte, let header = info.header, header.colorType.isIndexed {
                throw diagnostic
            }

            host.warn(diagnostic)
        }
    }
}
