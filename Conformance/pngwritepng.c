/* pngwritepng.c - write a file through png_write_png, then dump exactly what came out
 *
 * The convenience call that makes the ordinary write-side requests on a client's behalf, from a
 * bitmask, rather than the client calling png_set_packing/png_set_bgr/... itself. Each request's own
 * mechanics are covered by pngwrite.c's own transform cases; what is specific to this program is the
 * bitmask dispatch itself — the fixed order it applies requests in regardless of the order the bits
 * are named, which bits have no write-side meaning and are ignored, and what happens when the
 * request is contradictory or there is nothing to write at all.
 *
 * A transform bit is a deterministic rearrangement of bytes, not a choice the format leaves open, so
 * the file itself is compared here rather than only what it decodes back to — the same reasoning
 * pngwrite.c's own metadata cases already rely on for their transform-setting variants.
 *
 * usage: pngwritepng <output.png> <case> [dump]
 */

#include <png.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>

struct write_case
{
   const char *name;
   png_uint_32 width;
   png_uint_32 height;
   int bit_depth;
   int color_type;
   int transforms;
   int set_sbit;    /* whether to call png_set_sBIT before writing, for PNG_TRANSFORM_SHIFT */
   int set_rows;    /* whether to hand over rows at all */
};

static const struct write_case cases[] = {
   { "identity",        13, 7, 8, PNG_COLOR_TYPE_RGB,        PNG_TRANSFORM_IDENTITY, 0, 1 },
   { "invert_mono",     13, 7, 1, PNG_COLOR_TYPE_GRAY,       PNG_TRANSFORM_INVERT_MONO, 0, 1 },
   { "shift",           13, 7, 8, PNG_COLOR_TYPE_RGB,        PNG_TRANSFORM_SHIFT, 1, 1 },
   { "shift_no_sbit",   13, 7, 8, PNG_COLOR_TYPE_RGB,        PNG_TRANSFORM_SHIFT, 0, 1 },
   { "packing",         13, 7, 1, PNG_COLOR_TYPE_GRAY,       PNG_TRANSFORM_PACKING, 0, 1 },
   { "packing_depth2",  13, 7, 2, PNG_COLOR_TYPE_GRAY,       PNG_TRANSFORM_PACKING, 0, 1 },
   { "packing_depth4",  13, 7, 4, PNG_COLOR_TYPE_GRAY,       PNG_TRANSFORM_PACKING, 0, 1 },
   { "swap_alpha",       9, 5, 8, PNG_COLOR_TYPE_RGB_ALPHA,  PNG_TRANSFORM_SWAP_ALPHA, 0, 1 },
   { "strip_filler_after",  9, 5, 8, PNG_COLOR_TYPE_RGB,     PNG_TRANSFORM_STRIP_FILLER_AFTER, 0, 1 },
   { "strip_filler_before", 9, 5, 8, PNG_COLOR_TYPE_RGB,     PNG_TRANSFORM_STRIP_FILLER_BEFORE, 0, 1 },
   { "strip_filler_both",   9, 5, 8, PNG_COLOR_TYPE_RGB,
       PNG_TRANSFORM_STRIP_FILLER_BEFORE | PNG_TRANSFORM_STRIP_FILLER_AFTER, 0, 1 },
   { "bgr",              9, 5, 8, PNG_COLOR_TYPE_RGB,        PNG_TRANSFORM_BGR, 0, 1 },
   { "swap_endian",      9, 5, 16, PNG_COLOR_TYPE_RGB,       PNG_TRANSFORM_SWAP_ENDIAN, 0, 1 },
   { "packswap",        13, 7, 1, PNG_COLOR_TYPE_GRAY,       PNG_TRANSFORM_PACKSWAP, 0, 1 },
   { "invert_alpha",     9, 5, 8, PNG_COLOR_TYPE_RGB_ALPHA,  PNG_TRANSFORM_INVERT_ALPHA, 0, 1 },

   /* Combinations, in an order that does not match the fixed order they are applied in — asking
    * that way is the whole point of the convenience call.
    */
   { "combo_bgr_swap_alpha", 9, 5, 8, PNG_COLOR_TYPE_RGB_ALPHA,
       PNG_TRANSFORM_SWAP_ALPHA | PNG_TRANSFORM_BGR, 0, 1 },
   { "combo_pack_swap",  13, 7, 1, PNG_COLOR_TYPE_GRAY,
       PNG_TRANSFORM_PACKSWAP | PNG_TRANSFORM_PACKING, 0, 1 },

   /* Read-only bits: png_write_png has nothing to do with these, so a file written with them set
    * has to come out identical to one written with PNG_TRANSFORM_IDENTITY.
    */
   { "read_only_bits_ignored", 13, 7, 8, PNG_COLOR_TYPE_RGB,
       PNG_TRANSFORM_STRIP_16 | PNG_TRANSFORM_STRIP_ALPHA | PNG_TRANSFORM_EXPAND
           | PNG_TRANSFORM_GRAY_TO_RGB | PNG_TRANSFORM_EXPAND_16 | PNG_TRANSFORM_SCALE_16, 0, 1 },

   /* No rows ever handed over. */
   { "no_rows", 13, 7, 8, PNG_COLOR_TYPE_RGB, PNG_TRANSFORM_IDENTITY, 0, 0 },
};

static int channels_of(int color_type)
{
   switch (color_type)
   {
      case PNG_COLOR_TYPE_GRAY: return 1;
      case PNG_COLOR_TYPE_RGB: return 3;
      case PNG_COLOR_TYPE_RGB_ALPHA: return 4;
      default: return 1;
   }
}

/* A client that strips a filler hands over one channel more than the file will store — the byte
 * png_set_filler is about to remove has to be there to remove.  Every other transform here changes
 * the shape of the file's own row, not the shape of what the client supplies.
 */
static int client_channels(const struct write_case *c)
{
   int channels = channels_of(c->color_type);

   if ((c->transforms & (PNG_TRANSFORM_STRIP_FILLER_AFTER | PNG_TRANSFORM_STRIP_FILLER_BEFORE)) != 0)
      channels += 1;

   return channels;
}

static size_t rowbytes_of(const struct write_case *c, int channels)
{
   png_uint_32 samples_per_row = c->width * (png_uint_32)channels;

   if (c->bit_depth < 8)
      return (samples_per_row * (png_uint_32)c->bit_depth + 7) / 8;

   return (size_t)samples_per_row * (size_t)(c->bit_depth > 8 ? 2 : 1);
}

static int write_file(const char *path, const struct write_case *c)
{
   FILE *fp = fopen(path, "wb");
   png_structp p;
   png_infop i;
   png_bytep *rows = NULL;
   png_uint_32 y;
   int channels;
   size_t rowbytes;

   if (fp == NULL) return 1;

   p = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
   i = png_create_info_struct(p);

   if (setjmp(png_jmpbuf(p)))
   {
      png_destroy_write_struct(&p, &i);
      fclose(fp);

      if (rows != NULL)
      {
         for (y = 0; y < c->height; y++)
            free(rows[y]);

         free(rows);
      }

      printf("write error\n");
      return 1;
   }

   png_init_io(p, fp);
   png_set_IHDR(p, i, c->width, c->height, c->bit_depth, c->color_type,
       PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);

   if (c->set_sbit)
   {
      png_color_8 sig_bit;

      memset(&sig_bit, 0, sizeof sig_bit);
      sig_bit.red = 5;
      sig_bit.green = 6;
      sig_bit.blue = 5;
      sig_bit.gray = 5;
      sig_bit.alpha = 8;

      png_set_sBIT(p, i, &sig_bit);
   }

   channels = client_channels(c);
   rowbytes = rowbytes_of(c, channels);

   if (c->set_rows)
   {
      rows = malloc(c->height * sizeof(png_bytep));

      for (y = 0; y < c->height; ++y)
      {
         size_t k;

         rows[y] = malloc(rowbytes != 0 ? rowbytes : 1);

         /* Deliberately not smooth, so a byte moved to the wrong place is visible. */
         for (k = 0; k < rowbytes; ++k)
            rows[y][k] = (png_byte)((y * 37 + k * 29 + (k & 3) * 11) & 0xFF);
      }

      png_set_rows(p, i, rows);
   }

   png_write_png(p, i, c->transforms, NULL);

   png_destroy_write_struct(&p, &i);
   fclose(fp);

   if (rows != NULL)
   {
      for (y = 0; y < c->height; y++)
         free(rows[y]);

      free(rows);
   }

   return 0;
}

static int dump_file(const char *path)
{
   FILE *fp = fopen(path, "rb");
   png_structp p;
   png_infop i;
   size_t rowbytes;
   png_bytep row;
   png_uint_32 width, height, y;
   int bit_depth, color_type;

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
   png_get_IHDR(p, i, &width, &height, &bit_depth, &color_type, NULL, NULL, NULL);

   printf("ihdr width=%u height=%u depth=%d color=%d\n",
       (unsigned)width, (unsigned)height, bit_depth, color_type);

   rowbytes = png_get_rowbytes(p, i);
   row = malloc(rowbytes != 0 ? rowbytes : 1);

   for (y = 0; y < height; ++y)
   {
      size_t k;

      png_read_row(p, row, NULL);

      printf("row %u", (unsigned)y);

      for (k = 0; k < rowbytes; ++k)
         printf(" %02x", row[k]);

      printf("\n");
   }

   png_read_end(p, NULL);
   png_destroy_read_struct(&p, &i, NULL);
   free(row);
   fclose(fp);

   return 0;
}

int main(int argc, char **argv)
{
   size_t k;

   if (argc == 2 && strcmp(argv[1], "--cases") == 0)
   {
      for (k = 0; k < sizeof(cases) / sizeof(cases[0]); ++k)
         printf("%s\n", cases[k].name);

      return 0;
   }

   if (argc < 3)
   {
      fprintf(stderr, "usage: pngwritepng <output.png> <case> [dump]\n");
      return 2;
   }

   /* Reading alone, for the swap: one library reads what the other wrote. */
   if (strcmp(argv[2], "dump") == 0)
      return dump_file(argv[1]);

   for (k = 0; k < sizeof(cases) / sizeof(cases[0]); ++k)
   {
      if (strcmp(cases[k].name, argv[2]) != 0) continue;

      if (write_file(argv[1], &cases[k]) != 0) return 1;

      return dump_file(argv[1]);
   }

   fprintf(stderr, "pngwritepng: unknown case %s\n", argv[2]);
   return 2;
}
