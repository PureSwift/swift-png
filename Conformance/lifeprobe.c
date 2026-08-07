/* lifeprobe.c - batch-timed decode lifecycle, for measuring fixed cost
 *
 * pngbench reports best-of-N per single operation at 100ns resolution, which cannot
 * resolve a 1-2us tiny-image decode.  This times a whole batch and divides, so the
 * resolution is the batch, not the clock, and reports best-of-K batches.
 *
 * modes:
 *   life   create read struct + info + destroy, nothing else
 *   info   the above plus read_info/update_info (no rows)
 *   full   the whole decode, rows included
 */
#include <png.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_ns(void)
{
   struct timespec t;
   clock_gettime(CLOCK_MONOTONIC, &t);
   return (double)t.tv_sec * 1e9 + (double)t.tv_nsec;
}

typedef struct { const unsigned char *data; size_t size; size_t offset; } Source;

static void read_cb(png_structp p, png_bytep out, size_t count)
{
   Source *s = (Source *)png_get_io_ptr(p);
   if (s->offset + count > s->size) { memset(out, 0, count); return; }
   memcpy(out, s->data + s->offset, count);
   s->offset += count;
}

static void quiet(png_structp p, png_const_charp m) { (void)p; (void)m; }

static void run_life(const unsigned char *d, size_t n, int stage)
{
   Source s = { d, n, 0 };
   png_structp p = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, quiet, quiet);
   png_infop i;

   if (p == NULL) return;
   i = png_create_info_struct(p);

   if (stage > 0)
   {
      if (setjmp(png_jmpbuf(p))) { png_destroy_read_struct(&p, &i, NULL); return; }
      png_set_read_fn(p, &s, read_cb);
      png_read_info(p, i);
      png_read_update_info(p, i);

      if (stage > 1)
      {
         png_uint_32 y, h = png_get_image_height(p, i);
         size_t rb = png_get_rowbytes(p, i);
         png_bytep row = (png_bytep)malloc(rb ? rb : 1);

         for (y = 0; y < h; y++) png_read_row(p, row, NULL);

         free(row);
         png_read_end(p, NULL);
      }
   }

   png_destroy_read_struct(&p, &i, NULL);
}

int main(int argc, char **argv)
{
   const char *path = argc > 1 ? argv[1] : NULL;
   const char *mode = argc > 2 ? argv[2] : "full";
   int batch = argc > 3 ? atoi(argv[3]) : 20000;
   int repeats = argc > 4 ? atoi(argv[4]) : 12;
   int stage = strcmp(mode, "life") == 0 ? 0 : (strcmp(mode, "info") == 0 ? 1 : 2);
   unsigned char *data = NULL;
   size_t size = 0;
   double best = 1e30;
   int r, k;
   FILE *f;

   if (path == NULL) { fprintf(stderr, "usage: lifeprobe <file.png> [life|info|full] [batch] [repeats]\n"); return 2; }

   f = fopen(path, "rb");
   if (f == NULL) { perror(path); return 1; }
   fseek(f, 0, SEEK_END); size = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
   data = (unsigned char *)malloc(size);
   if (fread(data, 1, size, f) != size) { fclose(f); return 1; }
   fclose(f);

   for (k = 0; k < 2000; k++) run_life(data, size, stage);   /* warm up */

   for (r = 0; r < repeats; r++)
   {
      double started = now_ns();
      for (k = 0; k < batch; k++) run_life(data, size, stage);
      {
         double per = (now_ns() - started) / (double)batch;
         if (per < best) best = per;
      }
   }

   printf("%-28s %-5s %8.1f ns/op\n", path, mode, best);
   free(data);
   return 0;
}
