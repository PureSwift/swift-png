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
   /* These chunks postdate the oldest reference this harness is compiled against,
    * so their printing is conditional on the headers knowing them.  A reference
    * that does not is expected to read them as unknown chunks, and what it prints
    * then is a recorded difference rather than a compile error here.
    */
#ifdef PNG_cICP_SUPPORTED
   png_byte primaries;
   png_byte transfer;
   png_byte matrix;
   png_byte range;
#endif
#ifdef PNG_cLLI_SUPPORTED
   png_uint_32 max_cll;
   png_uint_32 max_fall;
#endif
   png_fixed_point chrm[8]; /* shared with cHRM, which every reference knows */
#ifdef PNG_mDCV_SUPPORTED
   png_uint_32 max_lum;
   png_uint_32 min_lum;
#endif
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

#ifdef PNG_cICP_SUPPORTED
   if (png_get_cICP(png_ptr, info_ptr, &primaries, &transfer, &matrix, &range) != 0)
      printf("cicp primaries=%d transfer=%d matrix=%d range=%d\n", primaries, transfer,
          matrix, range);
#endif

#ifdef PNG_cLLI_SUPPORTED
   if (png_get_cLLI_fixed(png_ptr, info_ptr, &max_cll, &max_fall) != 0)
      printf("clli max_cll=%lu max_fall=%lu\n", (unsigned long)max_cll,
          (unsigned long)max_fall);
#endif

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

#ifdef PNG_mDCV_SUPPORTED
   if (png_get_mDCV_fixed(png_ptr, info_ptr, &chrm[0], &chrm[1], &chrm[2], &chrm[3],
       &chrm[4], &chrm[5], &chrm[6], &chrm[7], &max_lum, &min_lum) != 0)
   {
      printf("mdcv");
      for (index = 0; index < 8; ++index)
         printf(" %ld", (long)chrm[index]);
      printf(" max=%lu min=%lu\n", (unsigned long)max_lum, (unsigned long)min_lum);
   }
#endif
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

/* How the rows are asked for.
 *
 * Both are ordinary client patterns and they run through different code, so both are
 * compared.  For an interlaced image they are quite different: one hands the whole job to
 * the library, the other loops the passes itself.
 */
enum read_mode { READ_ROWS, READ_IMAGE };

/* The transforms, named so a failing case can be reproduced from the command line.
 *
 * A client asks for these in any order and the library applies them in an order of its own, so the
 * comparison drives combinations rather than one at a time: the interesting defects are in the
 * interactions, not in a single transform.
 */
struct transform_entry
{
   const char *name;
   void (*apply)(png_structp png_ptr, png_infop info_ptr);
};

static void apply_expand(png_structp p, png_infop i) { (void)i; png_set_expand(p); }
static void apply_palette_to_rgb(png_structp p, png_infop i) { (void)i; png_set_palette_to_rgb(p); }
static void apply_gray_1_2_4_to_8(png_structp p, png_infop i) { (void)i; png_set_expand_gray_1_2_4_to_8(p); }
static void apply_trns_to_alpha(png_structp p, png_infop i) { (void)i; png_set_tRNS_to_alpha(p); }
static void apply_expand_16(png_structp p, png_infop i) { (void)i; png_set_expand_16(p); }
static void apply_strip_16(png_structp p, png_infop i) { (void)i; png_set_strip_16(p); }
static void apply_scale_16(png_structp p, png_infop i) { (void)i; png_set_scale_16(p); }
static void apply_strip_alpha(png_structp p, png_infop i) { (void)i; png_set_strip_alpha(p); }
static void apply_gray_to_rgb(png_structp p, png_infop i) { (void)i; png_set_gray_to_rgb(p); }
static void apply_packing(png_structp p, png_infop i) { (void)i; png_set_packing(p); }
static void apply_packswap(png_structp p, png_infop i) { (void)i; png_set_packswap(p); }
static void apply_bgr(png_structp p, png_infop i) { (void)i; png_set_bgr(p); }
static void apply_swap(png_structp p, png_infop i) { (void)i; png_set_swap(p); }
static void apply_swap_alpha(png_structp p, png_infop i) { (void)i; png_set_swap_alpha(p); }
static void apply_invert_alpha(png_structp p, png_infop i) { (void)i; png_set_invert_alpha(p); }
static void apply_invert_mono(png_structp p, png_infop i) { (void)i; png_set_invert_mono(p); }
static void apply_filler(png_structp p, png_infop i) { (void)i; png_set_filler(p, 0x3C3C, PNG_FILLER_AFTER); }
static void apply_filler_before(png_structp p, png_infop i) { (void)i; png_set_filler(p, 0x3C3C, PNG_FILLER_BEFORE); }
static void apply_add_alpha(png_structp p, png_infop i) { (void)i; png_set_add_alpha(p, 0x8080, PNG_FILLER_AFTER); }

/* A spread of exponents rather than one.
 *
 * The pair that multiplies to one has to leave the samples alone, and the others have to move them
 * by the same amount the reference moves them — including the pair just inside the threshold below
 * which the reference declines to bother at all.
 */
static void apply_gamma_none(png_structp p, png_infop i) { (void)i; png_set_gamma(p, 2.2, 1.0 / 2.2); }
static void apply_gamma_bright(png_structp p, png_infop i) { (void)i; png_set_gamma(p, 2.2, 1.0); }
static void apply_gamma_dark(png_structp p, png_infop i) { (void)i; png_set_gamma(p, 1.0, 1.0 / 2.2); }
static void apply_gamma_slight(png_structp p, png_infop i) { (void)i; png_set_gamma(p, 1.0, 1.0 / 1.02); }
static void apply_gamma_steep(png_structp p, png_infop i) { (void)i; png_set_gamma(p, 4.0, 1.0 / 1.1); }
static void apply_gamma_shallow(png_structp p, png_infop i) { (void)i; png_set_gamma(p, 1.1, 1.0 / 4.0); }

static void apply_rgb_to_gray(png_structp p, png_infop i)
{
   (void)i;

   png_set_rgb_to_gray(p, PNG_ERROR_ACTION_NONE, -1, -1);
}

static void apply_rgb_to_gray_warn(png_structp p, png_infop i)
{
   (void)i;

   png_set_rgb_to_gray(p, PNG_ERROR_ACTION_WARN, -1, -1);
}

static void apply_rgb_to_gray_weighted(png_structp p, png_infop i)
{
   (void)i;

   /* Weights of the client's own rather than the defaults, so that the two paths are both driven. */
   png_set_rgb_to_gray(p, PNG_ERROR_ACTION_NONE, 0.4, 0.4);
}

/* Compositing against a background.
 *
 * The colour is given at the image's own depth, which is not a detail: a value scaled for sixteen bits
 * handed to an eight bit image is out of range, and the reference reads it as such and produces
 * something that is not a blend at all.  So the depth is asked for first and the values scaled to it.
 */
static void
compose_against(png_structp p, png_infop i, unsigned r, unsigned g, unsigned b, int code)
{
   png_color_16 background;

   /* Scaled to the image's own depth, which is not a detail worth glossing over: a value scaled for
    * sixteen bits handed to an eight bit image is out of range, and the reference reads it as such and
    * produces something that is not a blend at all.  A real client reads the depth and fills the
    * structure accordingly, so this does the same.
    */
   unsigned scale = png_get_bit_depth(p, i) == 16 ? 257 : 1;

   memset(&background, 0, sizeof background);
   background.red = (png_uint_16)(r * scale);
   background.green = (png_uint_16)(g * scale);
   background.blue = (png_uint_16)(b * scale);
   background.gray = (png_uint_16)(r * scale);

   png_set_background(p, &background, code, 0, 1.0);
}

static void apply_background(png_structp p, png_infop i)
{ compose_against(p, i, 128, 64, 192, PNG_BACKGROUND_GAMMA_SCREEN); }
static void apply_background_black(png_structp p, png_infop i)
{ compose_against(p, i, 0, 0, 0, PNG_BACKGROUND_GAMMA_SCREEN); }
static void apply_background_white(png_structp p, png_infop i)
{ compose_against(p, i, 255, 255, 255, PNG_BACKGROUND_GAMMA_SCREEN); }
static void apply_background_file(png_structp p, png_infop i)
{ compose_against(p, i, 128, 64, 192, PNG_BACKGROUND_GAMMA_FILE); }

/* The alpha arrangements.
 *
 * Each also settles the output gamma, which is the API's easier way of defaulting the file's: a file
 * with no gamma chunk is taken to have been encoded for the display just named.
 */
static void apply_alpha_png(png_structp p, png_infop i)
{ (void)i; png_set_alpha_mode(p, PNG_ALPHA_PNG, 2.2); }
static void apply_alpha_png_linear(png_structp p, png_infop i)
{ (void)i; png_set_alpha_mode(p, PNG_ALPHA_PNG, 1.0); }
static void apply_alpha_premultiplied(png_structp p, png_infop i)
{ (void)i; png_set_alpha_mode(p, PNG_ALPHA_STANDARD, 2.2); }
static void apply_alpha_premultiplied_linear(png_structp p, png_infop i)
{ (void)i; png_set_alpha_mode(p, PNG_ALPHA_STANDARD, 1.0); }
static void apply_alpha_optimized(png_structp p, png_infop i)
{ (void)i; png_set_alpha_mode(p, PNG_ALPHA_OPTIMIZED, 2.2); }
static void apply_alpha_broken(png_structp p, png_infop i)
{ (void)i; png_set_alpha_mode(p, PNG_ALPHA_BROKEN, 2.2); }

/* Transforms of the client's own.
 *
 * Three shapes of client, because the interesting question is not what the transform computes but
 * what it does to the row's description: one that leaves the shape alone, one that declares a wider
 * row and fills it, and one that declares a narrower row and collapses into it.  Each also reads the
 * description it is handed, so where the call sits in the order is visible in the output.
 */
static void invert_bytes(png_structp p, png_row_infop info, png_bytep row)
{
   (void)p;
   for (size_t k = 0; k < info->rowbytes; k++)
      row[k] = (png_byte)~row[k];
}

static void widen_to_eight(png_structp p, png_row_infop info, png_bytep row)
{
   /* One sample per byte, taken from whatever depth the row arrived at.  Written backwards so the
    * row can be expanded where it lies.
    */
   png_uint_32 x;
   int depth = info->bit_depth;
   unsigned max = (1u << depth) - 1u;

   (void)p;

   if (depth >= 8) return;

   for (x = info->width; x-- > 0; )
   {
      unsigned per_byte = 8u / (unsigned)depth;
      unsigned shift = (unsigned)(8 - depth) - (x % per_byte) * (unsigned)depth;
      unsigned sample = (row[x / per_byte] >> shift) & max;

      row[x] = (png_byte)(sample * 255u / max);
   }
}

static void first_channel_only(png_structp p, png_row_infop info, png_bytep row)
{
   png_uint_32 x;

   /* A row narrower than a byte has no channels to choose between, so it is widened instead: the
    * declared shape has to be filled whatever arrives, or the comparison is of leftover bytes.
    */
   if (info->bit_depth < 8) { widen_to_eight(p, info, row); return; }

   (void)p;

   if (info->bit_depth != 8) return;

   for (x = 0; x < info->width; x++)
      row[x] = row[x * info->channels];
}

static void apply_user_invert(png_structp p, png_infop i)
{ (void)i; png_set_read_user_transform_fn(p, invert_bytes); }

static void apply_user_widen(png_structp p, png_infop i)
{
   (void)i;
   png_set_read_user_transform_fn(p, widen_to_eight);
   png_set_user_transform_info(p, (png_voidp)"widen", 8, 1);
}

static void apply_user_first_channel(png_structp p, png_infop i)
{
   (void)i;
   png_set_read_user_transform_fn(p, first_channel_only);
   png_set_user_transform_info(p, (png_voidp)"first", 8, 1);
}

static void
apply_shift(png_structp p, png_infop i)
{
   (void)i;

   png_color_8 bits;

   /* Deliberately not the image's own depth, so that the transform has something to do whatever
    * the file said.
    */
   bits.red = 5;
   bits.green = 6;
   bits.blue = 5;
   bits.gray = 4;
   bits.alpha = 7;

   png_set_shift(p, &bits);
}

static const struct transform_entry transforms[] = {
   { "expand", apply_expand },
   { "palette_to_rgb", apply_palette_to_rgb },
   { "gray_1_2_4_to_8", apply_gray_1_2_4_to_8 },
   { "trns_to_alpha", apply_trns_to_alpha },
   { "expand_16", apply_expand_16 },
   { "strip_16", apply_strip_16 },
   { "scale_16", apply_scale_16 },
   { "strip_alpha", apply_strip_alpha },
   { "gray_to_rgb", apply_gray_to_rgb },
   { "packing", apply_packing },
   { "packswap", apply_packswap },
   { "bgr", apply_bgr },
   { "swap", apply_swap },
   { "swap_alpha", apply_swap_alpha },
   { "invert_alpha", apply_invert_alpha },
   { "invert_mono", apply_invert_mono },
   { "filler", apply_filler },
   { "filler_before", apply_filler_before },
   { "add_alpha", apply_add_alpha },
   { "shift", apply_shift },
   { "gamma_none", apply_gamma_none },
   { "gamma_bright", apply_gamma_bright },
   { "gamma_dark", apply_gamma_dark },
   { "gamma_slight", apply_gamma_slight },
   { "gamma_steep", apply_gamma_steep },
   { "gamma_shallow", apply_gamma_shallow },
   { "rgb_to_gray", apply_rgb_to_gray },
   { "rgb_to_gray_warn", apply_rgb_to_gray_warn },
   { "rgb_to_gray_weighted", apply_rgb_to_gray_weighted },
   { "background", apply_background },
   { "background_black", apply_background_black },
   { "background_white", apply_background_white },
   { "background_file", apply_background_file },
   { "alpha_png", apply_alpha_png },
   { "alpha_png_linear", apply_alpha_png_linear },
   { "alpha_premultiplied", apply_alpha_premultiplied },
   { "alpha_premultiplied_linear", apply_alpha_premultiplied_linear },
   { "alpha_optimized", apply_alpha_optimized },
   { "alpha_broken", apply_alpha_broken },
   { "user_invert", apply_user_invert },
   { "user_widen", apply_user_widen },
   { "user_first_channel", apply_user_first_channel },
};

#define TRANSFORM_COUNT ((int)(sizeof transforms / sizeof transforms[0]))

/* Applies the transforms named in a comma-separated list, in the order given.
 *
 * The order is honoured on the way in even though it must not affect the result — that is exactly
 * what makes it worth varying.
 */
static int
apply_transforms(png_structp png_ptr, png_infop info_ptr, const char *names)
{
   char buffer[512];
   char *cursor;
   char *token;

   if (names == NULL || names[0] == '\0')
      return 1;

   strncpy(buffer, names, sizeof buffer - 1);
   buffer[sizeof buffer - 1] = '\0';

   cursor = buffer;

   while ((token = strsep(&cursor, ",")) != NULL)
   {
      int index;
      int found = 0;

      if (token[0] == '\0')
         continue;

      for (index = 0; index < TRANSFORM_COUNT; ++index)
      {
         if (strcmp(token, transforms[index].name) == 0)
         {
            transforms[index].apply(png_ptr, info_ptr);
            found = 1;
            break;
         }
      }

      if (!found)
      {
         fprintf(stderr, "pngdump: unknown transform %s\n", token);
         return 0;
      }
   }

   return 1;
}

static int
dump_file(const char *path, enum read_mode mode, const char *transform_names)
{
   FILE *file;
   png_structp png_ptr;
   png_infop info_ptr = NULL;
   png_bytepp rows = NULL;
   png_uint_32 height = 0;
   png_uint_32 index;
   size_t rowbytes;
   int passes = 1;

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

      if (rows != NULL)
      {
         for (index = 0; index < height; ++index)
            free(rows[index]);
         free(rows);
      }

      png_destroy_read_struct(&png_ptr, &info_ptr, NULL);
      fclose(file);

      printf("balanced %d\n", allocation_count == free_count);
      return 0;
   }

   png_init_io(png_ptr, file);
   png_read_info(png_ptr, info_ptr);

   /* Where the library says it is, which a client watching from its own callback relies on. */
   printf("iostate 0x%x chunk 0x%x\n", (unsigned)png_get_io_state(png_ptr),
          (unsigned)png_get_io_chunk_type(png_ptr));

   dump_header(png_ptr, info_ptr);
   dump_metadata(png_ptr, info_ptr);

   if (!apply_transforms(png_ptr, info_ptr, transform_names))
   {
      png_destroy_read_struct(&png_ptr, &info_ptr, NULL);
      fclose(file);
      return 2;
   }

   /* Interlace handling is asked for before the transforms are resolved, not after.  It is itself a
    * transform — it changes what a row means — so requesting it once the row layout has been settled
    * is too late, and the reference does not recover from it.
    */
   if (mode == READ_ROWS)
      passes = png_set_interlace_handling(png_ptr);

   /* Resolved before anything is allocated, because this is what says how much to allocate: after
    * it, the accessors describe the rows about to be handed over rather than the ones in the file.
    */
   png_read_update_info(png_ptr, info_ptr);

   printf("updated");
   dump_header(png_ptr, info_ptr);

   height = png_get_image_height(png_ptr, info_ptr);
   rowbytes = png_get_rowbytes(png_ptr, info_ptr);

   /* Every row is allocated, in both modes.  An interlaced image is not decoded in row
    * order — a pass writes scattered rows — so there is nowhere to put a row until all of
    * them exist.  Cleared, because the passes fill them in over several sweeps and an
    * untouched pixel has to read the same in both libraries.
    */
   rows = calloc(height, sizeof (png_bytep));

   if (rows == NULL)
   {
      printf("row allocation failed\n");
      png_destroy_read_struct(&png_ptr, &info_ptr, NULL);
      fclose(file);
      return 1;
   }

   for (index = 0; index < height; ++index)
   {
      rows[index] = calloc(rowbytes != 0 ? rowbytes : 1, 1);

      if (rows[index] == NULL)
      {
         printf("row allocation failed\n");
         png_destroy_read_struct(&png_ptr, &info_ptr, NULL);
         fclose(file);
         return 1;
      }
   }

   if (mode == READ_IMAGE)
   {
      png_read_image(png_ptr, rows);
   }

   else
   {
      /* Every row, once per pass.  How many sweeps that is was settled above, before the layout
       * was.
       */
      int pass;

      for (pass = 0; pass < passes; ++pass)
      {
         for (index = 0; index < height; ++index)
            png_read_row(png_ptr, rows[index], NULL);
      }
   }

   for (index = 0; index < height; ++index)
      dump_row(index, rows[index], rowbytes);

   png_read_end(png_ptr, info_ptr);

   /* Again after the image data, since metadata is allowed on either side of it and a
    * client that reads to the end expects to see both.
    */
   printf("after end\n");
   dump_metadata(png_ptr, info_ptr);

   printf("done rows=%lu\n", (unsigned long)height);

   for (index = 0; index < height; ++index)
      free(rows[index]);
   free(rows);
   rows = NULL;

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
   enum read_mode mode = READ_ROWS;
   const char *transform_names = NULL;

   if (argc < 2 || argc > 4)
   {
      fprintf(stderr, "usage: pngdump <file.png> [rows|image] [transform,...]\n");
      return 2;
   }

   /* The names this build understands, so that anything driving it does not have to keep its own
    * copy of the list and drift out of step with this one.
    */
   if (strcmp(argv[1], "--transforms") == 0)
   {
      for (unsigned k = 0; k < sizeof transforms / sizeof *transforms; k++)
         printf("%s\n", transforms[k].name);

      return 0;
   }

   if (argc >= 3)
   {
      if (strcmp(argv[2], "image") == 0)
         mode = READ_IMAGE;

      else if (strcmp(argv[2], "rows") != 0)
      {
         fprintf(stderr, "pngdump: unknown mode %s\n", argv[2]);
         return 2;
      }
   }

   if (argc == 4)
      transform_names = argv[3];

   return dump_file(argv[1], mode, transform_names);
}
