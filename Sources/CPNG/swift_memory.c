/* swift_memory.c - allocation
 *
 * A client can install its own allocator, and every allocation the library makes
 * on its behalf has to go through it.  That is not just a courtesy: a client may
 * take ownership of a buffer we allocated (png_data_freer transfers the palette,
 * the text array and others) and release it with png_free afterwards, so the two
 * sides must agree on which allocator owns the memory.
 *
 * This is why the engine allocates its buffers through here rather than with
 * Swift's allocator, even for memory a client never sees.
 */

#include "swift_internal.h"

#include <stdlib.h>

/* libpng caps a single allocation at what its size type can express, and refuses
 * a zero-sized request rather than returning a pointer that cannot be written.
 */
static int
swift_size_is_valid(png_alloc_size_t size)
{
   return size > 0 && size <= PNG_SIZE_MAX;
}

png_voidp PNGAPI
png_malloc_default(png_const_structrp png_ptr, png_alloc_size_t size)
{
   png_voidp memory;

   if (!swift_size_is_valid(size))
      return NULL;

   memory = malloc((size_t)size);

   if (memory == NULL)
      png_error(png_ptr, "out of memory");

   return memory;
}

void PNGAPI
png_free_default(png_const_structrp png_ptr, png_voidp ptr)
{
   (void)png_ptr;

   free(ptr);
}

/* Shared by png_malloc and png_malloc_warn, which differ only in how they report
 * a failure.
 */
static png_voidp
swift_malloc_base(png_const_structrp png_ptr, png_alloc_size_t size)
{
   if (png_ptr == NULL || !swift_size_is_valid(size))
      return NULL;

   if (png_ptr->malloc_fn != NULL)
   {
      /* The client's allocator may itself report an error and jump, so nothing
       * may be owned by the caller's frame here.
       */
      return png_ptr->malloc_fn((png_structp)png_ptr, size);
   }

   if (size > PNG_SIZE_MAX)
      return NULL;

   return malloc((size_t)size);
}

png_voidp PNGAPI
png_malloc(png_const_structrp png_ptr, png_alloc_size_t size)
{
   png_voidp memory = swift_malloc_base(png_ptr, size);

   if (memory == NULL)
      png_error(png_ptr, "out of memory");

   return memory;
}

png_voidp PNGAPI
png_malloc_warn(png_const_structrp png_ptr, png_alloc_size_t size)
{
   png_voidp memory = swift_malloc_base(png_ptr, size);

   if (memory == NULL)
      png_warning(png_ptr, "out of memory");

   return memory;
}

png_voidp PNGAPI
png_calloc(png_const_structrp png_ptr, png_alloc_size_t size)
{
   png_voidp memory = png_malloc(png_ptr, size);
   png_bytep bytes = (png_bytep)memory;
   png_alloc_size_t index;

   /* Cleared by hand rather than with calloc, because the client's allocator has
    * no zeroing variant to call.
    */
   for (index = 0; index < size; ++index)
      bytes[index] = 0;

   return memory;
}

void PNGAPI
png_free(png_const_structrp png_ptr, png_voidp ptr)
{
   if (png_ptr == NULL || ptr == NULL)
      return;

   if (png_ptr->free_fn != NULL)
   {
      png_ptr->free_fn((png_structp)png_ptr, ptr);
      return;
   }

   free(ptr);
}

void PNGAPI
png_set_mem_fn(png_structrp png_ptr, png_voidp mem_ptr, png_malloc_ptr malloc_fn,
    png_free_ptr free_fn)
{
   if (png_ptr == NULL)
      return;

   png_ptr->mem_ptr = mem_ptr;

   /* Both or neither: a client allocator paired with the default release, or the
    * reverse, would hand memory to the wrong owner.
    */
   if (malloc_fn != NULL && free_fn != NULL)
   {
      png_ptr->malloc_fn = malloc_fn;
      png_ptr->free_fn = free_fn;
   }

   else
   {
      png_ptr->malloc_fn = NULL;
      png_ptr->free_fn = NULL;
   }
}

png_voidp PNGAPI
png_get_mem_ptr(png_const_structrp png_ptr)
{
   if (png_ptr == NULL)
      return NULL;

   return png_ptr->mem_ptr;
}

/* The engine's own allocations, which report a failure by returning rather than by
 * jumping.
 *
 * png_malloc cannot be used for these.  It reports a failure with png_error, and a
 * client's error handler is entitled not to return — so the jump would leave from
 * inside the allocator, skipping every Swift frame between there and the client's
 * setjmp along with whatever those frames were holding.  A half-built text entry is
 * exactly that: its keyword is allocated, its value is not, and the code that would
 * free the keyword never runs.
 *
 * Returning null instead lets the engine unwind normally, free what it has, and
 * report the failure from the boundary where nothing is live.
 */
png_voidp
swift_c_malloc(png_const_structrp png_ptr, png_alloc_size_t size)
{
   return swift_malloc_base(png_ptr, size);
}

png_voidp
swift_c_malloc_warn(png_const_structrp png_ptr, png_alloc_size_t size)
{
   return png_malloc_warn(png_ptr, size);
}

void
swift_c_free(png_const_structrp png_ptr, png_voidp ptr)
{
   png_free(png_ptr, ptr);
}
