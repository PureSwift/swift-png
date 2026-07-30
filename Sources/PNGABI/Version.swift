// Version.swift - the version strings the published API hands out
//
// The accessors return pointers the client may hold indefinitely, so the storage
// has to outlive any call and never move.  Each string is built once into memory
// that is never released, which is what makes handing out the raw pointer safe.

import CPNG

enum Version {
    /// The version these strings report comes from the vendored png.h, so the
    /// header and the library cannot disagree about it.
    ///
    /// The pointers address memory that is written once during initialisation and
    /// never mutated or freed, so sharing them across threads is safe; the
    /// compiler cannot see that through a raw pointer, hence the annotation.
    nonisolated(unsafe) static let string: png_const_charp = immortal(
        PNG_LIBPNG_VER_STRING
    )

    /// What `png_get_header_version` reports.
    ///
    /// This is not the same as png.h's `PNG_HEADER_VERSION_STRING`: the reference
    /// build appends a further newline to it, so the returned text ends in a
    /// blank line.  The macro itself cannot be imported anyway, since it is
    /// spelled as an adjacent-literal concatenation, so both the text and the
    /// extra newline are reproduced here.
    nonisolated(unsafe) static let headerVersion: png_const_charp = immortal(
        " libpng version \(PNG_LIBPNG_VER_STRING)\n\n"
    )

    /// Byte-for-byte what the reference build reports, including the leading
    /// newline, because some programs print this verbatim.
    nonisolated(unsafe) static let copyright: png_const_charp = immortal(
        """

        libpng version \(PNG_LIBPNG_VER_STRING)
        Copyright (c) 2018-2026 Cosmin Truta
        Copyright (c) 1998-2002,2004,2006-2018 Glenn Randers-Pehrson
        Copyright (c) 1996-1997 Andreas Dilger
        Copyright (c) 1995-1996 Guy Eric Schalnat, Group 42, Inc.

        """
    )

    /// Copies `text` into memory that is never released, so the returned pointer
    /// stays valid for the lifetime of the process.
    private static func immortal(_ text: String) -> png_const_charp {
        let bytes = Array(text.utf8)
        let storage = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)

        for (index, byte) in bytes.enumerated() {
            storage[index] = CChar(bitPattern: byte)
        }
        storage[bytes.count] = 0

        return png_const_charp(storage)
    }
}
