// TextAPI.swift - reading and writing the text entries
//
// All three text chunks are reported through one array, with a field on each entry saying
// which kind it came from.  The array is built in the published structure's layout, in
// storage the info structure owns, because a client holds the pointer for as long as that
// structure lives.
//
// The strings themselves are not copied into that array; the entries point at the storage
// the parser already put them in.  So rebuilding the array on a second call is harmless,
// while moving the strings would not be.

import CPNG
import PNG

/// Reports the text entries as an array in the published layout.
///
/// Returns how many there are, which is what a client loops over. The array pointer is
/// optional: a client that only wants the count passes null.
@c @implementation
public func png_get_text(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ text_ptr: UnsafeMutablePointer<png_textp?>?,
    _ num_text: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard let info_ptr, let info = InfoStore.from(info_ptr) else { return 0 }

    let count = info.textEntries.count

    num_text?.pointee = Int32(count)

    guard count > 0 else {
        text_ptr?.pointee = nil
        return 0
    }

    guard let table = try? info.reserveExportTable(
        .text,
        byteCount: count * MemoryLayout<png_text>.stride
    ) else {
        return 0
    }

    let entries = table.assumingMemoryBound(to: png_text.self)

    for index in 0 ..< count {
        let entry = info.textEntries[index]

        entries[index].compression = entry.compression
        entries[index].key = entry.keyword.address
        entries[index].text = entry.text.address
        entries[index].lang = entry.language.isEmpty ? nil : entry.language.address
        entries[index].lang_key = entry.translatedKeyword.isEmpty
            ? nil
            : entry.translatedKeyword.address

        // The two lengths are not both filled.  An entry from one of the older chunks
        // reports its length in the first; one from the international chunk reports it in
        // the second, and leaves the first at zero.
        if entry.compression >= 1 {
            entries[index].text_length = 0
            entries[index].itxt_length = entry.text.count
        } else {
            entries[index].text_length = entry.text.count
            entries[index].itxt_length = 0
        }
    }

    text_ptr?.pointee = entries

    return Int32(count)
}

/// Adds text entries, copying everything the client passed.
///
/// Appends rather than replaces, because this is how a client builds up the text of an image
/// it is about to write, often one call at a time.
@c @implementation
public func png_set_text(
    _ png_ptr: png_const_structrp?,
    _ info_ptr: png_inforp?,
    _ text_ptr: png_const_textp?,
    _ num_text: Int32
) {
    guard let info_ptr, let info = InfoStore.from(info_ptr) else { return }
    guard let text_ptr, num_text > 0 else { return }

    do {
        for index in 0 ..< Int(num_text) {
            let source = text_ptr[index]

            // A keyword is what identifies the entry, so an entry without one is not
            // storable; the format also fixes its length.
            guard let key = source.key else {
                throw Diagnostic("text has no keyword")
            }

            var entry = TextEntry()
            entry.compression = source.compression

            do {
                entry.keyword = try TextStorage.copying(key, host: info.host)

                guard entry.keyword.count >= 1, entry.keyword.count <= 79 else {
                    throw Diagnostic("invalid keyword")
                }

                // An absent value is stored as the empty string rather than refused: a
                // keyword with nothing under it is a legitimate thing to write.
                entry.text = try TextStorage.copying(source.text, host: info.host)

                if source.compression >= 1 {
                    entry.language = try TextStorage.copying(source.lang, host: info.host)
                    entry.translatedKeyword = try TextStorage.copying(
                        source.lang_key,
                        host: info.host
                    )
                }
            } catch {
                entry.deallocate(host: info.host)
                throw error
            }

            try info.appendText(entry)
        }
    } catch let diagnostic as Diagnostic {
        guard let png_ptr else { return }
        report(diagnostic, to: png_structp(mutating: png_ptr))
    } catch {
        guard let png_ptr else { return }
        spng_c_error(png_structp(mutating: png_ptr), "out of memory")
    }
}
