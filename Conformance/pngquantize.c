/* pngquantize.c - fitting images into fewer colours, said out loud
 *
 * The one request whose work happens when it is made: the palette handed in comes back shortened, so
 * what a client sees is that array and the rows that follow from it.  Both are printed here.
 *
 * The palettes are generated rather than read from files, because what matters is not any particular
 * picture but how the reduction behaves as the colours crowd together: a spread of colours over the
 * whole cube barely merges, and a cluster of near-identical ones merges over and over.  The generator
 * is a plain multiplier so both libraries are asked about exactly the same colours.
 */

#include <png.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Every line carries the case it belongs to, so a difference can be recorded case by case rather
 * than by the kind of line it appeared on. */
static char tag[32];

static unsigned seed = 1;

static unsigned next(void)
{
   seed = seed * 1103515245u + 12345u;
   return (seed >> 16) & 0x7fff;
}

static void quiet(png_structp p, png_const_charp message)
{
   (void)p;
   (void)message;
}

/* An indexed image whose pixels are simply the indices, so a row printed is the map itself. */
static void write_indexed(const char *path, png_color *palette, int n)
{
   FILE *f = fopen(path, "wb");
   png_structp p = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
   png_infop i = png_create_info_struct(p);
   unsigned char row[256];
   int k;

   if (setjmp(png_jmpbuf(p)))
   {
      printf("write failed\n");
      exit(1);
   }

   for (k = 0; k < n; k++) row[k] = (unsigned char)k;

   png_init_io(p, f);
   png_set_IHDR(p, i, (png_uint_32)n, 1, 8, PNG_COLOR_TYPE_PALETTE,
                PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
   png_set_PLTE(p, i, palette, n);
   png_write_info(p, i);
   png_write_row(p, row);
   png_write_end(p, i);
   png_destroy_write_struct(&p, &i);
   fclose(f);
}

/* A colour image sweeping the cube, which is what the lookup gets asked about. */
static void write_colour(const char *path, int with_alpha)
{
   FILE *f = fopen(path, "wb");
   png_structp p = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
   png_infop i = png_create_info_struct(p);
   unsigned char row[64 * 4];
   int k;

   if (setjmp(png_jmpbuf(p)))
   {
      printf("write failed\n");
      exit(1);
   }

   png_init_io(p, f);
   png_set_IHDR(p, i, 64, 1, 8,
                with_alpha ? PNG_COLOR_TYPE_RGB_ALPHA : PNG_COLOR_TYPE_RGB,
                PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
   png_write_info(p, i);

   for (k = 0; k < 64; k++)
   {
      int channels = with_alpha ? 4 : 3;
      row[k * channels + 0] = (unsigned char)(k * 4);
      row[k * channels + 1] = (unsigned char)(255 - k * 4);
      row[k * channels + 2] = (unsigned char)((k * 37) & 0xFF);
      if (with_alpha) row[k * channels + 3] = (unsigned char)(k * 3);
   }

   png_write_row(p, row);
   png_write_end(p, i);
   png_destroy_write_struct(&p, &i);
   fclose(f);
}

/* Reads a file back with the reduction asked for, and prints everything it can be seen by. */
static void run(const char *label, const char *path, png_color *palette, int n,
                int maximum, png_uint_16 *histogram, int full_quantize)
{
   FILE *f = fopen(path, "rb");
   png_structp p = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
   png_infop i;
   png_color copy[256];
   png_bytep row;
   png_uint_32 width, height;
   int depth, colour, interlace, compression, filter, k;

   png_set_error_fn(p, NULL, NULL, quiet);
   i = png_create_info_struct(p);

   printf("%s %s\n", tag, label);

   if (setjmp(png_jmpbuf(p)))
   {
      printf("%s refused\n", tag);
      fclose(f);
      return;
   }

   memcpy(copy, palette, sizeof (png_color) * (size_t)(n > 0 ? n : 1));

   png_init_io(p, f);
   png_read_info(p, i);
   png_set_quantize(p, n > 0 ? copy : NULL, n, maximum, histogram, full_quantize);

   printf("%s palette", tag);
   for (k = 0; k < n; k++)
      printf(" %d,%d,%d", copy[k].red, copy[k].green, copy[k].blue);
   printf("\n");

   png_read_update_info(p, i);
   png_get_IHDR(p, i, &width, &height, &depth, &colour, &interlace, &compression, &filter);
   printf("%s shape %dx%d depth %d colour %d channels %d rowbytes %d\n",
          tag, (int)width, (int)height, depth, colour,
          (int)png_get_channels(p, i), (int)png_get_rowbytes(p, i));

   row = malloc(png_get_rowbytes(p, i));

   for (k = 0; k < (int)height; k++)
   {
      int byte;
      png_read_row(p, row, NULL);
      printf("%s row", tag);
      for (byte = 0; byte < (int)png_get_rowbytes(p, i); byte++)
         printf(" %d", row[byte]);
      printf("\n");
   }

   free(row);
   png_read_end(p, i);
   png_destroy_read_struct(&p, &i, NULL);
   fclose(f);
}

int main(void)
{
   png_color palette[256];
   png_uint_16 histogram[256];
   char label[128];
   char indexed_path[64];
   char colour_path[64];
   int trial;

   /* Named for the process, because the two builds of this program are run against each other and
    * must not be writing over one another's working files. */
   sprintf(indexed_path, "quantize-%d.png", (int)getpid());
   sprintf(colour_path, "quantize-colour-%d.png", (int)getpid());

   /* Indexed images, with the palette shortened by every route there is. */
   for (trial = 0; trial < 60; trial++)
   {
      int n = 4 + (int)(next() % 29);
      int maximum = 1 + (int)(next() % (unsigned)n);
      int full_quantize = (int)(next() % 2);
      int with_histogram = (int)(next() % 2);
      int crowded = (int)(next() % 2);
      int k;

      for (k = 0; k < n; k++)
      {
         unsigned range = crowded ? 48u : 256u;
         palette[k].red = (png_byte)(next() % range);
         palette[k].green = (png_byte)(next() % range);
         palette[k].blue = (png_byte)(next() % range);
         histogram[k] = (png_uint_16)(next() % 40);
      }

      sprintf(tag, "case%d", trial);
      write_indexed(indexed_path, palette, n);

      sprintf(label, "indexed %d colours into %d, %s, %s, %s",
              n, maximum,
              full_quantize ? "the whole reduction" : "the palette only",
              with_histogram ? "with a histogram" : "with none",
              crowded ? "crowded" : "spread");

      run(label, indexed_path, palette, n, maximum,
          with_histogram ? histogram : NULL, full_quantize);
   }

   /* Colour images, which is what the lookup table is for. */
   {
      static const int sizes[] = {2, 5, 16, 64, 256};
      int which, alpha;

      for (alpha = 0; alpha < 2; alpha++)
      {
         write_colour(colour_path, alpha);

         for (which = 0; which < 5; which++)
         {
            int n = sizes[which];
            int k;

            /* A palette spread evenly enough that every part of the cube has something near it. */
            for (k = 0; k < n; k++)
            {
               palette[k].red = (png_byte)((k * 71) & 0xFF);
               palette[k].green = (png_byte)((k * 149) & 0xFF);
               palette[k].blue = (png_byte)((k * 233) & 0xFF);
            }

            sprintf(label, "%s onto %d colours", alpha ? "colour with alpha" : "colour", n);
            sprintf(tag, "colour%d-%d", alpha, which);
            run(label, colour_path, palette, n, n, NULL, 1);

            sprintf(label, "%s onto %d colours, palette only", alpha ? "colour with alpha" : "colour", n);
            sprintf(tag, "plain%d-%d", alpha, which);
            run(label, colour_path, palette, n, n, NULL, 0);
         }
      }
   }

   remove(indexed_path);
   remove(colour_path);

   return 0;
}
