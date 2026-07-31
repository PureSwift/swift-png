/* pngwrite.c - write a file, then say what is in it
 *
 * The writing counterpart of pngdump, and it cannot be checked the same way.  Two encoders that both
 * produce correct files need not produce the same bytes: the filter heuristic, the compressor's
 * choices and the chunk sizes are all free.  Comparing the files would test agreement on things the
 * format leaves open.
 *
 * So what is compared is what the file *means*.  This program writes an image it generates itself,
 * then reads that file back with the same library and prints the geometry and every row.  Run twice —
 * once against each library — the outputs must match, which says the two encoders wrote the same
 * picture and each could read it back.
 *
 * That leaves one gap, and the script next door closes it: a library could agree with itself while
 * writing something no other decoder understands.  So the files are also swapped, each library
 * reading the other's output.
 *
 * usage: pngwrite <output.png> <case> [dump]
 */

#include <png.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct image_case
{
   const char *name;
   png_uint_32 width;
   png_uint_32 height;
   int bit_depth;
   int color_type;
   int interlace;
   int filters;        /* -1 for the default */
   int level;          /* -1 for the default */
   int strategy;       /* -1 for the default */
   int metadata;       /* whether to set every chunk this program knows */
};

static const struct image_case cases[] = {
   { "gray8",        13,  7, 8, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1 , 0 },
   { "gray16",       11,  5, 16, PNG_COLOR_TYPE_GRAY,      0, -1, -1, -1 , 0 },
   { "gray1",        13,  5, 1, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1 , 0 },
   { "gray2",        13,  5, 2, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1 , 0 },
   { "gray4",        13,  5, 4, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1 , 0 },
   { "rgb8",         13,  7, 8, PNG_COLOR_TYPE_RGB,        0, -1, -1, -1 , 0 },
   { "rgb16",        11,  5, 16, PNG_COLOR_TYPE_RGB,       0, -1, -1, -1 , 0 },
   { "rgba8",        13,  7, 8, PNG_COLOR_TYPE_RGB_ALPHA,  0, -1, -1, -1 , 0 },
   { "graya8",       13,  7, 8, PNG_COLOR_TYPE_GRAY_ALPHA, 0, -1, -1, -1 , 0 },
   { "palette8",      9,  3, 8, PNG_COLOR_TYPE_PALETTE,    0, -1, -1, -1 , 0 },
   { "palette4",      9,  3, 4, PNG_COLOR_TYPE_PALETTE,    0, -1, -1, -1 , 0 },
   { "wide",        256,  2, 8, PNG_COLOR_TYPE_RGB,        0, -1, -1, -1 , 0 },
   { "tall",          2, 64, 8, PNG_COLOR_TYPE_RGB,        0, -1, -1, -1 , 0 },
   { "one_pixel",     1,  1, 8, PNG_COLOR_TYPE_RGB,        0, -1, -1, -1 , 0 },

   /* The filter choices, one at a time: each is a different scanline in the file even though every
    * one decodes to the same image.
    */
   { "filter_none",  13,  7, 8, PNG_COLOR_TYPE_RGB, 0, PNG_FILTER_NONE, -1, -1 , 0 },
   { "filter_sub",   13,  7, 8, PNG_COLOR_TYPE_RGB, 0, PNG_FILTER_SUB, -1, -1 , 0 },
   { "filter_up",    13,  7, 8, PNG_COLOR_TYPE_RGB, 0, PNG_FILTER_UP, -1, -1 , 0 },
   { "filter_avg",   13,  7, 8, PNG_COLOR_TYPE_RGB, 0, PNG_FILTER_AVG, -1, -1 , 0 },
   { "filter_paeth", 13,  7, 8, PNG_COLOR_TYPE_RGB, 0, PNG_FILTER_PAETH, -1, -1 , 0 },

   /* And the compressor's own settings, which change the bytes and not the picture. */
   { "level_0",      13,  7, 8, PNG_COLOR_TYPE_RGB, 0, -1, 0, -1 , 0 },
   { "level_9",      13,  7, 8, PNG_COLOR_TYPE_RGB, 0, -1, 9, -1 , 0 },
   /* Spelled out rather than named: zlib's header is not among the ones a libpng client is promised,
    * and the value is part of zlib's interface rather than a detail of this program.
    */
   { "strategy_rle", 13,  7, 8, PNG_COLOR_TYPE_RGB, 0, -1, -1, 3 , 0 },
   { "strategy_huffman", 13, 7, 8, PNG_COLOR_TYPE_RGB, 0, -1, -1, 2 , 0 },

   /* Everything the file can say about itself, over the colour types that carry those chunks
    * differently: a background is an index for one, a grey for another and a colour for the third.
    */
   /* Interlaced, at sizes where whole passes are empty and where a pass row ends part way through
    * a byte — the two places the geometry is easiest to get wrong.
    */
   { "interlaced_rgb8",   16, 16, 8, PNG_COLOR_TYPE_RGB,  1, -1, -1, -1, 0 },
   { "interlaced_rgba8",   9,  9, 8, PNG_COLOR_TYPE_RGB_ALPHA, 1, -1, -1, -1, 0 },
   { "interlaced_gray1",  13, 11, 1, PNG_COLOR_TYPE_GRAY, 1, -1, -1, -1, 0 },
   { "interlaced_gray2",   9,  9, 2, PNG_COLOR_TYPE_GRAY, 1, -1, -1, -1, 0 },
   { "interlaced_gray4",   3,  3, 4, PNG_COLOR_TYPE_GRAY, 1, -1, -1, -1, 0 },
   { "interlaced_rgb16",  11,  7, 16, PNG_COLOR_TYPE_RGB, 1, -1, -1, -1, 0 },
   { "interlaced_small",   1,  1, 8, PNG_COLOR_TYPE_RGB,  1, -1, -1, -1, 0 },
   { "interlaced_5x3",     5,  3, 8, PNG_COLOR_TYPE_RGB,  1, -1, -1, -1, 0 },
   { "interlaced_palette", 10, 10, 8, PNG_COLOR_TYPE_PALETTE, 1, -1, -1, -1, 0 },

   /* The three text chunks, which are one idea with three encodings.  Written both before and after
    * the rows, since the format allows either and a client means the difference.
    */
   { "text_rgb",     13,  7, 8, PNG_COLOR_TYPE_RGB,       0, -1, -1, -1, 3 },

   /* Flushed every other row, which cuts the compressed stream into pieces at points the encoder
    * would not otherwise have chosen — and must still decode to the same picture.
    */
   { "flushed",      13,  7, 8, PNG_COLOR_TYPE_RGB,       0, -1, -1, -1, 4 },

   /* Rows the client holds in a shape the format does not store: the write transforms.  Each is
    * numbered so the harness can ask for it, and the numbers carry on from the metadata cases.
    */
   { "w_bgr",        13,  7, 8, PNG_COLOR_TYPE_RGB,        0, -1, -1, -1, 10 },
   { "w_bgr_alpha",  13,  7, 8, PNG_COLOR_TYPE_RGB_ALPHA,  0, -1, -1, -1, 10 },
   { "w_swap",       11,  5, 16, PNG_COLOR_TYPE_RGB,       0, -1, -1, -1, 11 },
   { "w_swap_alpha", 13,  7, 8, PNG_COLOR_TYPE_RGB_ALPHA,  0, -1, -1, -1, 12 },
   { "w_invert_alpha", 13, 7, 8, PNG_COLOR_TYPE_RGB_ALPHA, 0, -1, -1, -1, 13 },
   { "w_invert_mono", 13, 7, 8, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1, 14 },
   { "w_invert_mono1", 13, 5, 1, PNG_COLOR_TYPE_GRAY,      0, -1, -1, -1, 14 },
   { "w_packing1",   13,  5, 1, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1, 15 },
   { "w_packing2",   13,  5, 2, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1, 15 },
   { "w_packing4",   13,  5, 4, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1, 15 },
   { "w_packswap",   13,  5, 2, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1, 16 },
   { "w_pack_swap",  13,  5, 2, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1, 17 },
   { "w_filler",     13,  7, 8, PNG_COLOR_TYPE_RGB,        0, -1, -1, -1, 18 },
   { "w_filler_before", 13, 7, 8, PNG_COLOR_TYPE_RGB,      0, -1, -1, -1, 19 },
   { "w_shift",      13,  7, 8, PNG_COLOR_TYPE_RGB,        0, -1, -1, -1, 20 },
   { "w_shift16",    11,  5, 16, PNG_COLOR_TYPE_RGB,       0, -1, -1, -1, 20 },
   { "w_shift_gray", 13,  7, 8, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1, 20 },
   { "w_bgr_swap_alpha", 13, 7, 8, PNG_COLOR_TYPE_RGB_ALPHA, 0, -1, -1, -1, 21 },
   { "w_filler_bgr", 13,  7, 8, PNG_COLOR_TYPE_RGB,        0, -1, -1, -1, 22 },
   { "w_shift_bgr",  13,  7, 8, PNG_COLOR_TYPE_RGB,        0, -1, -1, -1, 23 },
   { "w_pack_invert", 13, 5, 2, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1, 24 },
   { "w_interlaced_bgr", 9, 9, 8, PNG_COLOR_TYPE_RGB,      1, -1, -1, -1, 10 },

   /* A transform of the client's own, alone and before one of the library's. */
   { "w_user",       13,  7, 8, PNG_COLOR_TYPE_RGB,        0, -1, -1, -1, 25 },
   { "w_user_bgr",   13,  7, 8, PNG_COLOR_TYPE_RGB,        0, -1, -1, -1, 26 },
   { "w_user_pack",  13,  5, 2, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1, 27 },

   { "meta_rgb",     13,  7, 8, PNG_COLOR_TYPE_RGB,       0, -1, -1, -1, 1 },
   { "meta_gray",    13,  7, 8, PNG_COLOR_TYPE_GRAY,      0, -1, -1, -1, 1 },
   { "meta_palette",  9,  3, 8, PNG_COLOR_TYPE_PALETTE,   0, -1, -1, -1, 1 },

   /* The histogram on its own, because it cannot be compared with anything else.  The reference's
    * reader refuses the chunk wherever it appears, so a file carrying one reads back differently
    * whichever library wrote it — which is recorded next door, and would otherwise mask every other
    * chunk in the case it was bundled with.
    */
   { "hist_palette",  9,  3, 8, PNG_COLOR_TYPE_PALETTE,   0, -1, -1, -1, 2 },
   { "meta_rgba",    13,  7, 8, PNG_COLOR_TYPE_RGB_ALPHA, 0, -1, -1, -1, 1 },
};

/* Sets every chunk this program knows how to set.
 *
 * The values are arbitrary but distinct, so that a field written into the wrong place is visible
 * rather than plausible.
 */
/* A transform of the client's own: something visible, and something that depends on the description
 * it is handed, so that a library showing it the wrong one is caught.
 */
static void write_user(png_structp p, png_row_infop info, png_bytep row)
{
   size_t k;

   (void)p;

   for (k = 0; k < info->rowbytes; k++)
      row[k] = (png_byte)(row[k] ^ (png_byte)(info->channels * 16 + info->bit_depth));
}

static void set_metadata(png_structp p, png_infop i, const struct image_case *c)
{
   /* Two says to set the histogram as well, which is the one chunk that cannot be compared. */
   png_color_16 background;
   png_color_8 sig_bits;
   png_time when;
   png_uint_16 histogram[256];
   png_byte alphas[256];
   png_color_16 transparent;
   int k;

   png_set_gAMA_fixed(p, i, 45455);
   png_set_cHRM_fixed(p, i, 31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000);
   png_set_sRGB(p, i, PNG_sRGB_INTENT_PERCEPTUAL);

   memset(&sig_bits, 0, sizeof sig_bits);
   sig_bits.red = 5; sig_bits.green = 6; sig_bits.blue = 5; sig_bits.gray = 7; sig_bits.alpha = 4;
   png_set_sBIT(p, i, &sig_bits);

   memset(&background, 0, sizeof background);
   background.index = 3;
   background.red = 100; background.green = 200; background.blue = 30; background.gray = 128;
   png_set_bKGD(p, i, &background);

   png_set_pHYs(p, i, 2835, 2835, PNG_RESOLUTION_METER);
   png_set_oFFs(p, i, -12, 34, PNG_OFFSET_PIXEL);

   memset(&when, 0, sizeof when);
   when.year = 2026; when.month = 7; when.day = 30;
   when.hour = 12; when.minute = 34; when.second = 56;
   png_set_tIME(p, i, &when);

   if (c->color_type == PNG_COLOR_TYPE_PALETTE)
   {
      for (k = 0; k < 256; k++)
      {
         histogram[k] = (png_uint_16)(k * 3 + 1);
         alphas[k] = (png_byte)(k * 5);
      }

      if (c->metadata == 2) png_set_hIST(p, i, histogram);

      png_set_tRNS(p, i, alphas, 6, NULL);
   }
   else if (c->color_type == PNG_COLOR_TYPE_RGB)
   {
      memset(&transparent, 0, sizeof transparent);
      transparent.red = 12; transparent.green = 34; transparent.blue = 56;
      png_set_tRNS(p, i, NULL, 0, &transparent);
   }
   else if (c->color_type == PNG_COLOR_TYPE_GRAY)
   {
      memset(&transparent, 0, sizeof transparent);
      transparent.gray = 77;
      png_set_tRNS(p, i, NULL, 0, &transparent);
   }
}

static int channels_of(int color_type)
{
   switch (color_type)
   {
      case PNG_COLOR_TYPE_GRAY: return 1;
      case PNG_COLOR_TYPE_GRAY_ALPHA: return 2;
      case PNG_COLOR_TYPE_RGB: return 3;
      case PNG_COLOR_TYPE_RGB_ALPHA: return 4;
      default: return 1;
   }
}

/* The same picture whatever the shape, so a difference is never the generator's doing.
 *
 * Deliberately not smooth: a gradient would make every filter agree and the choice invisible.
 */
static void fill(png_bytep row, png_uint_32 y, const struct image_case *c)
{
   png_uint_32 width = c->width;
   int channels = channels_of(c->color_type);
   size_t rowbytes = ((size_t)width * channels * c->bit_depth + 7) / 8;
   size_t k;

   /* A client that packs its samples supplies one to a byte; one that supplies a filler channel
    * supplies a channel more.  Either way it hands over more than the file stores, so the row is
    * filled to whatever it is about to hand over rather than to what the file will hold.
    */
   if (c->metadata == 15 || c->metadata == 17 || c->metadata == 24 || c->metadata == 27)
      rowbytes = (size_t)width * channels;
   else if (c->metadata == 18 || c->metadata == 19 || c->metadata == 22)
      rowbytes = (size_t)width * (channels + 1) * c->bit_depth / 8;

   for (k = 0; k < rowbytes; k++)
      row[k] = (png_byte)((k * 37 + y * 101 + (k & 3) * 17) & 0xFF);
}

static int write_file(const char *path, const struct image_case *c)
{
   FILE *fp = fopen(path, "wb");
   png_structp p;
   png_infop i;
   png_bytep row;
   png_uint_32 y;
   png_color palette[256];
   int k;

   if (fp == NULL) return 1;

   p = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
   i = png_create_info_struct(p);

   if (setjmp(png_jmpbuf(p)))
   {
      png_destroy_write_struct(&p, &i);
      fclose(fp);
      printf("write error\n");
      return 1;
   }

   png_init_io(p, fp);
   png_set_IHDR(p, i, c->width, c->height, c->bit_depth, c->color_type,
                c->interlace ? PNG_INTERLACE_ADAM7 : PNG_INTERLACE_NONE,
                PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);

   if (c->color_type == PNG_COLOR_TYPE_PALETTE)
   {
      int entries = 1 << c->bit_depth;

      if (entries > 256) entries = 256;

      for (k = 0; k < entries; k++)
      {
         palette[k].red = (png_byte)(k * 7);
         palette[k].green = (png_byte)(k * 13);
         palette[k].blue = (png_byte)(k * 29);
      }

      png_set_PLTE(p, i, palette, entries);
   }

   if (c->metadata == 4) png_set_flush(p, 2);

   if (c->metadata == 3)
   {
      png_text texts[3];
      static char long_text[600];
      int k;

      /* Long enough that compressing it is worth something, and repetitive enough that the two
       * compressed forms have something to work with.
       */
      for (k = 0; k < (int)sizeof long_text - 1; k++)
         long_text[k] = (char)('a' + (k % 26));

      long_text[sizeof long_text - 1] = 0;

      memset(texts, 0, sizeof texts);

      texts[0].compression = PNG_TEXT_COMPRESSION_NONE;
      texts[0].key = "Title";
      texts[0].text = "a plain keyword and its text";

      texts[1].compression = PNG_TEXT_COMPRESSION_zTXt;
      texts[1].key = "Description";
      texts[1].text = long_text;

      texts[2].compression = PNG_ITXT_COMPRESSION_NONE;
      texts[2].key = "Comment";
      texts[2].text = "international, uncompressed";
      texts[2].lang = "en";
      texts[2].lang_key = "Comment";

      png_set_text(p, i, texts, 3);
   }
   else if (c->metadata == 1 || c->metadata == 2) set_metadata(p, i, c);

   if (c->filters >= 0) png_set_filter(p, PNG_FILTER_TYPE_BASE, c->filters);
   if (c->level >= 0) png_set_compression_level(p, c->level);
   if (c->strategy >= 0) png_set_compression_strategy(p, c->strategy);

   png_write_info(p, i);

   /* The write transforms, asked for after the header is written, which is where a client asks for
    * them and where the library has to be ready for them.
    */
   if (c->metadata >= 10)
   {
      png_color_8 sig;

      memset(&sig, 0, sizeof sig);
      sig.red = 5; sig.green = 6; sig.blue = 5; sig.alpha = 7;
      sig.gray = c->bit_depth >= 8 ? 5 : c->bit_depth;

      switch (c->metadata)
      {
         case 10: png_set_bgr(p); break;
         case 11: png_set_swap(p); break;
         case 12: png_set_swap_alpha(p); break;
         case 13: png_set_invert_alpha(p); break;
         case 14: png_set_invert_mono(p); break;
         case 15: png_set_packing(p); break;
         case 16: png_set_packswap(p); break;
         case 17: png_set_packing(p); png_set_packswap(p); break;
         case 18: png_set_filler(p, 0, PNG_FILLER_AFTER); break;
         case 19: png_set_filler(p, 0, PNG_FILLER_BEFORE); break;
         case 20: png_set_shift(p, &sig); break;
         case 21: png_set_bgr(p); png_set_swap_alpha(p); break;
         case 22: png_set_filler(p, 0, PNG_FILLER_BEFORE); png_set_bgr(p); break;
         case 23: png_set_shift(p, &sig); png_set_bgr(p); break;
         case 24: png_set_packing(p); png_set_invert_mono(p); break;
         case 25: png_set_write_user_transform_fn(p, write_user); break;
         case 26: png_set_write_user_transform_fn(p, write_user); png_set_bgr(p); break;
         case 27: png_set_write_user_transform_fn(p, write_user); png_set_packing(p); break;
      }
   }


   /* Generous: a client that packs its samples, or supplies a filler channel, hands over more bytes
    * than the file will store.
    */
   row = malloc(png_get_rowbytes(p, i) * 8 + 64);

   {
      /* Every row of the image, once per pass.  For an image that is not interlaced that is one
       * pass and the ordinary loop; for one that is, the library keeps the rows each pass wants and
       * counts the rest.
       */
      int passes = png_set_interlace_handling(p);
      int pass;

      for (pass = 0; pass < passes; pass++)
         for (y = 0; y < c->height; y++)
         {
            fill(row, y, c);
            png_write_row(p, row);
         }
   }

   if (c->metadata == 3)
   {
      /* Text set after the rows, which belongs after them in the file. */
      png_text after;

      memset(&after, 0, sizeof after);
      after.compression = PNG_ITXT_COMPRESSION_zTXt;
      after.key = "Software";
      after.text = "international, compressed, and written after the image data";
      after.lang = "en";
      after.lang_key = "Software";

      png_set_text(p, i, &after, 1);
   }

   png_write_end(p, c->metadata == 3 ? i : NULL);
   free(row);
   png_destroy_write_struct(&p, &i);
   fclose(fp);

   return 0;
}

/* What the file says about itself, in the order this program set it. */
static void dump_metadata(png_structp p, png_infop i)
{
   png_fixed_point gamma;
   png_fixed_point wx, wy, rx, ry, gx, gy, bx, by;
   int intent;
   png_color_8p sig_bits;
   png_color_16p background;
   png_uint_32 res_x, res_y;
   int unit_type;
   png_int_32 off_x, off_y;
   png_timep when;
   png_uint_16p histogram;
   png_bytep alphas;
   int num_alphas;
   png_color_16p transparent;

   if (png_get_gAMA_fixed(p, i, &gamma))
      printf("gama %d\n", (int)gamma);

   if (png_get_cHRM_fixed(p, i, &wx, &wy, &rx, &ry, &gx, &gy, &bx, &by))
      printf("chrm %d %d %d %d %d %d %d %d\n", (int)wx, (int)wy, (int)rx, (int)ry,
             (int)gx, (int)gy, (int)bx, (int)by);

   if (png_get_sRGB(p, i, &intent))
      printf("srgb %d\n", intent);

   if (png_get_sBIT(p, i, &sig_bits))
      printf("sbit r=%d g=%d b=%d gray=%d alpha=%d\n", sig_bits->red, sig_bits->green,
             sig_bits->blue, sig_bits->gray, sig_bits->alpha);

   if (png_get_bKGD(p, i, &background))
      printf("bkgd index=%d red=%d green=%d blue=%d gray=%d\n", background->index,
             background->red, background->green, background->blue, background->gray);

   if (png_get_pHYs(p, i, &res_x, &res_y, &unit_type))
      printf("phys x=%u y=%u unit=%d\n", (unsigned)res_x, (unsigned)res_y, unit_type);

   if (png_get_oFFs(p, i, &off_x, &off_y, &unit_type))
      printf("offs x=%d y=%d unit=%d\n", (int)off_x, (int)off_y, unit_type);

   if (png_get_tIME(p, i, &when))
      printf("time %d-%d-%d %d:%d:%d\n", when->year, when->month, when->day,
             when->hour, when->minute, when->second);

   if (png_get_hIST(p, i, &histogram))
   {
      int k;
      int entries = 0;
      png_colorp palette;

      png_get_PLTE(p, i, &palette, &entries);
      printf("hist");

      for (k = 0; k < entries; k++) printf(" %d", histogram[k]);

      printf("\n");
   }

   {
      png_textp texts;
      int count = png_get_text(p, i, &texts, NULL);
      int k;

      for (k = 0; k < count; k++)
         printf("text compression=%d key=%s lang=%s lang_key=%s len=%u text=%s\n",
                texts[k].compression, texts[k].key,
                texts[k].lang != NULL ? texts[k].lang : "",
                texts[k].lang_key != NULL ? texts[k].lang_key : "",
                (unsigned)texts[k].text_length,
                texts[k].text != NULL ? texts[k].text : "");
   }

   if (png_get_tRNS(p, i, &alphas, &num_alphas, &transparent))
   {
      int k;

      printf("trns count=%d:", num_alphas);

      /* The count is reported for a transparent colour too, where there is no table to go with it —
       * so the table is what says whether there is anything to print, not the count.
       */
      if (alphas != NULL)
         for (k = 0; k < num_alphas; k++) printf(" %02x", alphas[k]);

      if (transparent != NULL)
         printf(" color=%d,%d,%d,%d", transparent->red, transparent->green,
                transparent->blue, transparent->gray);

      printf("\n");
   }
}

/* Reads a file back and prints what it holds, which is the only thing worth comparing. */
static int dump_file(const char *path)
{
   FILE *fp = fopen(path, "rb");
   png_structp p;
   png_infop i;
   png_colorp palette;
   int entries;

   if (fp == NULL) { printf("missing\n"); return 1; }

   p = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
   i = png_create_info_struct(p);

   if (setjmp(png_jmpbuf(p)))
   {
      png_destroy_read_struct(&p, &i, NULL);
      fclose(fp);
      printf("read error\n");
      return 1;
   }

   png_init_io(p, fp);
   png_read_info(p, i);

   printf("ihdr width=%u height=%u depth=%d color=%d interlace=%d\n",
          (unsigned)png_get_image_width(p, i), (unsigned)png_get_image_height(p, i),
          png_get_bit_depth(p, i), png_get_color_type(p, i),
          png_get_interlace_type(p, i));

   if (png_get_PLTE(p, i, &palette, &entries))
   {
      int k;

      printf("plte count=%d:", entries);

      for (k = 0; k < entries; k++)
         printf(" %02x%02x%02x", palette[k].red, palette[k].green, palette[k].blue);

      printf("\n");
   }

   dump_metadata(p, i);

   {
      /* Read the whole image rather than pass by pass: what is being compared is the picture, and an
       * interlaced file holds the same one as a file that is not.
       */
      int passes = png_set_interlace_handling(p);
      png_uint_32 height = png_get_image_height(p, i);
      png_bytepp rows = malloc(sizeof(png_bytep) * height);
      png_uint_32 r;
      int pass;

      png_read_update_info(p, i);

      for (r = 0; r < height; r++)
         rows[r] = calloc(1, png_get_rowbytes(p, i) + 8);

      for (pass = 0; pass < passes; pass++)
         for (r = 0; r < height; r++)
            png_read_row(p, rows[r], NULL);

      for (r = 0; r < height; r++)
      {
         size_t k;

         printf("row %u", (unsigned)r);

         for (k = 0; k < png_get_rowbytes(p, i); k++)
            printf(" %02x", rows[r][k]);

         printf("\n");
         free(rows[r]);
      }

      free(rows);
   }

   png_read_end(p, NULL);
   png_destroy_read_struct(&p, &i, NULL);
   fclose(fp);

   return 0;
}

int main(int argc, char **argv)
{
   unsigned k;

   if (argc == 2 && strcmp(argv[1], "--cases") == 0)
   {
      for (k = 0; k < sizeof cases / sizeof *cases; k++)
         printf("%s\n", cases[k].name);

      return 0;
   }

   if (argc < 3)
   {
      fprintf(stderr, "usage: pngwrite <output.png> <case> [dump]\n");
      return 2;
   }

   /* Reading alone, for the swap: one library reads what the other wrote. */
   if (strcmp(argv[2], "dump") == 0)
      return dump_file(argv[1]);

   for (k = 0; k < sizeof cases / sizeof *cases; k++)
   {
      if (strcmp(cases[k].name, argv[2]) != 0) continue;

      if (write_file(argv[1], &cases[k]) != 0) return 1;

      return dump_file(argv[1]);
   }

   fprintf(stderr, "pngwrite: unknown case %s\n", argv[2]);
   return 2;
}
