/* pngbench.c - how long each library takes over the same work
 *
 * Compiled twice, like the comparisons next door, and run over the same files.  What is timed is the
 * library and nothing else: the file is read into memory first and decoded from there, and what is
 * written goes nowhere, so no measurement includes the disk.
 *
 * Each case runs many times and the *best* time is kept rather than the average.  A benchmark on a
 * machine doing other things measures the library plus whatever else ran; the fastest run is the one
 * least disturbed by that, and it is the number that moves when the library changes.
 *
 * Three cases, because they exercise different halves.  A plain decode is the row pipeline with
 * nothing switched on.  A decode with transforms adds the tables and the per-sample work.  An encode
 * is the filter search and the compressor, which is usually the slowest thing either library does.
 *
 * usage: pngbench <file.png> [rounds]
 */

#include <png.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct memory {
   png_bytep data;
   size_t size;
   size_t offset;
};

static void PNGCBAPI take_from_memory(png_structp png_ptr, png_bytep into, size_t count)
{
   struct memory *m = png_get_io_ptr(png_ptr);

   if (m->offset + count > m->size)
      png_error(png_ptr, "ran out of file");

   memcpy(into, m->data + m->offset, count);
   m->offset += count;
}

/* Counted rather than kept: what an encode produces is not wanted, only how long it took. */
static void PNGCBAPI count_written(png_structp png_ptr, png_bytep data, size_t count)
{
   struct memory *m = png_get_io_ptr(png_ptr);

   (void)data;
   m->offset += count;
}

static void PNGCBAPI settled(png_structp png_ptr) { (void)png_ptr; }
static void PNGCBAPI quiet(png_structp png_ptr, png_const_charp message)
{
   (void)png_ptr;
   (void)message;
}

static double now(void)
{
   struct timespec t;
   clock_gettime(CLOCK_MONOTONIC, &t);
   return (double)t.tv_sec * 1000.0 + (double)t.tv_nsec / 1000000.0;
}

/* One decode, with the transforms switched on or off.  Returns the rows produced. */
static long decode(struct memory *file, int transformed, png_bytepp rows, int keep)
{
   png_structp p = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, quiet);
   png_infop i;
   png_uint_32 width, height;
   int depth, colour, interlace, compression, filter, y, pass, passes = 1;
   long produced = 0;
   png_bytep row = NULL;

   if (p == NULL)
      return -1;

   png_set_error_fn(p, NULL, NULL, quiet);
   i = png_create_info_struct(p);

   if (setjmp(png_jmpbuf(p)))
   {
      free(row);
      png_destroy_read_struct(&p, &i, NULL);
      return -1;
   }

   file->offset = 0;
   png_set_read_fn(p, file, take_from_memory);
   png_read_info(p, i);
   png_get_IHDR(p, i, &width, &height, &depth, &colour, &interlace, &compression, &filter);

   if (transformed)
   {
      png_set_expand(p);
      png_set_gray_to_rgb(p);
      png_set_add_alpha(p, 0xFFFF, PNG_FILLER_AFTER);
      png_set_gamma(p, 2.2, 0.45455);
      png_set_scale_16(p);
   }

   if (interlace)
      passes = png_set_interlace_handling(p);

   png_read_update_info(p, i);

   if (!keep)
      row = malloc(png_get_rowbytes(p, i));

   for (pass = 0; pass < passes; pass++)
      for (y = 0; y < (int)height; y++)
      {
         png_read_row(p, keep ? rows[y] : row, NULL);
         produced++;
      }

   png_read_end(p, NULL);
   free(row);
   png_destroy_read_struct(&p, &i, NULL);

   return produced;
}

/* Reads the image once, keeping the rows, so an encode has something to write. */
static png_bytepp keep_rows(struct memory *file, png_uint_32 *width, png_uint_32 *height,
                            int *depth, int *colour, size_t *stride)
{
   png_structp p = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, quiet);
   png_infop i;
   int interlace, compression, filter, y, pass, passes = 1;
   png_bytepp rows;

   png_set_error_fn(p, NULL, NULL, quiet);
   i = png_create_info_struct(p);

   if (setjmp(png_jmpbuf(p)))
   {
      png_destroy_read_struct(&p, &i, NULL);
      return NULL;
   }

   file->offset = 0;
   png_set_read_fn(p, file, take_from_memory);
   png_read_info(p, i);
   png_get_IHDR(p, i, width, height, depth, colour, &interlace, &compression, &filter);

   if (interlace)
      passes = png_set_interlace_handling(p);

   png_read_update_info(p, i);
   *stride = png_get_rowbytes(p, i);

   rows = malloc(sizeof (png_bytep) * *height);

   for (y = 0; y < (int)*height; y++)
      rows[y] = calloc(1, *stride);

   for (pass = 0; pass < passes; pass++)
      for (y = 0; y < (int)*height; y++)
         png_read_row(p, rows[y], NULL);

   png_read_end(p, NULL);
   png_destroy_read_struct(&p, &i, NULL);

   return rows;
}

static long encode(png_bytepp rows, png_uint_32 width, png_uint_32 height, int depth, int colour)
{
   struct memory sink = { NULL, 0, 0 };
   png_structp p = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, quiet);
   png_infop i;
   int y;

   if (p == NULL)
      return -1;

   png_set_error_fn(p, NULL, NULL, quiet);
   i = png_create_info_struct(p);

   if (setjmp(png_jmpbuf(p)))
   {
      png_destroy_write_struct(&p, &i);
      return -1;
   }

   png_set_write_fn(p, &sink, count_written, settled);
   png_set_IHDR(p, i, width, height, depth, colour,
                PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
   png_write_info(p, i);

   for (y = 0; y < (int)height; y++)
      png_write_row(p, rows[y]);

   png_write_end(p, i);
   png_destroy_write_struct(&p, &i);

   return (long)sink.offset;
}

int main(int argc, char **argv)
{
   struct memory file;
   FILE *f;
   int rounds = argc > 2 ? atoi(argv[2]) : 20;
   int round;
   double best_plain = 1e30, best_transformed = 1e30, best_encode = 1e30;
   png_uint_32 width = 0, height = 0;
   int depth = 0, colour = 0;
   size_t stride = 0;
   png_bytepp rows;
   long written = 0;

   if (argc < 2)
   {
      fprintf(stderr, "usage: pngbench <file.png> [rounds]\n");
      return 2;
   }

   f = fopen(argv[1], "rb");

   if (f == NULL)
      return 2;

   fseek(f, 0, SEEK_END);
   file.size = (size_t)ftell(f);
   fseek(f, 0, SEEK_SET);
   file.data = malloc(file.size);
   file.offset = 0;

   if (fread(file.data, 1, file.size, f) != file.size)
      return 2;

   fclose(f);

   if (decode(&file, 0, NULL, 0) < 0)
   {
      printf("%s unreadable\n", argv[1]);
      return 0;
   }

   for (round = 0; round < rounds; round++)
   {
      double started = now();
      decode(&file, 0, NULL, 0);
      {
         double took = now() - started;
         if (took < best_plain) best_plain = took;
      }

      started = now();
      decode(&file, 1, NULL, 0);
      {
         double took = now() - started;
         if (took < best_transformed) best_transformed = took;
      }
   }

   rows = keep_rows(&file, &width, &height, &depth, &colour, &stride);

   if (rows != NULL)
   {
      for (round = 0; round < rounds; round++)
      {
         double started = now();
         written = encode(rows, width, height, depth, colour);
         {
            double took = now() - started;
            if (took < best_encode) best_encode = took;
         }
      }

      for (round = 0; round < (int)height; round++)
         free(rows[round]);

      free(rows);
   }

   printf("%s %ux%u decode %.4f transformed %.4f encode %.4f wrote %ld\n",
          argv[1], (unsigned)width, (unsigned)height,
          best_plain, best_transformed,
          best_encode > 1e29 ? 0.0 : best_encode, written);

   free(file.data);

   return 0;
}
