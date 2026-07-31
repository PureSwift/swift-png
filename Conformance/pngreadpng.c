/* pngreadpng.c - read a whole file in one call, and say what came back
 *
 * The convenience form of reading, which is a different code path from the row-by-row one even though
 * it decodes the same image: the library makes the transform requests itself, allocates the rows, and
 * hands back an array.
 *
 * Driven over a few transform masks rather than all of them.  The masks are the ones that change the
 * row's shape, since those are where allocating the rows and reporting their size have to agree — a
 * mask that only rearranges bytes cannot get that wrong.
 *
 * usage: pngreadpng <file.png> <transform-mask>
 */

#include <png.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
   FILE *fp;
   png_structp p;
   png_infop i;
   png_bytepp rows;
   png_uint_32 y;
   int transforms;

   if (argc < 3)
   {
      fprintf(stderr, "usage: pngreadpng <file.png> <transform-mask>\n");
      return 2;
   }

   transforms = (int)strtol(argv[2], NULL, 0);
   fp = fopen(argv[1], "rb");

   if (fp == NULL) { printf("missing\n"); return 1; }

   p = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
   i = png_create_info_struct(p);

   if (setjmp(png_jmpbuf(p)))
   {
      printf("error\n");
      png_destroy_read_struct(&p, &i, NULL);
      fclose(fp);
      return 1;
   }

   png_init_io(p, fp);
   png_read_png(p, i, transforms, NULL);

   rows = png_get_rows(p, i);

   printf("ihdr width=%u height=%u depth=%d color=%d rowbytes=%u\n",
          (unsigned)png_get_image_width(p, i), (unsigned)png_get_image_height(p, i),
          png_get_bit_depth(p, i), png_get_color_type(p, i),
          (unsigned)png_get_rowbytes(p, i));

   for (y = 0; y < png_get_image_height(p, i); y++)
   {
      size_t k;

      printf("row %u", (unsigned)y);

      for (k = 0; k < png_get_rowbytes(p, i); k++)
         printf(" %02x", rows[y][k]);

      printf("\n");
   }

   png_destroy_read_struct(&p, &i, NULL);
   fclose(fp);

   return 0;
}
