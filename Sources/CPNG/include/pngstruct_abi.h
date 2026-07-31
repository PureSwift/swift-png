/* pngstruct_abi.h - completion of the opaque libpng control structures
 *
 * png_struct and png_info are incomplete types in the public ABI; clients only
 * ever hold pointers to them, so their layout is ours to choose.  This header
 * completes them for the C shim and for the Swift importer.  It is internal and
 * is never installed.
 *
 * The division of labour is deliberate.  These structures hold only plain data
 * that the error, memory and callback machinery touches, because that machinery
 * has to remain reachable across a client longjmp that abandons Swift frames
 * without running their cleanups.  Everything with a lifetime managed by Swift
 * hangs off the single opaque `swift_ctx` pointer.
 */

#ifndef SPNG_PNGSTRUCT_ABI_H
#define SPNG_PNGSTRUCT_ABI_H

#include "png.h"

#define SPNG_MESSAGE_MAX 192 /* matches the message length libpng exposes */

/* Bits of png_struct_def.flags. */
#define SPNG_FLAG_IS_READ         0x00000001U /* read struct, not write */
#define SPNG_FLAG_JMPBUF_ARMED    0x00000002U /* png_set_longjmp_fn has run */
#define SPNG_FLAG_BENIGN_READ_ERR 0x00000004U /* png_set_benign_errors, read */
#define SPNG_FLAG_BENIGN_WRITE_ERR 0x00000008U /* png_set_benign_errors, write */
#define SPNG_FLAG_IN_CALLBACK     0x00000010U /* debug re-entrancy guard */

struct png_struct_def
{
   /* Jump state.  This is the only jmp_buf in the project and only
    * spng_error.c may touch it.
    */
   jmp_buf jmp_buf_local;
   png_longjmp_ptr longjmp_fn;
   size_t jmp_buf_size;

   /* Error reporting.  `message` receives formatted text before dispatch so
    * that the error path never allocates.
    */
   png_error_ptr error_fn;
   png_error_ptr warning_fn;
   png_voidp error_ptr;
   char message[SPNG_MESSAGE_MAX];

   /* Input and output. */
   png_rw_ptr read_fn;
   png_rw_ptr write_fn;
   png_flush_ptr output_flush_fn;
   png_voidp io_ptr;
   png_uint_32 io_state;

   /* Memory.  All buffers whose pointers can escape to the client are
    * allocated through these.
    */
   png_malloc_ptr malloc_fn;
   png_free_ptr free_fn;
   png_voidp mem_ptr;

   /* Row progress reporting. */
   png_read_status_ptr read_row_fn;
   png_write_status_ptr write_row_fn;

   /* Progressive reader. */
   png_progressive_info_ptr info_fn;
   png_progressive_row_ptr row_fn;
   png_progressive_end_ptr end_fn;
   png_voidp progressive_ptr;

   /* The info structure the client handed to png_process_data, kept so that the
    * callbacks can be given it.  The library never owns it; it is the client's,
    * and is only borrowed for the length of one push.
    */
   png_inforp progressive_info;

   /* User transforms. */
   png_user_transform_ptr read_user_transform_fn;
   png_user_transform_ptr write_user_transform_fn;
   png_voidp user_transform_ptr;
   png_byte user_transform_depth;
   png_byte user_transform_channels;

   /* User chunk handling. */
   png_user_chunk_ptr read_user_chunk_fn;
   png_voidp user_chunk_ptr;

   png_uint_32 flags;

   /* Retained Unmanaged<PngContext>; owns every piece of codec state. */
   void *swift_ctx;
};

struct png_info_def
{
   /* Retained Unmanaged<InfoStore>. */
   void *swift_ctx;
};

/* Control block for the simplified API.  png_image.opaque points at one of
 * these; the layout is private, exactly as it is in the reference ABI.
 */
struct png_control
{
   png_structp png_ptr;
   png_infop info_ptr;
   png_voidp error_buf;

   png_const_bytep memory; /* input, for png_image_begin_read_from_memory */
   size_t size;

   unsigned int for_write : 1;
   unsigned int owned_file : 1;

   /* Where the simplified API catches what the rest of the library throws.
    *
    * The whole difference between this API and the one underneath is that a
    * client of this one never installs an error handler: it calls a function
    * that returns zero and leaves a message behind.  So every call sets a jump
    * here first, and the error handler below jumps to it rather than to the
    * client.
    */
   jmp_buf jmpbuf;

   /* The image being worked on, so the handler can record into its message. */
   png_imagep image;

   /* The file being read or written, when this API opened it. */
   FILE *file;

   /* For writing to memory: where to put it, how much room there is, and how
    * much was needed.
    */
   png_bytep out_memory;
   size_t out_size;
   size_t out_used;
};

#endif /* SPNG_PNGSTRUCT_ABI_H */
