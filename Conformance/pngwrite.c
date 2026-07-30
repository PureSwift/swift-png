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
};

static const struct image_case cases[] = {
   { "gray8",        13,  7, 8, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1 },
   { "gray16",       11,  5, 16, PNG_COLOR_TYPE_GRAY,      0, -1, -1, -1 },
   { "gray1",        13,  5, 1, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1 },
   { "gray2",        13,  5, 2, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1 },
   { "gray4",        13,  5, 4, PNG_COLOR_TYPE_GRAY,       0, -1, -1, -1 },
   { "rgb8",         13,  7, 8, PNG_COLOR_TYPE_RGB,        0, -1, -1, -1 },
   { "rgb16",        11,  5, 16, PNG_COLOR_TYPE_RGB,       0, -1, -1, -1 },
   { "rgba8",        13,  7, 8, PNG_COLOR_TYPE_RGB_ALPHA,  0, -1, -1, -1 },
   { "graya8",       13,  7, 8, PNG_COLOR_TYPE_GRAY_ALPHA, 0, -1, -1, -1 },
   { "palette8",      9,  3, 8, PNG_COLOR_TYPE_PALETTE,    0, -1, -1, -1 },
   { "palette4",      9,  3, 4, PNG_COLOR_TYPE_PALETTE,    0, -1, -1, -1 },
   { "wide",        256,  2, 8, PNG_COLOR_TYPE_RGB,        0, -1, -1, -1 },
   { "tall",          2, 64, 8, PNG_COLOR_TYPE_RGB,        0, -1, -1, -1 },
   { "one_pixel",     1,  1, 8, PNG_COLOR_TYPE_RGB,        0, -1, -1, -1 },

   /* The filter choices, one at a time: each is a different scanline in the file even though every
    * one decodes to the same image.
    */
   { "filter_none",  13,  7, 8, PNG_COLOR_TYPE_RGB, 0, PNG_FILTER_NONE, -1, -1 },
   { "filter_sub",   13,  7, 8, PNG_COLOR_TYPE_RGB, 0, PNG_FILTER_SUB, -1, -1 },
   { "filter_up",    13,  7, 8, PNG_COLOR_TYPE_RGB, 0, PNG_FILTER_UP, -1, -1 },
   { "filter_avg",   13,  7, 8, PNG_COLOR_TYPE_RGB, 0, PNG_FILTER_AVG, -1, -1 },
   { "filter_paeth", 13,  7, 8, PNG_COLOR_TYPE_RGB, 0, PNG_FILTER_PAETH, -1, -1 },

   /* And the compressor's own settings, which change the bytes and not the picture. */
   { "level_0",      13,  7, 8, PNG_COLOR_TYPE_RGB, 0, -1, 0, -1 },
   { "level_9",      13,  7, 8, PNG_COLOR_TYPE_RGB, 0, -1, 9, -1 },
   /* Spelled out rather than named: zlib's header is not among the ones a libpng client is promised,
    * and the value is part of zlib's interface rather than a detail of this program.
    */
   { "strategy_rle", 13,  7, 8, PNG_COLOR_TYPE_RGB, 0, -1, -1, 3 },
   { "strategy_huffman", 13, 7, 8, PNG_COLOR_TYPE_RGB, 0, -1, -1, 2 },
};

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

   if (c->filters >= 0) png_set_filter(p, PNG_FILTER_TYPE_BASE, c->filters);
   if (c->level >= 0) png_set_compression_level(p, c->level);
   if (c->strategy >= 0) png_set_compression_strategy(p, c->strategy);

   png_write_info(p, i);

   row = malloc(png_get_rowbytes(p, i) + 8);

   for (y = 0; y < c->height; y++)
   {
      fill(row, y, c);
      png_write_row(p, row);
   }

   png_write_end(p, NULL);
   free(row);
   png_destroy_write_struct(&p, &i);
   fclose(fp);

   return 0;
}

/* Reads a file back and prints what it holds, which is the only thing worth comparing. */
static int dump_file(const char *path)
{
   FILE *fp = fopen(path, "rb");
   png_structp p;
   png_infop i;
   png_bytep row;
   png_uint_32 y;
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

   row = malloc(png_get_rowbytes(p, i) + 8);

   for (y = 0; y < png_get_image_height(p, i); y++)
   {
      size_t k;

      png_read_row(p, row, NULL);
      printf("row %u", (unsigned)y);

      for (k = 0; k < png_get_rowbytes(p, i); k++)
         printf(" %02x", row[k]);

      printf("\n");
   }

   png_read_end(p, NULL);
   free(row);
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
