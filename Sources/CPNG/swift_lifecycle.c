/* swift_lifecycle.c - creating and destroying the control structures
 *
 * Creation is in C because it needs a jump target of its own.  A client has not
 * had the chance to call setjmp yet at this point, but creation can still fail
 * (a version mismatch, a failed allocation), and the way failure is reported in
 * this API is by jumping.  So creation arms a temporary buffer, reports through
 * it, and returns NULL, which is what the API promises.
 *
 * Destruction has to work from any state the structure can be in, including
 * whatever a client jump left behind mid-decode.  That is why the codec state
 * hangs off a single pointer: releasing it reclaims the whole tree without
 * needing to know how far the decode had progressed.
 */

#include "swift_internal.h"

#include <setjmp.h>
#include <stdlib.h>
#include <string.h>

/* A client compiled against a different major or minor version was built against
 * different declarations, so the structures it expects are not the ones we
 * provide.  A differing patch level is compatible by libpng's own rule.
 */
static int
swift_version_is_compatible(png_const_charp user_png_ver)
{
   if (user_png_ver == NULL)
      return 1; /* the client declined to say; libpng accepts this */

   if (strcmp(user_png_ver, PNG_LIBPNG_VER_STRING) == 0)
      return 1;

   /* "1.6.58": positions 0 and 2 are the major and minor digits. */
   if (user_png_ver[0] != PNG_LIBPNG_VER_STRING[0])
      return 0;

   if (user_png_ver[1] != '.' || user_png_ver[2] != PNG_LIBPNG_VER_STRING[2])
      return 0;

   return 1;
}

static png_structp
swift_create_png_struct(png_const_charp user_png_ver, png_voidp error_ptr,
    png_error_ptr error_fn, png_error_ptr warn_fn, png_voidp mem_ptr,
    png_malloc_ptr malloc_fn, png_free_ptr free_fn, int is_read)
{
   /* Built on the stack first so that a failure during creation has somewhere to
    * report to and nothing to release.
    */
   png_struct scratch;
   png_structp png_ptr;

   memset(&scratch, 0, sizeof scratch);

   scratch.error_fn = error_fn;
   scratch.warning_fn = warn_fn;
   scratch.error_ptr = error_ptr;
   scratch.mem_ptr = mem_ptr;

   if (malloc_fn != NULL && free_fn != NULL)
   {
      scratch.malloc_fn = malloc_fn;
      scratch.free_fn = free_fn;
   }

   if (is_read)
      scratch.flags |= SWIFT_FLAG_IS_READ;

   /* Arm the scratch structure's buffer so that a png_error raised below returns
    * here rather than reaching a client that has no target installed yet.
    */
   scratch.longjmp_fn = longjmp;
   scratch.jmp_buf_size = sizeof (jmp_buf);
   scratch.flags |= SWIFT_FLAG_JMPBUF_ARMED;

   if (setjmp(scratch.jmp_buf_local) != 0)
      return NULL;

   if (!swift_version_is_compatible(user_png_ver))
   {
      png_error(&scratch,
          "the application was built against an incompatible libpng version");
   }

   png_ptr = png_malloc(&scratch, (png_alloc_size_t)sizeof (png_struct));

   memcpy(png_ptr, &scratch, sizeof scratch);

   /* The armed buffer addressed the stack frame that is about to end, so the
    * copy's is not a valid target.  Disarm it; the client arms the real one by
    * calling setjmp(png_jmpbuf(png_ptr)).
    */
   png_ptr->longjmp_fn = NULL;
   png_ptr->jmp_buf_size = 0;
   png_ptr->flags &= ~SWIFT_FLAG_JMPBUF_ARMED;

   if (!swift_swift_context_create(png_ptr, is_read))
   {
      png_free(&scratch, png_ptr);
      return NULL;
   }

   return png_ptr;
}

png_structp PNGAPI
png_create_read_struct_2(png_const_charp user_png_ver, png_voidp error_ptr,
    png_error_ptr error_fn, png_error_ptr warn_fn, png_voidp mem_ptr,
    png_malloc_ptr malloc_fn, png_free_ptr free_fn)
{
   return swift_create_png_struct(user_png_ver, error_ptr, error_fn, warn_fn,
       mem_ptr, malloc_fn, free_fn, 1);
}

png_structp PNGAPI
png_create_read_struct(png_const_charp user_png_ver, png_voidp error_ptr,
    png_error_ptr error_fn, png_error_ptr warn_fn)
{
   return swift_create_png_struct(user_png_ver, error_ptr, error_fn, warn_fn,
       NULL, NULL, NULL, 1);
}

png_structp PNGAPI
png_create_write_struct_2(png_const_charp user_png_ver, png_voidp error_ptr,
    png_error_ptr error_fn, png_error_ptr warn_fn, png_voidp mem_ptr,
    png_malloc_ptr malloc_fn, png_free_ptr free_fn)
{
   return swift_create_png_struct(user_png_ver, error_ptr, error_fn, warn_fn,
       mem_ptr, malloc_fn, free_fn, 0);
}

png_structp PNGAPI
png_create_write_struct(png_const_charp user_png_ver, png_voidp error_ptr,
    png_error_ptr error_fn, png_error_ptr warn_fn)
{
   return swift_create_png_struct(user_png_ver, error_ptr, error_fn, warn_fn,
       NULL, NULL, NULL, 0);
}

png_infop PNGAPI
png_create_info_struct(png_const_structrp png_ptr)
{
   png_infop info_ptr;

   if (png_ptr == NULL)
      return NULL;

   /* Allocated with the warning variant so that a failure here returns NULL, as
    * the API promises, rather than jumping.
    */
   info_ptr = (png_infop)png_malloc_warn(png_ptr,
       (png_alloc_size_t)sizeof (png_info));

   if (info_ptr == NULL)
      return NULL;

   memset(info_ptr, 0, sizeof (png_info));

   if (!swift_swift_info_create(info_ptr, png_ptr))
   {
      png_free(png_ptr, info_ptr);
      return NULL;
   }

   return info_ptr;
}

void PNGAPI
png_destroy_info_struct(png_const_structrp png_ptr, png_infopp info_ptr_ptr)
{
   png_infop info_ptr;

   if (png_ptr == NULL || info_ptr_ptr == NULL)
      return;

   info_ptr = *info_ptr_ptr;

   if (info_ptr == NULL)
      return;

   *info_ptr_ptr = NULL;

   swift_swift_info_destroy(info_ptr, png_ptr);
   png_free(png_ptr, info_ptr);
}

/* Shared by the read and write destructors, which differ only in which
 * structures a client may pass.
 */
static void
swift_destroy_png_struct(png_structpp png_ptr_ptr, png_infopp info_ptr_ptr,
    png_infopp end_info_ptr_ptr)
{
   png_structp png_ptr;

   if (png_ptr_ptr == NULL)
      return;

   png_ptr = *png_ptr_ptr;

   if (png_ptr == NULL)
      return;

   /* Before the structure itself, since releasing them needs its allocator. */
   if (end_info_ptr_ptr != NULL)
      png_destroy_info_struct(png_ptr, end_info_ptr_ptr);

   if (info_ptr_ptr != NULL)
      png_destroy_info_struct(png_ptr, info_ptr_ptr);

   *png_ptr_ptr = NULL;

   /* Releases every buffer the decode had allocated, whatever state it was left
    * in.
    */
   swift_swift_context_destroy(png_ptr);

   if (png_ptr->free_fn != NULL)
      png_ptr->free_fn(png_ptr, png_ptr);

   else
      free(png_ptr);
}

void PNGAPI
png_destroy_read_struct(png_structpp png_ptr_ptr, png_infopp info_ptr_ptr,
    png_infopp end_info_ptr_ptr)
{
   swift_destroy_png_struct(png_ptr_ptr, info_ptr_ptr, end_info_ptr_ptr);
}

void PNGAPI
png_destroy_write_struct(png_structpp png_ptr_ptr, png_infopp info_ptr_ptr)
{
   swift_destroy_png_struct(png_ptr_ptr, info_ptr_ptr, NULL);
}

void PNGAPI
png_info_init_3(png_infopp info_ptr_ptr, size_t png_info_struct_size)
{
   png_infop info_ptr;

   if (info_ptr_ptr == NULL)
      return;

   info_ptr = *info_ptr_ptr;

   if (info_ptr == NULL)
      return;

   /* This entry point exists for code that predates png_info becoming opaque and
    * allocated its own structure.  A client cannot do that any more, since the
    * type is incomplete, so the only sound response to a size that is not ours is
    * to refuse rather than write past the end of whatever was passed.
    */
   if (png_info_struct_size != sizeof (png_info))
      return;

   swift_swift_info_reset(info_ptr, NULL);
}
