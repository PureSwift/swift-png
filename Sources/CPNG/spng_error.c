/* spng_error.c - error reporting and the setjmp/longjmp boundary
 *
 * This file owns the jump machinery.  Nothing else in the project references
 * jmp_buf, longjmp or setjmp, which keeps the one construct that can abandon
 * Swift frames without running their cleanups confined to a single reviewable
 * translation unit.
 *
 * The contract with the Swift engine: engine code never jumps.  It reports
 * failure by throwing, and the exported entry point calls spng_c_error as the
 * final action in its frame, once no Swift-managed values are live.  Client
 * callbacks are a separate case: a client may legally longjmp out of one, so
 * call sites for the trampolines in spng_callbacks.c must leave the context in
 * a state that png_destroy_* can still reclaim.
 */

#include "spng_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Copy a message into the struct's fixed buffer so dispatch allocates nothing.
 * png_ptr is const in the public signatures because reporting is conceptually
 * read-only, but the buffer is scratch space; casting the constness away here
 * matches how the reference implementation treats it.
 */
static png_const_charp
spng_stage_message(png_const_structrp png_ptr, png_const_charp message)
{
   png_structp mutable_ptr = (png_structp)png_ptr;

   if (message == NULL)
      message = "unknown error";

   if (mutable_ptr == NULL)
      return message;

   strncpy(mutable_ptr->message, message, SPNG_MESSAGE_MAX - 1);
   mutable_ptr->message[SPNG_MESSAGE_MAX - 1] = '\0';

   return mutable_ptr->message;
}

/* Prefix a message with a chunk name, as "IHDR: message".
 *
 * Assembled in a local buffer before being copied into place, because the caller
 * may well have staged `message` into that same buffer already; building in place
 * would overwrite the text while reading it.
 */
static png_const_charp
spng_stage_chunk_message(png_const_structrp png_ptr, png_const_charp chunk_name,
    png_const_charp message)
{
   png_structp mutable_ptr = (png_structp)png_ptr;
   char staged[SPNG_MESSAGE_MAX];
   size_t offset = 0;

   if (mutable_ptr == NULL)
      return message;

   if (chunk_name != NULL)
   {
      while (offset + 2 < SPNG_MESSAGE_MAX && chunk_name[offset] != '\0')
      {
         staged[offset] = chunk_name[offset];
         ++offset;
      }

      if (offset + 2 < SPNG_MESSAGE_MAX)
      {
         staged[offset++] = ':';
         staged[offset++] = ' ';
      }
   }

   if (message != NULL)
   {
      size_t index = 0;

      while (offset + 1 < SPNG_MESSAGE_MAX && message[index] != '\0')
         staged[offset++] = message[index++];
   }

   staged[offset] = '\0';

   memcpy(mutable_ptr->message, staged, offset + 1);

   return mutable_ptr->message;
}

void PNGAPI
png_longjmp(png_const_structrp png_ptr, int val)
{
   if (png_ptr != NULL && png_ptr->longjmp_fn != NULL &&
       (png_ptr->flags & SPNG_FLAG_JMPBUF_ARMED) != 0)
   {
      /* The buffer lives in the heap-allocated struct, so its address is stable
       * for as long as the client can jump to it.
       */
      png_ptr->longjmp_fn(((png_structp)png_ptr)->jmp_buf_local, val);
   }

   /* No jump target: the client never called setjmp(png_jmpbuf(png_ptr)) and
    * has no way to recover, which is the same dead end the reference
    * implementation reaches.
    */
   abort();
}

jmp_buf * PNGAPI
png_set_longjmp_fn(png_structrp png_ptr, png_longjmp_ptr longjmp_fn,
    size_t jmp_buf_size)
{
   if (png_ptr == NULL)
      return NULL;

   /* A size mismatch means the client was compiled against a different
    * <setjmp.h> configuration than this library; jumping would corrupt the
    * stack, so refuse rather than accept a buffer we cannot use.
    */
   if (jmp_buf_size != sizeof (jmp_buf))
   {
      png_ptr->longjmp_fn = NULL;
      png_ptr->flags &= ~SPNG_FLAG_JMPBUF_ARMED;
      png_error(png_ptr, "size of jmp_buf does not match the library build");
   }

   png_ptr->longjmp_fn = longjmp_fn;
   png_ptr->jmp_buf_size = jmp_buf_size;
   png_ptr->flags |= SPNG_FLAG_JMPBUF_ARMED;

   return &png_ptr->jmp_buf_local;
}

void PNGCBAPI
spng_c_default_error(png_structp png_ptr, png_const_charp message)
{
   fprintf(stderr, "libpng error: %s\n", message != NULL ? message : "");
   fflush(stderr);
   png_longjmp(png_ptr, 1);
}

void PNGCBAPI
spng_c_default_warning(png_structp png_ptr, png_const_charp message)
{
   (void)png_ptr;
   fprintf(stderr, "libpng warning: %s\n", message != NULL ? message : "");
   fflush(stderr);
}

void PNGAPI
png_error(png_const_structrp png_ptr, png_const_charp error_message)
{
   png_const_charp staged = spng_stage_message(png_ptr, error_message);

   if (png_ptr != NULL && png_ptr->error_fn != NULL)
   {
      /* The handler is expected not to return.  If it does, fall through to
       * the jump so that control never resumes in the caller, which has already
       * abandoned whatever it was doing.
       */
      png_ptr->error_fn((png_structp)png_ptr, staged);
   }

   spng_c_default_error((png_structp)png_ptr, staged);
}

void PNGAPI
png_warning(png_const_structrp png_ptr, png_const_charp warning_message)
{
   png_const_charp staged = spng_stage_message(png_ptr, warning_message);

   if (png_ptr != NULL && png_ptr->warning_fn != NULL)
      png_ptr->warning_fn((png_structp)png_ptr, staged);

   else
      spng_c_default_warning((png_structp)png_ptr, staged);
}

void PNGAPI
png_benign_error(png_const_structrp png_ptr, png_const_charp error_message)
{
   png_uint_32 benign = (png_ptr != NULL && (png_ptr->flags & SPNG_FLAG_IS_READ)
       != 0) ? SPNG_FLAG_BENIGN_READ_ERR : SPNG_FLAG_BENIGN_WRITE_ERR;

   if (png_ptr != NULL && (png_ptr->flags & benign) != 0)
      png_warning(png_ptr, error_message);

   else
      png_error(png_ptr, error_message);
}

void PNGAPI
png_chunk_error(png_const_structrp png_ptr, png_const_charp error_message)
{
   png_error(png_ptr, error_message);
}

void PNGAPI
png_chunk_warning(png_const_structrp png_ptr, png_const_charp warning_message)
{
   png_warning(png_ptr, warning_message);
}

void PNGAPI
png_chunk_benign_error(png_const_structrp png_ptr, png_const_charp error_message)
{
   png_benign_error(png_ptr, error_message);
}

void
spng_c_error(png_const_structrp png_ptr, png_const_charp message)
{
   png_error(png_ptr, message);
}

void
spng_c_warning(png_const_structrp png_ptr, png_const_charp message)
{
   png_warning(png_ptr, message);
}

void
spng_c_warning_bytes(png_const_structrp png_ptr, const char *message,
    size_t length)
{
   png_structp mutable_ptr = (png_structp)png_ptr;
   size_t count = length;

   if (mutable_ptr == NULL || message == NULL)
      return;

   if (count > SPNG_MESSAGE_MAX - 1)
      count = SPNG_MESSAGE_MAX - 1;

   memcpy(mutable_ptr->message, message, count);
   mutable_ptr->message[count] = '\0';

   /* Pass the staged copy rather than the caller's bytes, which are not
    * terminated.
    */
   png_warning(png_ptr, mutable_ptr->message);
}

void
spng_c_benign_error(png_const_structrp png_ptr, png_const_charp message)
{
   png_benign_error(png_ptr, message);
}

void
spng_c_chunk_error(png_const_structrp png_ptr, png_const_charp chunk_name,
    png_const_charp message)
{
   png_error(png_ptr, spng_stage_chunk_message(png_ptr, chunk_name, message));
}

void
spng_c_chunk_warning(png_const_structrp png_ptr, png_const_charp chunk_name,
    png_const_charp message)
{
   png_warning(png_ptr, spng_stage_chunk_message(png_ptr, chunk_name, message));
}

int
spng_c_in_callback(png_const_structrp png_ptr)
{
   return png_ptr != NULL && (png_ptr->flags & SPNG_FLAG_IN_CALLBACK) != 0;
}
