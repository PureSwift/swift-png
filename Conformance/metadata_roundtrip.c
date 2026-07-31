/* metadata_roundtrip.c - drive every setter, then read it back
 *
 * The decode comparison exercises the getters thoroughly and the setters not at all: a
 * decoded file reaches the info structure through the parsers, never through
 * png_set_gAMA and its neighbours.  This walks the other direction — set a value, ask for
 * it back — and is compiled against each library so the two answers can be diffed.
 *
 * It touches no stream. Everything here works on an info structure alone, which is what
 * lets it run before this library can write a file.
 *
 * The values are deliberately awkward: extremes of each field's range, a background at the
 * top of what the bit depth allows, text with an empty value, a palette entry at both
 * ends. A setter that silently clamps or drops shows up as a differing line.
 */

#include <png.h>

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* The answers a library works out rather than stores.
 *
 * These are the accessors that convert rather than fetch: a timestamp as the line a mail header would
 * carry, the chromaticities as the matrix a colour space is quoted as, and the ceilings a decode will
 * not go past.  None of them is in a file, and all of them are things a client asks for.
 */
static void
report_derived(png_structp png_ptr, png_infop info_ptr)
{
   png_time when;
   char buffer[32];
   struct tm broken;

   memset(&when, 0, sizeof when);
   when.year = 2026; when.month = 7; when.day = 30;
   when.hour = 9; when.minute = 5; when.second = 3;

   if (png_convert_to_rfc1123_buffer(buffer, &when))
      printf("rfc1123 %s\n", buffer);
   else
      printf("rfc1123 refused\n");

   /* Every field out of range at once, which a file can say and a client should not be handed as a
    * date.
    */
   memset(&when, 0, sizeof when);
   when.month = 13; when.day = 0; when.hour = 25; when.minute = 61; when.second = 61;
   printf("rfc1123 out of range %d\n", png_convert_to_rfc1123_buffer(buffer, &when));

   /* Each field on its own, so that a check that is missing shows up as itself rather than being
    * hidden by the one next to it.
    */
   {
      static const int months[] = { 0, 1, 12, 13 };
      static const int days[] = { 0, 1, 31, 32 };
      static const int hours[] = { 0, 23, 24 };
      static const int seconds[] = { 0, 59, 60, 61 };
      unsigned k;

      for (k = 0; k < sizeof months / sizeof *months; k++)
      {
         memset(&when, 0, sizeof when);
         when.year = 2026; when.day = 1; when.month = (png_byte)months[k];
         printf("month %d -> %d\n", months[k], png_convert_to_rfc1123_buffer(buffer, &when));
      }

      for (k = 0; k < sizeof days / sizeof *days; k++)
      {
         memset(&when, 0, sizeof when);
         when.year = 2026; when.month = 1; when.day = (png_byte)days[k];
         printf("day %d -> %d\n", days[k], png_convert_to_rfc1123_buffer(buffer, &when));
      }

      for (k = 0; k < sizeof hours / sizeof *hours; k++)
      {
         memset(&when, 0, sizeof when);
         when.year = 2026; when.month = 1; when.day = 1; when.hour = (png_byte)hours[k];
         printf("hour %d -> %d\n", hours[k], png_convert_to_rfc1123_buffer(buffer, &when));
      }

      for (k = 0; k < sizeof seconds / sizeof *seconds; k++)
      {
         memset(&when, 0, sizeof when);
         when.year = 2026; when.month = 1; when.day = 1;
         when.second = (png_byte)seconds[k];
         printf("second %d -> %d\n", seconds[k], png_convert_to_rfc1123_buffer(buffer, &when));
      }
   }

   memset(&broken, 0, sizeof broken);
   broken.tm_year = 126; broken.tm_mon = 6; broken.tm_mday = 30;
   broken.tm_hour = 9; broken.tm_min = 5; broken.tm_sec = 3;
   png_convert_from_struct_tm(&when, &broken);
   printf("from tm %d-%d-%d %d:%d:%d\n", when.year, when.month, when.day,
          when.hour, when.minute, when.second);

   {
      static const long moments[] = { 0, 1000000000L, 1753900000L, 2000000000L };
      unsigned k;

      for (k = 0; k < sizeof moments / sizeof *moments; k++)
      {
         png_convert_from_time_t(&when, (time_t)moments[k]);
         printf("from time_t %ld -> %d-%d-%d %d:%d:%d\n", moments[k], when.year, when.month,
                when.day, when.hour, when.minute, when.second);
      }
   }

   {
      png_fixed_point rX, rY, rZ, gX, gY, gZ, bX, bY, bZ;

      if (png_get_cHRM_XYZ_fixed(png_ptr, info_ptr, &rX, &rY, &rZ, &gX, &gY, &gZ, &bX, &bY, &bZ))
         printf("chrm xyz %d %d %d %d %d %d %d %d %d\n", (int)rX, (int)rY, (int)rZ,
                (int)gX, (int)gY, (int)gZ, (int)bX, (int)bY, (int)bZ);
      else
         printf("chrm xyz refused\n");
   }

   printf("limits %u %u %u %u\n",
          (unsigned)png_get_user_width_max(png_ptr), (unsigned)png_get_user_height_max(png_ptr),
          (unsigned)png_get_chunk_cache_max(png_ptr),
          (unsigned)png_get_chunk_malloc_max(png_ptr));

   png_set_user_limits(png_ptr, 1000, 2000);
   png_set_chunk_cache_max(png_ptr, 7);
   png_set_chunk_malloc_max(png_ptr, 99);

   printf("limits set %u %u %u %u\n",
          (unsigned)png_get_user_width_max(png_ptr), (unsigned)png_get_user_height_max(png_ptr),
          (unsigned)png_get_chunk_cache_max(png_ptr),
          (unsigned)png_get_chunk_malloc_max(png_ptr));

   printf("palette max %d\n", png_get_palette_max(png_ptr, info_ptr));
}

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

/* A well-formed, empty colour profile.
 *
 * Two tags rather than one, because a profile describing fewer is refused however large it
 * is.
 */
static void
build_profile(png_bytep profile, png_uint_32 *length)
{
   static const char *tags[2] = { "wtpt", "rXYZ" };
   const png_uint_32 tag_data_offset = 132 + 12 * 2;
   const png_uint_32 tag_data_length = 20;
   const png_uint_32 total = tag_data_offset + tag_data_length * 2;
   png_uint_32 index;

   memset(profile, 0, total);

   png_save_uint_32(profile, total);
   memcpy(profile + 4, "none", 4);
   png_save_uint_32(profile + 8, 0x02100000);
   memcpy(profile + 12, "mntr", 4);
   memcpy(profile + 16, "RGB ", 4);
   memcpy(profile + 20, "XYZ ", 4);
   memcpy(profile + 36, "acsp", 4);
   memcpy(profile + 40, "APPL", 4);
   png_save_uint_32(profile + 64, 0);
   png_save_uint_32(profile + 68, 0x0000F6D6);
   png_save_uint_32(profile + 72, 0x00010000);
   png_save_uint_32(profile + 76, 0x0000D32D);
   png_save_uint_32(profile + 128, 2);

   for (index = 0; index < 2; ++index)
   {
      png_bytep entry = profile + 132 + 12 * index;
      png_bytep data = profile + tag_data_offset + tag_data_length * index;

      memcpy(entry, tags[index], 4);
      png_save_uint_32(entry + 4, tag_data_offset + tag_data_length * index);
      png_save_uint_32(entry + 8, tag_data_length);

      memcpy(data, "XYZ ", 4);
      png_save_uint_32(data + 8, 0x0000F6D6);
      png_save_uint_32(data + 12, 0x00010000);
      png_save_uint_32(data + 16, 0x0000D32D);
   }

   *length = total;
}

static void
apply(png_structp png_ptr, png_infop info_ptr)
{
   png_color palette[4];
   png_byte alpha[4];
   png_uint_16 histogram[4];
   png_color_16 background;
   png_color_8 sig_bit;
   png_time when;
   png_text text[3];
   png_byte profile[256];
   png_byte exif[8];
   png_uint_32 profile_length;
   int index;

   /* Indexed, so that the palette and the chunks sized against it are all meaningful. */
   png_set_IHDR(png_ptr, info_ptr, 4, 2, 8, PNG_COLOR_TYPE_PALETTE,
       PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_BASE, PNG_FILTER_TYPE_BASE);

   for (index = 0; index < 4; ++index)
   {
      palette[index].red = (png_byte)(index * 60);
      palette[index].green = (png_byte)(255 - index * 60);
      palette[index].blue = (png_byte)(index == 0 ? 0 : 255);
      alpha[index] = (png_byte)(index * 85);
      histogram[index] = (png_uint_16)(1000 * (index + 1));
   }

   png_set_PLTE(png_ptr, info_ptr, palette, 4);
   png_set_tRNS(png_ptr, info_ptr, alpha, 4, NULL);
   png_set_hIST(png_ptr, info_ptr, histogram);

   memset(&background, 0, sizeof background);
   background.index = 3;
   png_set_bKGD(png_ptr, info_ptr, &background);

   memset(&sig_bit, 0, sizeof sig_bit);
   sig_bit.red = 5;
   sig_bit.green = 6;
   sig_bit.blue = 5;
   png_set_sBIT(png_ptr, info_ptr, &sig_bit);

   /* The ends of the range, since a setter that truncates shows up here. */
   png_set_gAMA_fixed(png_ptr, info_ptr, 100000);
   png_set_cHRM_fixed(png_ptr, info_ptr, 31270, 32900, 64000, 33000, 30000, 60000,
       15000, 6000);
   png_set_sRGB(png_ptr, info_ptr, 3);

   png_set_pHYs(png_ptr, info_ptr, 3937, 3937, PNG_RESOLUTION_METER);
   png_set_oFFs(png_ptr, info_ptr, -2147483647, 2147483647, PNG_OFFSET_PIXEL);
   png_set_sCAL_s(png_ptr, info_ptr, 1, "12.5e3", "0.0001");

   memset(&when, 0, sizeof when);
   when.year = 2026;
   when.month = 12;
   when.day = 31;
   when.hour = 23;
   when.minute = 59;
   when.second = 60; /* a leap second, which the format allows */
   png_set_tIME(png_ptr, info_ptr, &when);

   png_set_cICP(png_ptr, info_ptr, 9, 16, 0, 1);
   png_set_cLLI_fixed(png_ptr, info_ptr, 10000000, 4000000);
   png_set_mDCV_fixed(png_ptr, info_ptr, 31270, 32900, 64000, 33000, 30000, 60000,
       15000, 6000, 10000000, 5);

   build_profile(profile, &profile_length);
   png_set_iCCP(png_ptr, info_ptr, "a profile", 0, profile, profile_length);

   memcpy(exif, "MM\0*\0\0\0\10", 8);
   png_set_eXIf_1(png_ptr, info_ptr, 8, exif);

   memset(text, 0, sizeof text);

   text[0].compression = PNG_TEXT_COMPRESSION_NONE;
   text[0].key = "Title";
   text[0].text = "a plain comment";

   /* An empty value, which is legitimate and distinguishable from an absent one. */
   text[1].compression = PNG_TEXT_COMPRESSION_NONE;
   text[1].key = "Empty";
   text[1].text = "";

   text[2].compression = PNG_ITXT_COMPRESSION_NONE;
   text[2].key = "Author";
   text[2].text = "a translated comment";
   text[2].lang = "en-GB";
   text[2].lang_key = "Author";

   png_set_text(png_ptr, info_ptr, text, 3);
}

/* Reads everything back.  Kept separate from apply() so that the order of the setters
 * cannot influence what a getter reports.
 */
static void
report(png_structp png_ptr, png_infop info_ptr)
{
   png_uint_32 width;
   png_uint_32 height;
   int bit_depth;
   int color_type;
   int interlace_type;
   int compression_type;
   int filter_type;
   png_colorp palette;
   int num_palette;
   png_bytep alpha;
   int num_alpha;
   png_color_16p trans_color;
   png_color_16p background;
   png_color_8p sig_bit;
   png_uint_16p histogram;
   png_fixed_point gamma;
   png_fixed_point chrm[8];
   int intent;
   png_uint_32 res_x;
   png_uint_32 res_y;
   int unit;
   png_int_32 off_x;
   png_int_32 off_y;
   png_charp scale_width;
   png_charp scale_height;
   png_timep when;
   png_byte primaries;
   png_byte transfer;
   png_byte matrix;
   png_byte range;
   png_uint_32 max_cll;
   png_uint_32 max_fall;
   png_uint_32 max_lum;
   png_uint_32 min_lum;
   png_charp profile_name;
   png_bytep profile;
   png_uint_32 profile_length;
   png_uint_32 num_exif;
   png_bytep exif;
   png_textp text;
   int num_text;
   int index;

   if (png_get_IHDR(png_ptr, info_ptr, &width, &height, &bit_depth, &color_type,
       &interlace_type, &compression_type, &filter_type) != 0)
   {
      printf("ihdr width=%lu height=%lu depth=%d color=%d interlace=%d\n",
          (unsigned long)width, (unsigned long)height, bit_depth, color_type,
          interlace_type);
   }

   printf("geometry channels=%d rowbytes=%lu\n",
       png_get_channels(png_ptr, info_ptr),
       (unsigned long)png_get_rowbytes(png_ptr, info_ptr));

   if (png_get_PLTE(png_ptr, info_ptr, &palette, &num_palette) != 0)
   {
      printf("plte count=%d", num_palette);
      for (index = 0; index < num_palette; ++index)
         printf(" %02x%02x%02x", palette[index].red, palette[index].green,
             palette[index].blue);
      printf("\n");
   }

   alpha = NULL;
   num_alpha = 0;
   trans_color = NULL;

   if (png_get_tRNS(png_ptr, info_ptr, &alpha, &num_alpha, &trans_color) != 0)
   {
      printf("trns count=%d", num_alpha);
      if (alpha != NULL)
      {
         for (index = 0; index < num_alpha; ++index)
            printf(" %02x", alpha[index]);
      }
      printf("\n");
   }

   if (png_get_hIST(png_ptr, info_ptr, &histogram) != 0)
   {
      printf("hist");
      for (index = 0; index < num_palette; ++index)
         printf(" %u", histogram[index]);
      printf("\n");
   }

   if (png_get_bKGD(png_ptr, info_ptr, &background) != 0)
      printf("bkgd index=%d red=%d green=%d blue=%d gray=%d\n", background->index,
          background->red, background->green, background->blue, background->gray);

   if (png_get_sBIT(png_ptr, info_ptr, &sig_bit) != 0)
      printf("sbit red=%d green=%d blue=%d gray=%d alpha=%d\n", sig_bit->red,
          sig_bit->green, sig_bit->blue, sig_bit->gray, sig_bit->alpha);

   if (png_get_gAMA_fixed(png_ptr, info_ptr, &gamma) != 0)
      printf("gama fixed=%ld\n", (long)gamma);

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

   if (png_get_pHYs(png_ptr, info_ptr, &res_x, &res_y, &unit) != 0)
      printf("phys x=%lu y=%lu unit=%d\n", (unsigned long)res_x, (unsigned long)res_y,
          unit);

   if (png_get_oFFs(png_ptr, info_ptr, &off_x, &off_y, &unit) != 0)
      printf("offs x=%ld y=%ld unit=%d\n", (long)off_x, (long)off_y, unit);

   if (png_get_sCAL_s(png_ptr, info_ptr, &unit, &scale_width, &scale_height) != 0)
      printf("scal unit=%d width=%s height=%s\n", unit, scale_width, scale_height);

   if (png_get_tIME(png_ptr, info_ptr, &when) != 0)
      printf("time %04d-%02d-%02d %02d:%02d:%02d\n", when->year, when->month, when->day,
          when->hour, when->minute, when->second);

   if (png_get_cICP(png_ptr, info_ptr, &primaries, &transfer, &matrix, &range) != 0)
      printf("cicp primaries=%d transfer=%d matrix=%d range=%d\n", primaries, transfer,
          matrix, range);

   if (png_get_cLLI_fixed(png_ptr, info_ptr, &max_cll, &max_fall) != 0)
      printf("clli max_cll=%lu max_fall=%lu\n", (unsigned long)max_cll,
          (unsigned long)max_fall);

   if (png_get_mDCV_fixed(png_ptr, info_ptr, &chrm[0], &chrm[1], &chrm[2], &chrm[3],
       &chrm[4], &chrm[5], &chrm[6], &chrm[7], &max_lum, &min_lum) != 0)
   {
      printf("mdcv");
      for (index = 0; index < 8; ++index)
         printf(" %ld", (long)chrm[index]);
      printf(" max=%lu min=%lu\n", (unsigned long)max_lum, (unsigned long)min_lum);
   }

   if (png_get_iCCP(png_ptr, info_ptr, &profile_name, &compression_type, &profile,
       &profile_length) != 0)
   {
      printf("iccp name=%s compression=%d length=%lu first=%02x last=%02x\n",
          profile_name, compression_type, (unsigned long)profile_length, profile[0],
          profile[profile_length - 1]);
   }

   if (png_get_eXIf_1(png_ptr, info_ptr, &num_exif, &exif) != 0)
   {
      printf("exif length=%lu", (unsigned long)num_exif);
      for (index = 0; index < (int)num_exif; ++index)
         printf(" %02x", exif[index]);
      printf("\n");
   }

   if (png_get_text(png_ptr, info_ptr, &text, &num_text) > 0)
   {
      printf("text count=%d\n", num_text);
      for (index = 0; index < num_text; ++index)
         printf("text %d compression=%d key=%s text=%s lang=%s lang_key=%s"
             " text_length=%lu itxt_length=%lu\n",
             index, text[index].compression,
             text[index].key != NULL ? text[index].key : "-",
             text[index].text != NULL ? text[index].text : "-",
             text[index].lang != NULL ? text[index].lang : "-",
             text[index].lang_key != NULL ? text[index].lang_key : "-",
             (unsigned long)text[index].text_length,
             (unsigned long)text[index].itxt_length);
   }

   /* The validity bits, which have to agree with what the getters reported above: a client
    * may test either.
    */
   printf("valid %lu\n", (unsigned long)png_get_valid(png_ptr, info_ptr, 0xFFFFFFFF));
}

int
main(void)
{
   png_structp png_ptr;
   png_infop info_ptr;

   /* A write structure, since these are the calls a client makes on the way to writing. */
   png_ptr = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, report_error,
       report_warning);

   if (png_ptr == NULL)
   {
      printf("create failed\n");
      return 1;
   }

   info_ptr = png_create_info_struct(png_ptr);

   if (info_ptr == NULL)
   {
      printf("create info failed\n");
      png_destroy_write_struct(&png_ptr, NULL);
      return 1;
   }

   if (setjmp(png_jmpbuf(png_ptr)) != 0)
   {
      printf("aborted\n");
      png_destroy_write_struct(&png_ptr, &info_ptr);
      return 0;
   }

   apply(png_ptr, info_ptr);
   report(png_ptr, info_ptr);
   report_derived(png_ptr, info_ptr);

   png_destroy_write_struct(&png_ptr, &info_ptr);

   printf("done\n");

   return 0;
}
