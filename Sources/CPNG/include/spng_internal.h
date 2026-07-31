/* spng_internal.h - the internal C surface shared by the shim and Swift
 *
 * This is the umbrella header of the CPNG clang module, so importing CPNG from
 * Swift yields the public libpng API, the completed control structures, and the
 * two families of internal entry points declared below.
 *
 * Naming:
 *   spng_c_*      implemented in C, called from Swift
 *   spng_swift_*  implemented in Swift with @c, called from C
 *
 * None of these are exported from the finished library; the link-time export
 * list keeps the dynamic symbol table to the published libpng API.
 */

#ifndef SPNG_INTERNAL_H
#define SPNG_INTERNAL_H

#include "png.h"
#include "pngstruct_abi.h"

#ifdef __cplusplus
extern "C" {
#endif

/* -- Error dispatch -------------------------------------------------------
 *
 * The engine never longjmps.  Swift code reports failure by throwing, and the
 * exported entry point calls spng_c_error as the last action in its frame; the
 * dispatcher runs the client's handler and then jumps.  spng_c_error never
 * returns.
 */
PNG_NORETURN void spng_c_error(png_const_structrp png_ptr,
    png_const_charp message);
void spng_c_warning(png_const_structrp png_ptr, png_const_charp message);

/* Takes a length because the engine's messages come from Swift string literals,
 * whose null termination is an implementation detail rather than a guarantee.
 */
void spng_c_warning_bytes(png_const_structrp png_ptr, const char *message,
    size_t length);

/* As above, prefixed with a chunk type given as its four bytes packed big-endian.
 * Packed rather than passed as a string because the engine holds it that way.
 */
void spng_c_warning_chunk_bytes(png_const_structrp png_ptr, const char *message,
    size_t length, png_uint_32 packed_name);

/* Reported as an error or a warning depending on png_set_benign_errors. */
void spng_c_benign_error(png_const_structrp png_ptr, png_const_charp message);

/* Formats "<chunk>: <message>" into png_ptr->message and dispatches, matching
 * the reference implementation's chunk diagnostics.
 */
PNG_NORETURN void spng_c_chunk_error(png_const_structrp png_ptr,
    png_const_charp chunk_name, png_const_charp message);
void spng_c_chunk_warning(png_const_structrp png_ptr,
    png_const_charp chunk_name, png_const_charp message);

/* -- Memory --------------------------------------------------------------
 *
 * Every allocation whose pointer can reach the client, and every large row or
 * image buffer, goes through these so that png_set_mem_fn is honoured and
 * png_free works on anything we hand out.
 */
png_voidp spng_c_malloc(png_const_structrp png_ptr, png_alloc_size_t size);
png_voidp spng_c_malloc_warn(png_const_structrp png_ptr, png_alloc_size_t size);
void spng_c_free(png_const_structrp png_ptr, png_voidp ptr);

/* -- Callback trampolines -------------------------------------------------
 *
 * Client code runs only from these.  A client is allowed to longjmp out of any
 * of them, so callers must have committed all state they still need to
 * context-owned storage, and must hold no Swift-managed temporaries.
 */
void spng_c_call_read(png_structrp png_ptr, png_bytep data, size_t length);
void spng_c_call_write(png_structrp png_ptr, png_bytep data, size_t length);
void spng_c_call_flush(png_structrp png_ptr);
void spng_c_call_read_row_status(png_structrp png_ptr, png_uint_32 row,
    int pass);
void spng_c_call_write_row_status(png_structrp png_ptr, png_uint_32 row,
    int pass);
void spng_c_call_progressive_info(png_structrp png_ptr, png_inforp info_ptr);
void spng_c_call_progressive_row(png_structrp png_ptr, png_bytep new_row,
    png_uint_32 row_number, int pass);
void spng_c_call_progressive_end(png_structrp png_ptr, png_inforp info_ptr);
/* Hands one row to a transform the client installed.
 *
 * The row's description is built here rather than passed in, and for the usual
 * reason: the client may jump out of its own transform, and a description owned
 * by a Swift frame would be abandoned along with whatever kept it alive.  So the
 * shape goes in as plain numbers and comes back as one — the bit depth in the low
 * byte and the channel count in the next.
 *
 * What the client declared through png_set_user_transform_info wins over what it
 * left in the description, which is what the reference does.
 */
png_uint_32 spng_c_call_read_user_transform(png_structrp png_ptr, png_bytep row,
    png_uint_32 width, png_uint_32 bit_depth, png_uint_32 channels,
    png_uint_32 color_type);
png_uint_32 spng_c_call_write_user_transform(png_structrp png_ptr, png_bytep row,
    png_uint_32 width, png_uint_32 bit_depth, png_uint_32 channels,
    png_uint_32 color_type);
int spng_c_call_user_chunk(png_structrp png_ptr, png_unknown_chunkp chunk);

/* The simplified API's own pieces.  The lifecycle is C, because the whole of it
 * is a setjmp cage; the work is Swift, because it is the same decoding as
 * everything else.
 */
void spng_c_image_free(png_imagep image);
int spng_swift_image_read_header(png_imagep image, png_controlp control);
int spng_swift_image_finish_read(png_imagep image, png_controlp control,
    png_const_colorp background, void *buffer, png_int_32 row_stride,
    void *colormap);

/* Non-zero when a client callback is on the stack; debug re-entrancy checks
 * use it to catch illegal nested API calls.
 */
int spng_c_in_callback(png_const_structrp png_ptr);

/* -- Default handlers -----------------------------------------------------
 *
 * The default error handler is the end of every error path, so it must not
 * return; declaring that lets the compiler verify that png_error and the
 * generated stubs genuinely never fall through.
 */
PNG_NORETURN void PNGCBAPI spng_c_default_error(png_structp png_ptr,
    png_const_charp message);
void PNGCBAPI spng_c_default_warning(png_structp png_ptr,
    png_const_charp message);
void PNGCBAPI spng_c_stdio_read(png_structp png_ptr, png_bytep data,
    size_t length);
void PNGCBAPI spng_c_stdio_write(png_structp png_ptr, png_bytep data,
    size_t length);
void PNGCBAPI spng_c_stdio_flush(png_structp png_ptr);

/* -- Swift entry points called from the shim ------------------------------
 *
 * Resolved at the final link of the library; the shim only declares them.
 */
int spng_swift_context_create(png_structrp png_ptr, int is_read);
void spng_swift_context_destroy(png_structrp png_ptr);
int spng_swift_info_create(png_inforp info_ptr, png_const_structrp png_ptr);
void spng_swift_info_destroy(png_inforp info_ptr, png_const_structrp png_ptr);
void spng_swift_info_reset(png_inforp info_ptr, png_const_structrp png_ptr);

#ifdef __cplusplus
}
#endif

#endif /* SPNG_INTERNAL_H */
