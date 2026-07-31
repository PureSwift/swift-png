// QuantizeAPI.swift - asking for the image in fewer colours than it has
//
// The one request in the reading API that does its work when it is made rather than when the rows are
// read.  A client passes in the palette its display can manage, and when the call returns that array
// has been rewritten: the colours it should now use are the first `maximum_colors` of it.
//
// Which is why the array is not const, and why nothing is copied out of it here.  The client owns it,
// the client will read it, and what this leaves behind is a pair of tables that say how a row is to be
// renumbered or how a colour is to find its entry.

import CPNG
import PNGCore

/// Fits the image into `maximum_colors` colours, and says how.
///
/// `histogram` is the file's own count of how often each palette entry appears, which decides what to
/// lose when the palette is longer than the display can take; without it the choice is made by finding
/// the colours nearest each other.  Either way the palette is shortened in place.
///
/// `full_quantize` says which of the two jobs is wanted.  Set, an image of colours is fitted to the
/// palette through a table over the top bits of each channel — the whole reduction.  Clear, only the
/// renumbering of rows that are already indices is prepared, which is all an indexed image needs.
@c @implementation
public func png_set_quantize(
    _ png_ptr: png_structrp?,
    _ palette: png_colorp?,
    _ num_palette: Int32,
    _ maximum_colors: Int32,
    _ histogram: png_const_uint_16p?,
    _ full_quantize: Int32
) {
    guard let png_ptr, let context = PngContext.from(png_ptr) else { return }

    let count = Int(num_palette)
    let maximum = Int(maximum_colors)

    guard count > 0, maximum > 0, let palette else { return }

    context.transformFlags.insert(.quantize)

    var tables = Quantization()

    palette.withMemoryRebound(to: Rgb8.self, capacity: count) { entries in
        let buffer = UnsafeMutableBufferPointer(start: entries, count: count)

        let indexMap: [UInt8]?

        if let histogram {
            indexMap = histogram.withMemoryRebound(to: UInt16.self, capacity: count) { counts in
                Quantize.reduce(
                    palette: buffer,
                    count: count,
                    maximum: maximum,
                    histogram: UnsafeBufferPointer(start: counts, count: count),
                    fullQuantize: full_quantize != 0
                )
            }
        } else {
            indexMap = Quantize.reduce(
                palette: buffer,
                count: count,
                maximum: maximum,
                histogram: nil,
                fullQuantize: full_quantize != 0
            )
        }

        if let indexMap {
            tables.indexMap = indexMap
        }

        // Built from the shortened palette, over however many entries survived — which is the whole
        // palette when it was already short enough.
        if full_quantize != 0 {
            tables.lookup = Quantize.lookup(
                palette: UnsafeBufferPointer(buffer),
                count: min(count, maximum)
            )
        }
    }

    context.quantization = tables

    // What the rows may now name, which is fewer entries than the file's own chunk describes.  A row
    // naming one of the entries that went is a row past the end of the palette the client is working
    // with, and is reported as such even though the file was never at fault.
    context.entitledPaletteCount = min(count, maximum)
}
