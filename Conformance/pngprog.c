/* pngprog.c - decode a file by pushing it in, a few bytes at a time
 *
 * The progressive reader, which is the sequential one turned inside out: the client hands over
 * whatever has arrived and is called back with whatever that completes.  A client reading from a
 * network works this way because it cannot promise to produce a scanline on demand.
 *
 * What is printed is everything the callbacks report — the header when it is complete, every row with
 * the number and pass it was given, and the end.  Run against both libraries the outputs must match,
 * and they must also match at every block size: a decoder that only works when whole chunks arrive at
 * once is not a progressive decoder.
 *
 * usage: pngprog <file.png> <block-size>
 */

#include <png.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static png_bytepp image_rows;
static png_uint_32 image_height;
static size_t image_rowbytes;

static void on_info(png_structp p, png_infop i)
{
   png_uint_32 y;

   printf("info width=%u height=%u depth=%d color=%d interlace=%d\n",
          (unsigned)png_get_image_width(p, i), (unsigned)png_get_image_height(p, i),
          png_get_bit_depth(p, i), png_get_color_type(p, i),
          png_get_interlace_type(p, i));

   /* Asking for the passes to be placed for us, which is what makes the rows the client assembles
    * into the whole image rather than into seven subimages.
    */
   png_set_interlace_handling(p);
   png_read_update_info(p, i);

   image_height = png_get_image_height(p, i);
   image_rowbytes = png_get_rowbytes(p, i);
   image_rows = malloc(sizeof(png_bytep) * (image_height ? image_height : 1));

   for (y = 0; y < image_height; y++)
      image_rows[y] = calloc(1, image_rowbytes + 8);
}

static void on_row(png_structp p, png_bytep new_row, png_uint_32 row_number, int pass)
{
   printf("row number=%u pass=%d", (unsigned)row_number, pass);

   if (new_row == NULL)
   {
      /* A row the library is not delivering, which for an interlaced image it does for the rows a
       * pass does not contain.
       */
      printf(" (none)\n");
      return;
   }

   printf("\n");

   if (row_number < image_height)
      png_progressive_combine_row(p, image_rows[row_number], new_row);
}

static void on_end(png_structp p, png_infop i)
{
   png_uint_32 y;
   size_t k;

   (void)p;
   (void)i;

   printf("end\n");

   for (y = 0; y < image_height; y++)
   {
      printf("row %u", (unsigned)y);

      for (k = 0; k < image_rowbytes; k++)
         printf(" %02x", image_rows[y][k]);

      printf("\n");
   }
}

int main(int argc, char **argv)
{
   FILE *fp;
   png_structp p;
   png_infop i;
   unsigned char *buffer;
   size_t block;
   size_t n;

   if (argc < 3)
   {
      fprintf(stderr, "usage: pngprog <file.png> <block-size>\n");
      return 2;
   }

   block = (size_t)atoi(argv[2]);

   if (block == 0) block = 1;

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

   png_set_progressive_read_fn(p, (void *)"progressive", on_info, on_row, on_end);

   buffer = malloc(block);

   while ((n = fread(buffer, 1, block, fp)) > 0)
      png_process_data(p, i, buffer, n);

   free(buffer);
   png_destroy_read_struct(&p, &i, NULL);
   fclose(fp);

   return 0;
}
