/* swift_simplified.c - the lifecycle of the simplified API
 *
 * The one part of the library a client uses without installing anything.  Everywhere else a client
 * supplies an error handler and this library jumps to it; here it calls a function that returns zero
 * and leaves a sentence behind, and the jump is caught before it can reach the client.
 *
 * So this file is the cage.  Every entry point sets a jump, calls into the engine, and turns whatever
 * comes back into a result and a message.  It is C for the reason the rest of the error machinery is:
 * setjmp is not something a Swift frame can be on the wrong side of.
 */

#include "include/swift_internal.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Records a message into the image and remembers how bad it was.
 *
 * The first warning and the first error are both kept, and an error outranks a warning: a client that
 * gets both is told about the one that stopped it.
 */
static void
swift_image_record(png_imagep image, png_const_charp message, int severity)
{
   if (image == NULL)
      return;

   /* Only if this is worse than what is already recorded, or nothing is. */
   if ((image->warning_or_error & 0x03) >= (png_uint_32)severity &&
       (image->warning_or_error & 0x03) != 0)
      return;

   image->warning_or_error = (image->warning_or_error & ~0x03U) | (png_uint_32)severity;

   if (message != NULL)
   {
      size_t length = strlen(message);

      if (length >= sizeof image->message)
         length = sizeof image->message - 1;

      memcpy(image->message, message, length);
      image->message[length] = 0;
   }
}

static void PNGCBAPI
swift_image_error(png_structp png_ptr, png_const_charp message)
{
   png_controlp control = (png_controlp)png_get_error_ptr(png_ptr);

   if (control != NULL)
   {
      swift_image_record(control->image, message, PNG_IMAGE_ERROR);
      longjmp(control->jmpbuf, 1);
   }

   /* No control block to jump to, which cannot happen through this API's own entry points and
    * would leave nothing to return to if it did.
    */
   abort();
}

static void PNGCBAPI
swift_image_warning(png_structp png_ptr, png_const_charp message)
{
   png_controlp control = (png_controlp)png_get_error_ptr(png_ptr);

   if (control != NULL)
      swift_image_record(control->image, message, PNG_IMAGE_WARNING);
}

/* Releases everything the control block owns, including itself. */
void
swift_c_image_free(png_imagep image)
{
   png_controlp control;

   if (image == NULL || image->opaque == NULL)
      return;

   control = image->opaque;
   image->opaque = NULL;

   if (control->png_ptr != NULL)
   {
      if (control->for_write)
         png_destroy_write_struct(&control->png_ptr, &control->info_ptr);
      else
         png_destroy_read_struct(&control->png_ptr, &control->info_ptr, NULL);
   }

   if (control->file != NULL && control->owned_file)
      fclose(control->file);

   free(control);
}

/* Makes the control block and the structure underneath it.
 *
 * Returns NULL having recorded the reason, which is this API's way of failing.
 */
static png_controlp
swift_image_begin(png_imagep image, int for_write)
{
   png_controlp control;

   if (image == NULL)
      return NULL;

   if (image->version != PNG_IMAGE_VERSION)
   {
      swift_image_record(image, "png_image: incorrect version", PNG_IMAGE_ERROR);
      return NULL;
   }

   /* Anything already here is from a previous call the client did not finish. */
   swift_c_image_free(image);

   image->warning_or_error = 0;
   image->message[0] = 0;

   control = calloc(1, sizeof *control);

   if (control == NULL)
   {
      swift_image_record(image, "png_image: out of memory", PNG_IMAGE_ERROR);
      return NULL;
   }

   control->image = image;
   control->for_write = for_write ? 1u : 0u;
   control->error_buf = &control->jmpbuf;

   control->png_ptr = for_write
      ? png_create_write_struct(PNG_LIBPNG_VER_STRING, control,
                                swift_image_error, swift_image_warning)
      : png_create_read_struct(PNG_LIBPNG_VER_STRING, control,
                               swift_image_error, swift_image_warning);

   if (control->png_ptr == NULL)
   {
      free(control);
      swift_image_record(image, "png_image: out of memory", PNG_IMAGE_ERROR);
      return NULL;
   }

   control->info_ptr = png_create_info_struct(control->png_ptr);

   if (control->info_ptr == NULL)
   {
      swift_c_image_free(image);
      swift_image_record(image, "png_image: out of memory", PNG_IMAGE_ERROR);
      return NULL;
   }

   image->opaque = control;

   return control;
}

int
png_image_begin_read_from_file(png_imagep image, const char *file_name)
{
   png_controlp control = swift_image_begin(image, 0);

   if (control == NULL)
      return 0;

   control->file = fopen(file_name, "rb");

   if (control->file == NULL)
   {
      swift_image_record(image, strerror(errno), PNG_IMAGE_ERROR);
      swift_c_image_free(image);
      return 0;
   }

   control->owned_file = 1;

   if (setjmp(control->jmpbuf) != 0)
   {
      swift_c_image_free(image);
      return 0;
   }

   png_init_io(control->png_ptr, control->file);

   return swift_swift_image_read_header(image, control);
}

int
png_image_begin_read_from_stdio(png_imagep image, FILE *file)
{
   png_controlp control;

   if (file == NULL)
   {
      if (image != NULL)
         swift_image_record(image, "png_image: invalid file", PNG_IMAGE_ERROR);

      return 0;
   }

   control = swift_image_begin(image, 0);

   if (control == NULL)
      return 0;

   control->file = file;
   control->owned_file = 0;

   if (setjmp(control->jmpbuf) != 0)
   {
      swift_c_image_free(image);
      return 0;
   }

   png_init_io(control->png_ptr, control->file);

   return swift_swift_image_read_header(image, control);
}

/* Reading from memory, which needs a read callback of our own: the bytes are the client's and are
 * handed out a piece at a time as the decoder asks.
 */
static void PNGCBAPI
swift_image_read_memory(png_structp png_ptr, png_bytep data, size_t length)
{
   png_controlp control = (png_controlp)png_get_io_ptr(png_ptr);

   if (control == NULL || control->size < length)
   {
      png_error(png_ptr, "png_image: read beyond end of memory");
      return;
   }

   memcpy(data, control->memory, length);
   control->memory += length;
   control->size -= length;
}

int
png_image_begin_read_from_memory(png_imagep image, png_const_voidp memory, size_t size)
{
   png_controlp control;

   if (memory == NULL)
   {
      if (image != NULL)
         swift_image_record(image, "png_image: invalid memory", PNG_IMAGE_ERROR);

      return 0;
   }

   control = swift_image_begin(image, 0);

   if (control == NULL)
      return 0;

   control->memory = memory;
   control->size = size;

   if (setjmp(control->jmpbuf) != 0)
   {
      swift_c_image_free(image);
      return 0;
   }

   png_set_read_fn(control->png_ptr, control, swift_image_read_memory);

   return swift_swift_image_read_header(image, control);
}

int
png_image_finish_read(png_imagep image, png_const_colorp background,
    void *buffer, png_int_32 row_stride, void *colormap)
{
   png_controlp control;

   if (image == NULL || image->opaque == NULL)
   {
      if (image != NULL)
         swift_image_record(image, "png_image_finish_read: no image", PNG_IMAGE_ERROR);

      return 0;
   }

   control = image->opaque;

   if (buffer == NULL)
   {
      swift_image_record(image, "png_image_finish_read: no buffer", PNG_IMAGE_ERROR);
      swift_c_image_free(image);
      return 0;
   }

   if (setjmp(control->jmpbuf) != 0)
   {
      swift_c_image_free(image);
      return 0;
   }

   {
      int result = swift_swift_image_finish_read(image, control, background, buffer,
                                                row_stride, colormap);

      swift_c_image_free(image);

      return result;
   }
}

void
png_image_free(png_imagep image)
{
   swift_c_image_free(image);
}


/* -- writing ---------------------------------------------------------------
 *
 * The same cage the other way round.  A client describes the image it holds and hands over the
 * pixels; everything about how they become a file is the library's.
 */

/* `used` comes back with how many bytes the file came to, taken before the control block goes away:
 * the caller cannot read it afterwards, because afterwards there is nothing to read.
 */
static int
swift_image_write(png_imagep image, const void *buffer, png_int_32 row_stride,
    int convert_to_8_bit, const void *colormap, size_t *used)
{
   png_controlp control = image->opaque;

   if (buffer == NULL)
   {
      swift_image_record(image, "png_image_write: no buffer", PNG_IMAGE_ERROR);
      swift_c_image_free(image);
      return 0;
   }

   if (setjmp(control->jmpbuf) != 0)
   {
      swift_c_image_free(image);
      return 0;
   }

   {
      int result = swift_swift_image_write(image, control, buffer, row_stride,
                                          convert_to_8_bit, colormap);

      if (used != NULL)
         *used = control->out_used;

      swift_c_image_free(image);

      return result;
   }
}

int
png_image_write_to_file(png_imagep image, const char *file, int convert_to_8_bit,
    const void *buffer, png_int_32 row_stride, const void *colormap)
{
   png_controlp control;

   if (image == NULL)
      return 0;

   control = swift_image_begin(image, 1);

   if (control == NULL)
      return 0;

   control->file = fopen(file, "wb");

   if (control->file == NULL)
   {
      swift_image_record(image, strerror(errno), PNG_IMAGE_ERROR);
      swift_c_image_free(image);
      return 0;
   }

   control->owned_file = 1;

   if (setjmp(control->jmpbuf) != 0)
   {
      swift_c_image_free(image);
      return 0;
   }

   png_init_io(control->png_ptr, control->file);

   return swift_image_write(image, buffer, row_stride, convert_to_8_bit, colormap, NULL);
}

int
png_image_write_to_stdio(png_imagep image, FILE *file, int convert_to_8_bit,
    const void *buffer, png_int_32 row_stride, const void *colormap)
{
   png_controlp control;

   if (image == NULL)
      return 0;

   if (file == NULL)
   {
      swift_image_record(image, "png_image_write: invalid file", PNG_IMAGE_ERROR);
      return 0;
   }

   control = swift_image_begin(image, 1);

   if (control == NULL)
      return 0;

   control->file = file;
   control->owned_file = 0;

   if (setjmp(control->jmpbuf) != 0)
   {
      swift_c_image_free(image);
      return 0;
   }

   png_init_io(control->png_ptr, control->file);

   return swift_image_write(image, buffer, row_stride, convert_to_8_bit, colormap, NULL);
}

/* Writing to memory, which is also how the size is found out.
 *
 * A client that does not know how much room to set aside passes none, and what it gets back is the
 * count it needed: the whole file is produced either way and the bytes are simply not kept.  That is
 * the reference's arrangement and it is the only one that can answer the question exactly, since how
 * well an image compresses is not something anyone can predict.
 */
static void PNGCBAPI
swift_image_write_memory(png_structp png_ptr, png_bytep data, size_t length)
{
   png_controlp control = (png_controlp)png_get_io_ptr(png_ptr);

   if (control == NULL)
      return;

   if (control->out_memory != NULL && control->out_used + length <= control->out_size)
      memcpy(control->out_memory + control->out_used, data, length);

   control->out_used += length;
}

static void PNGCBAPI
swift_image_flush_memory(png_structp png_ptr)
{
   (void)png_ptr;
}

int
png_image_write_to_memory(png_imagep image, void *memory,
    png_alloc_size_t * PNG_RESTRICT memory_bytes, int convert_to_8_bit,
    const void *buffer, png_int_32 row_stride, const void *colormap)
{
   png_controlp control;
   int result;

   if (image == NULL || memory_bytes == NULL)
   {
      if (image != NULL)
         swift_image_record(image, "png_image_write: no size", PNG_IMAGE_ERROR);

      return 0;
   }

   control = swift_image_begin(image, 1);

   if (control == NULL)
      return 0;

   control->out_memory = memory;
   control->out_size = memory == NULL ? 0 : (size_t)*memory_bytes;
   control->out_used = 0;

   if (setjmp(control->jmpbuf) != 0)
   {
      swift_c_image_free(image);
      return 0;
   }

   png_set_write_fn(control->png_ptr, control, swift_image_write_memory,
                    swift_image_flush_memory);

   /* The count is wanted whether or not the bytes fitted, so it is taken from the control block
    * before that block goes away.
    */
   {
      size_t used = 0;

      result = swift_image_write(image, buffer, row_stride, convert_to_8_bit, colormap, &used);

      if (result != 0)
      {
         if (memory != NULL && used > (size_t)*memory_bytes)
         {
            /* There was not room, and saying so is the point of the call. */
            *memory_bytes = used;
            swift_image_record(image, "png_image_write: buffer too small", PNG_IMAGE_ERROR);
            return 0;
         }

         *memory_bytes = used;
      }
   }

   return result;
}
