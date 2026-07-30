/* pngdump.c - the differential oracle
 *
 * Decodes a file and writes everything observable about the result to standard
 * output in a plain text form.  Compiled twice: once against the reference libpng
 * and once against this library.  If the two outputs differ on any input, this
 * library is wrong, and the diff says where.
 *
 * That indirection exists because two libraries claiming the same ABI cannot be
 * loaded into one process, so the comparison has to happen between processes.
 *
 * The output is deliberately dull and line-oriented, so a diff is readable.
 * Nothing here may depend on which library it was linked against: only the public
 * API is used, and only through the reference headers.
 */

#include <png.h>

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Reported through the error callback, so that a decode that fails still produces
 * comparable output: whether the two libraries agree about rejecting a file is as
 * much a part of conformance as whether they agree about decoding one.
 */
static void PNGCBAPI
report_error(png_structp png_ptr, png_const_charp message)
{
   printf("error %s\n", message);
   fflush(stdout);

   longjmp(png_jmpbuf(png_ptr), 1);
}

static void PNGCBAPI
report_warning(png_structp png_ptr, png_const_charp message)
{
   (void)png_ptr;

   printf("warning %s\n", message);
}

/* Counted to check that the two sides balance.
 *
 * The totals themselves are not reported, and deliberately so: how many
 * allocations a decode makes is an implementation detail that two conforming
 * libraries may reasonably differ on.  What is not negotiable is that everything
 * handed out by the client's allocator comes back to the client's deallocator,
 * including when a decode is abandoned by a jump out of the error handler.
 */
static unsigned long allocation_count;
static unsigned long free_count;

static png_voidp PNGCBAPI
counting_malloc(png_structp png_ptr, png_alloc_size_t size)
{
   (void)png_ptr;

   ++allocation_count;
   return malloc((size_t)size);
}

static void PNGCBAPI
counting_free(png_structp png_ptr, png_voidp ptr)
{
   (void)png_ptr;

   ++free_count;
   free(ptr);
}

static void
dump_header(png_structp png_ptr, png_infop info_ptr)
{
   png_uint_32 width = 0;
   png_uint_32 height = 0;
   int bit_depth = 0;
   int color_type = 0;
   int interlace_type = 0;
   int compression_type = 0;
   int filter_type = 0;

   if (png_get_IHDR(png_ptr, info_ptr, &width, &height, &bit_depth, &color_type,
       &interlace_type, &compression_type, &filter_type) == 0)
   {
      printf("ihdr absent\n");
      return;
   }

   printf("ihdr width=%lu height=%lu depth=%d color=%d interlace=%d"
       " compression=%d filter=%d\n",
       (unsigned long)width, (unsigned long)height, bit_depth, color_type,
       interlace_type, compression_type, filter_type);

   /* The separate accessors have to agree with png_get_IHDR; a client may use
    * either, and some use both.
    */
   printf("geometry width=%lu height=%lu depth=%d color=%d channels=%d"
       " rowbytes=%lu interlace=%d\n",
       (unsigned long)png_get_image_width(png_ptr, info_ptr),
       (unsigned long)png_get_image_height(png_ptr, info_ptr),
       png_get_bit_depth(png_ptr, info_ptr),
       png_get_color_type(png_ptr, info_ptr),
       png_get_channels(png_ptr, info_ptr),
       (unsigned long)png_get_rowbytes(png_ptr, info_ptr),
       png_get_interlace_type(png_ptr, info_ptr));
}

/* Rows are printed as hex.  Comparing them byte for byte is the point of the
 * exercise, and a hex dump keeps the diff pointing at the exact byte.
 */
static void
dump_row(png_uint_32 index, png_const_bytep row, size_t length)
{
   size_t offset;

   printf("row %lu ", (unsigned long)index);

   for (offset = 0; offset < length; ++offset)
      printf("%02x", row[offset]);

   printf("\n");
}

static int
dump_file(const char *path)
{
   FILE *file;
   png_structp png_ptr;
   png_infop info_ptr = NULL;
   png_bytep row = NULL;
   png_uint_32 height;
   png_uint_32 index;
   size_t rowbytes;

   file = fopen(path, "rb");

   if (file == NULL)
   {
      printf("open failed\n");
      return 1;
   }

   png_ptr = png_create_read_struct_2(PNG_LIBPNG_VER_STRING, NULL, report_error,
       report_warning, NULL, counting_malloc, counting_free);

   if (png_ptr == NULL)
   {
      printf("create failed\n");
      fclose(file);
      return 1;
   }

   info_ptr = png_create_info_struct(png_ptr);

   if (info_ptr == NULL)
   {
      printf("create info failed\n");
      png_destroy_read_struct(&png_ptr, NULL, NULL);
      fclose(file);
      return 1;
   }

   if (setjmp(png_jmpbuf(png_ptr)) != 0)
   {
      /* Reached by the error callback.  Everything allocated so far still has to
       * be reclaimable from here, which is the property this arrangement is
       * really testing.
       */
      printf("aborted\n");

      if (row != NULL)
         free(row);

      png_destroy_read_struct(&png_ptr, &info_ptr, NULL);
      fclose(file);

      printf("balanced %d\n", allocation_count == free_count);
      return 0;
   }

   png_init_io(png_ptr, file);
   png_read_info(png_ptr, info_ptr);

   dump_header(png_ptr, info_ptr);

   height = png_get_image_height(png_ptr, info_ptr);
   rowbytes = png_get_rowbytes(png_ptr, info_ptr);

   row = malloc(rowbytes != 0 ? rowbytes : 1);

   if (row == NULL)
   {
      printf("row allocation failed\n");
      png_destroy_read_struct(&png_ptr, &info_ptr, NULL);
      fclose(file);
      return 1;
   }

   for (index = 0; index < height; ++index)
   {
      png_read_row(png_ptr, row, NULL);
      dump_row(index, row, rowbytes);
   }

   png_read_end(png_ptr, NULL);

   printf("done rows=%lu\n", (unsigned long)height);

   free(row);
   row = NULL;

   png_destroy_read_struct(&png_ptr, &info_ptr, NULL);
   fclose(file);

   /* An imbalance means memory the client's allocator gave out was released some
    * other way, or not at all.
    */
   printf("balanced %d\n", allocation_count == free_count);

   return 0;
}

int
main(int argc, char **argv)
{
   if (argc != 2)
   {
      fprintf(stderr, "usage: pngdump <file.png>\n");
      return 2;
   }

   return dump_file(argv[1]);
}
