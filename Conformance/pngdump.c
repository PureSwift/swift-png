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

/* Every metadata accessor, in a fixed order.
 *
 * Each line names the chunk and prints what the getter reported, including the bitmask it
 * answered, since a getter claiming to have data is as much a part of the contract as the
 * data itself.  A chunk that was absent prints nothing, so the diff shows a disagreement
 * about presence as an added or removed line.
 */
static void
dump_metadata(png_structp png_ptr, png_infop info_ptr)
{
   png_uint_32 res_x;
   png_uint_32 res_y;
   png_int_32 off_x;
   png_int_32 off_y;
   int unit;
   int intent;
   double gamma;
   png_fixed_point fixed_gamma;
   png_colorp palette;
   int num_palette;
   png_bytep trans_alpha;
   int num_trans;
   png_color_16p trans_color;
   png_color_16p background;
   png_color_8p sig_bit;
   png_uint_16p histogram;
   png_timep mod_time;
   png_charp profile_name;
   png_bytep profile;
   png_uint_32 profile_length;
   int compression_type;
   png_uint_32 num_exif;
   png_bytep exif;
   png_charp scale_width;
   png_charp scale_height;
   png_byte primaries;
   png_byte transfer;
   png_byte matrix;
   png_byte range;
   png_uint_32 max_cll;
   png_uint_32 max_fall;
   png_fixed_point chrm[8];
   png_uint_32 max_lum;
   png_uint_32 min_lum;
   size_t index;

   if (png_get_gAMA_fixed(png_ptr, info_ptr, &fixed_gamma) != 0)
      printf("gama fixed=%ld\n", (long)fixed_gamma);

   if (png_get_gAMA(png_ptr, info_ptr, &gamma) != 0)
      printf("gama double=%.5f\n", gamma);

   if (png_get_cHRM_fixed(png_ptr, info_ptr, &chrm[0], &chrm[1], &chrm[2], &chrm[3],
       &chrm[4], &chrm[5], &chrm[6], &chrm[7]) != 0)
   {
      printf("chrm");
      for (index = 0; index < 8; ++index)
         printf(" %ld", (long)chrm[index]);
      printf("\n");
   }

   if (png_get_sRGB(png_ptr, info_ptr, &intent) != 0)
      printf("srgb intent=%d\n", intent);

   if (png_get_sBIT(png_ptr, info_ptr, &sig_bit) != 0)
      printf("sbit red=%d green=%d blue=%d gray=%d alpha=%d\n",
          sig_bit->red, sig_bit->green, sig_bit->blue, sig_bit->gray, sig_bit->alpha);

   if (png_get_PLTE(png_ptr, info_ptr, &palette, &num_palette) != 0)
   {
      printf("plte count=%d", num_palette);
      for (index = 0; index < (size_t)num_palette; ++index)
         printf(" %02x%02x%02x", palette[index].red, palette[index].green,
             palette[index].blue);
      printf("\n");
   }

   num_trans = 0;
   trans_alpha = NULL;
   trans_color = NULL;

   if (png_get_tRNS(png_ptr, info_ptr, &trans_alpha, &num_trans, &trans_color) != 0)
   {
      printf("trns count=%d", num_trans);

      if (trans_alpha != NULL)
      {
         for (index = 0; index < (size_t)num_trans; ++index)
            printf(" %02x", trans_alpha[index]);
      }

      if (trans_color != NULL)
      {
         printf(" color=%d,%d,%d,%d,%d", trans_color->index, trans_color->red,
             trans_color->green, trans_color->blue, trans_color->gray);
      }

      printf("\n");
   }

   if (png_get_bKGD(png_ptr, info_ptr, &background) != 0)
      printf("bkgd index=%d red=%d green=%d blue=%d gray=%d\n",
          background->index, background->red, background->green, background->blue,
          background->gray);

   if (png_get_hIST(png_ptr, info_ptr, &histogram) != 0)
   {
      printf("hist");
      /* One entry per palette entry, so the palette decides how many to print. */
      if (png_get_PLTE(png_ptr, info_ptr, &palette, &num_palette) != 0)
      {
         for (index = 0; index < (size_t)num_palette; ++index)
            printf(" %u", histogram[index]);
      }
      printf("\n");
   }

   if (png_get_pHYs(png_ptr, info_ptr, &res_x, &res_y, &unit) != 0)
      printf("phys x=%lu y=%lu unit=%d\n", (unsigned long)res_x, (unsigned long)res_y,
          unit);

   if (png_get_pHYs_dpi(png_ptr, info_ptr, &res_x, &res_y, &unit) != 0)
      printf("phys dpi x=%lu y=%lu unit=%d\n", (unsigned long)res_x,
          (unsigned long)res_y, unit);

   printf("phys derived xm=%lu ym=%lu m=%lu xi=%lu yi=%lu i=%lu ratio=%.5f"
       " ratio_fixed=%ld\n",
       (unsigned long)png_get_x_pixels_per_meter(png_ptr, info_ptr),
       (unsigned long)png_get_y_pixels_per_meter(png_ptr, info_ptr),
       (unsigned long)png_get_pixels_per_meter(png_ptr, info_ptr),
       (unsigned long)png_get_x_pixels_per_inch(png_ptr, info_ptr),
       (unsigned long)png_get_y_pixels_per_inch(png_ptr, info_ptr),
       (unsigned long)png_get_pixels_per_inch(png_ptr, info_ptr),
       (double)png_get_pixel_aspect_ratio(png_ptr, info_ptr),
       (long)png_get_pixel_aspect_ratio_fixed(png_ptr, info_ptr));

   if (png_get_oFFs(png_ptr, info_ptr, &off_x, &off_y, &unit) != 0)
      printf("offs x=%ld y=%ld unit=%d\n", (long)off_x, (long)off_y, unit);

   printf("offs derived xp=%ld yp=%ld xu=%ld yu=%ld xi=%.5f yi=%.5f xif=%ld yif=%ld\n",
       (long)png_get_x_offset_pixels(png_ptr, info_ptr),
       (long)png_get_y_offset_pixels(png_ptr, info_ptr),
       (long)png_get_x_offset_microns(png_ptr, info_ptr),
       (long)png_get_y_offset_microns(png_ptr, info_ptr),
       (double)png_get_x_offset_inches(png_ptr, info_ptr),
       (double)png_get_y_offset_inches(png_ptr, info_ptr),
       (long)png_get_x_offset_inches_fixed(png_ptr, info_ptr),
       (long)png_get_y_offset_inches_fixed(png_ptr, info_ptr));

   if (png_get_tIME(png_ptr, info_ptr, &mod_time) != 0)
      printf("time %04d-%02d-%02d %02d:%02d:%02d\n", mod_time->year, mod_time->month,
          mod_time->day, mod_time->hour, mod_time->minute, mod_time->second);

   if (png_get_iCCP(png_ptr, info_ptr, &profile_name, &compression_type, &profile,
       &profile_length) != 0)
   {
      printf("iccp name=%s compression=%d length=%lu", profile_name, compression_type,
          (unsigned long)profile_length);
      for (index = 0; index < (size_t)profile_length; ++index)
         printf(" %02x", profile[index]);
      printf("\n");
   }

   if (png_get_eXIf_1(png_ptr, info_ptr, &num_exif, &exif) != 0)
   {
      printf("exif length=%lu", (unsigned long)num_exif);
      for (index = 0; index < (size_t)num_exif; ++index)
         printf(" %02x", exif[index]);
      printf("\n");
   }

   if (png_get_sCAL_s(png_ptr, info_ptr, &unit, &scale_width, &scale_height) != 0)
      printf("scal unit=%d width=%s height=%s\n", unit, scale_width, scale_height);

   if (png_get_cICP(png_ptr, info_ptr, &primaries, &transfer, &matrix, &range) != 0)
      printf("cicp primaries=%d transfer=%d matrix=%d range=%d\n", primaries, transfer,
          matrix, range);

   if (png_get_cLLI_fixed(png_ptr, info_ptr, &max_cll, &max_fall) != 0)
      printf("clli max_cll=%lu max_fall=%lu\n", (unsigned long)max_cll,
          (unsigned long)max_fall);

   {
      png_textp text = NULL;
      int num_text = 0;

      if (png_get_text(png_ptr, info_ptr, &text, &num_text) > 0)
      {
         int entry;

         printf("text count=%d\n", num_text);

         for (entry = 0; entry < num_text; ++entry)
         {
            /* The language fields are absent for the older two chunks, and printed as a
             * dash so that absent and empty are distinguishable in the diff.
             */
            printf("text %d compression=%d key=%s text=%s lang=%s lang_key=%s"
                " text_length=%lu itxt_length=%lu\n",
                entry, text[entry].compression,
                text[entry].key != NULL ? text[entry].key : "-",
                text[entry].text != NULL ? text[entry].text : "-",
                text[entry].lang != NULL ? text[entry].lang : "-",
                text[entry].lang_key != NULL ? text[entry].lang_key : "-",
                (unsigned long)text[entry].text_length,
                (unsigned long)text[entry].itxt_length);
         }
      }
   }

   if (png_get_mDCV_fixed(png_ptr, info_ptr, &chrm[0], &chrm[1], &chrm[2], &chrm[3],
       &chrm[4], &chrm[5], &chrm[6], &chrm[7], &max_lum, &min_lum) != 0)
   {
      printf("mdcv");
      for (index = 0; index < 8; ++index)
         printf(" %ld", (long)chrm[index]);
      printf(" max=%lu min=%lu\n", (unsigned long)max_lum, (unsigned long)min_lum);
   }
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
   dump_metadata(png_ptr, info_ptr);

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

   png_read_end(png_ptr, info_ptr);

   /* Again after the image data, since metadata is allowed on either side of it and a
    * client that reads to the end expects to see both.
    */
   printf("after end\n");
   dump_metadata(png_ptr, info_ptr);

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
