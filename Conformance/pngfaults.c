/* pngfaults.c - what is left behind when a decode is abandoned part way
 *
 * A client is allowed to leave at several points: its error handler need not return, its warning
 * handler may jump out too, and its reader may give up rather than supply bytes.  Any of those
 * abandons the library in whatever state it had reached, and png_destroy_read_struct then has to
 * reclaim everything anyway.
 *
 * So this leaves, over and over, from every point there is.  For each image it counts how many
 * allocations a whole read takes, then reads it again once per allocation with that one refused —
 * and again once per warning, and once per read of the file — jumping out each time and destroying
 * the structure afterwards.
 *
 * Three ways of using the library, because they abandon differently.  A sequential read holds the
 * most state; a pushed-in read leaves from inside a callback with the library's own state machine
 * part way through a chunk; and a write leaves with an image half written and a compressor open.
 *
 * Nothing is compared against the reference here.  The two libraries do not allocate the same number
 * of times or in the same order, so the counts mean nothing between them; what this checks is that
 * every block this program handed out came back, which is a question about one library at a time.
 * The allocator is the harness's own, so the answer is exact rather than a leak checker's guess.
 */

#include <png.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BLOCK_LIMIT 8192

struct tracker {
   void *blocks[BLOCK_LIMIT];
   size_t sizes[BLOCK_LIMIT];    /* kept so a leak can be described rather than only counted */
   int live;
   int overflowed;

   long allocations;      /* how many have been asked for this run */
   long refuse;           /* which one to refuse, or zero to refuse none */

   long warnings;
   long warn_leave;       /* which warning to leave from, or zero to stay */

   long reads;
   long read_leave;       /* which read of the file to leave from, or zero */

   long rows;
   long row_leave;        /* which row handed back to leave from, or zero */

   long writes;
   long write_leave;      /* which write of the file to leave from, or zero */

   int left;              /* whether this run was abandoned */
   int armed;             /* whether there is yet anywhere to jump to */
   png_bytep row;         /* held here rather than in a local, which a jump would strand */
   FILE *file;
};

static png_voidp PNGCBAPI take(png_structp png_ptr, png_alloc_size_t size)
{
   struct tracker *t = png_get_mem_ptr(png_ptr);
   void *memory;

   t->allocations++;

   /* Only once there is somewhere to jump to.  Refusing an allocation made while the structure is
    * still being built calls the error handler before setjmp has been reached, and a handler that
    * jumps then jumps to nowhere — which is a fault in this program rather than in either library.
    */
   if (t->armed != 0 && t->refuse != 0 && t->allocations == t->refuse)
      return NULL;

   memory = malloc(size != 0 ? (size_t)size : 1);

   if (memory == NULL)
      return NULL;

   if (t->live < BLOCK_LIMIT)
   {
      t->sizes[t->live] = (size_t)size;
      t->blocks[t->live++] = memory;
   }
   else
      t->overflowed = 1;

   return memory;
}

static void PNGCBAPI give_back(png_structp png_ptr, png_voidp memory)
{
   struct tracker *t = png_get_mem_ptr(png_ptr);
   int index;

   if (memory == NULL)
      return;

   for (index = 0; index < t->live; index++)
   {
      if (t->blocks[index] == memory)
      {
         t->live--;
         t->blocks[index] = t->blocks[t->live];
         t->sizes[index] = t->sizes[t->live];
         free(memory);
         return;
      }
   }

   /* Freeing something this program never handed out is a fault worth knowing about, and is
    * reported by leaving the block count wrong rather than by crashing here.
    */
   t->overflowed = 1;
   free(memory);
}

static void PNGCBAPI leave(png_structp png_ptr, png_const_charp message)
{
   struct tracker *t = png_get_error_ptr(png_ptr);
   (void)message;
   t->left = 1;
   longjmp(png_jmpbuf(png_ptr), 1);
}

static void PNGCBAPI remark(png_structp png_ptr, png_const_charp message)
{
   struct tracker *t = png_get_error_ptr(png_ptr);
   (void)message;

   t->warnings++;

   if (t->warn_leave != 0 && t->warnings == t->warn_leave)
   {
      t->left = 1;
      longjmp(png_jmpbuf(png_ptr), 1);
   }
}

static void PNGCBAPI supply(png_structp png_ptr, png_bytep into, size_t count)
{
   struct tracker *t = png_get_io_ptr(png_ptr);

   t->reads++;

   if (t->read_leave != 0 && t->reads == t->read_leave)
   {
      t->left = 1;
      longjmp(png_jmpbuf(png_ptr), 1);
   }

   if (fread(into, 1, count, t->file) != count)
      png_error(png_ptr, "ran out of file");
}

/* The three points a pushed-in read reports back at, any of which a client may leave from. */
static void PNGCBAPI pushed_info(png_structp png_ptr, png_infop info_ptr)
{
   (void)info_ptr;
   png_start_read_image(png_ptr);
}

static void PNGCBAPI pushed_row(png_structp png_ptr, png_bytep row, png_uint_32 number, int pass)
{
   struct tracker *t = png_get_progressive_ptr(png_ptr);

   (void)row;
   (void)number;
   (void)pass;

   t->rows++;

   if (t->row_leave != 0 && t->rows == t->row_leave)
   {
      t->left = 1;
      longjmp(png_jmpbuf(png_ptr), 1);
   }
}

static void PNGCBAPI pushed_end(png_structp png_ptr, png_infop info_ptr)
{
   (void)png_ptr;
   (void)info_ptr;
}

/* The other direction: a client that gives up rather than take the bytes being written. */
static void PNGCBAPI accept(png_structp png_ptr, png_bytep data, size_t count)
{
   struct tracker *t = png_get_io_ptr(png_ptr);

   (void)data;
   (void)count;

   t->writes++;

   if (t->write_leave != 0 && t->writes == t->write_leave)
   {
      t->left = 1;
      longjmp(png_jmpbuf(png_ptr), 1);
   }
}

static void PNGCBAPI settle(png_structp png_ptr)
{
   (void)png_ptr;
}

/* One whole read, abandoned wherever the tracker says.  Returns the blocks left over. */
static int run(const char *path, struct tracker *t)
{
   png_structp p;
   png_infop i;
   png_infop end;

   t->live = 0;
   t->overflowed = 0;
   t->allocations = 0;
   t->warnings = 0;
   t->reads = 0;
   t->left = 0;
   t->armed = 0;
   t->row = NULL;

   t->file = fopen(path, "rb");

   if (t->file == NULL)
      return 0;

   p = png_create_read_struct_2(PNG_LIBPNG_VER_STRING, t, leave, remark, t, take, give_back);

   if (p == NULL)
   {
      fclose(t->file);
      return t->live;
   }

   i = png_create_info_struct(p);
   end = png_create_info_struct(p);

   if (setjmp(png_jmpbuf(p)) == 0)
   {
      png_uint_32 width, height;
      int depth, colour, interlace, compression, filter, y, pass, passes;

      t->armed = 1;

      png_set_read_fn(p, t, supply);
      png_read_info(p, i);
      png_get_IHDR(p, i, &width, &height, &depth, &colour, &interlace,
                   &compression, &filter);

      /* Enough transforms to reach the parts of the library that allocate tables. */
      png_set_expand(p);
      png_set_gamma(p, 2.2, 0.45455);
      passes = png_set_interlace_handling(p);
      png_read_update_info(p, i);

      /* Not through the library's allocator, and not in a local: a jump out of the loop below
       * would strand a local, and a block taken from the tracked allocator would be counted as
       * something the library failed to give back when it was this program's all along.
       */
      t->row = malloc(png_get_rowbytes(p, i));

      for (pass = 0; pass < passes; pass++)
         for (y = 0; y < (int)height; y++)
            png_read_row(p, t->row, NULL);

      png_read_end(p, end);
   }

   free(t->row);
   t->row = NULL;

   png_destroy_read_struct(&p, &i, &end);
   fclose(t->file);

   return t->overflowed ? -1 : t->live;
}

/* The same file pushed in rather than pulled, abandoned wherever the tracker says. */
static int run_pushed(const char *path, struct tracker *t)
{
   png_structp p;
   png_infop i;
   unsigned char buffer[512];
   size_t got;

   t->live = 0;
   t->overflowed = 0;
   t->allocations = 0;
   t->warnings = 0;
   t->rows = 0;
   t->left = 0;
   t->armed = 0;
   t->row = NULL;

   t->file = fopen(path, "rb");

   if (t->file == NULL)
      return 0;

   p = png_create_read_struct_2(PNG_LIBPNG_VER_STRING, t, leave, remark, t, take, give_back);

   if (p == NULL)
   {
      fclose(t->file);
      return t->live;
   }

   i = png_create_info_struct(p);

   if (setjmp(png_jmpbuf(p)) == 0)
   {
      t->armed = 1;
      png_set_progressive_read_fn(p, t, pushed_info, pushed_row, pushed_end);

      while ((got = fread(buffer, 1, sizeof buffer, t->file)) > 0)
         png_process_data(p, i, buffer, got);
   }

   png_destroy_read_struct(&p, &i, NULL);
   fclose(t->file);

   return t->overflowed ? -1 : t->live;
}

/* An image written out, abandoned wherever the tracker says.
 *
 * The rows are this program's own rather than the library's, and are written nowhere: what is being
 * checked is what the library takes and gives back, not what comes out the other end.
 */
static int run_write(struct tracker *t, int colour, int depth, int interlaced)
{
   png_structp p;
   png_infop i;
   static unsigned char scanline[64 * 8];
   static png_color palette[16];
   static png_byte transparency[16];
   int k;

   t->live = 0;
   t->overflowed = 0;
   t->allocations = 0;
   t->warnings = 0;
   t->writes = 0;
   t->left = 0;
   t->armed = 0;
   t->row = NULL;
   t->file = NULL;

   for (k = 0; k < (int)sizeof scanline; k++)
      scanline[k] = (unsigned char)((k * 37) & 0xFF);

   for (k = 0; k < 16; k++)
   {
      palette[k].red = (png_byte)(k * 17);
      palette[k].green = (png_byte)(k * 15);
      palette[k].blue = (png_byte)(k * 13);
      transparency[k] = (png_byte)(k * 16);
   }

   p = png_create_write_struct_2(PNG_LIBPNG_VER_STRING, t, leave, remark, t, take, give_back);

   if (p == NULL)
      return t->live;

   i = png_create_info_struct(p);

   if (setjmp(png_jmpbuf(p)) == 0)
   {
      png_text text[2];
      int y;

      t->armed = 1;
      png_set_write_fn(p, t, accept, settle);

      png_set_IHDR(p, i, 16, 8, depth, colour,
                   interlaced ? PNG_INTERLACE_ADAM7 : PNG_INTERLACE_NONE,
                   PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);

      if (colour == PNG_COLOR_TYPE_PALETTE)
      {
         png_set_PLTE(p, i, palette, 16);
         png_set_tRNS(p, i, transparency, 16, NULL);
      }

      /* Text, because it is the one thing on this side that compresses and so allocates most. */
      memset(text, 0, sizeof text);
      text[0].compression = PNG_TEXT_COMPRESSION_NONE;
      text[0].key = (png_charp)"Title";
      text[0].text = (png_charp)"a plain remark";
      text[1].compression = PNG_TEXT_COMPRESSION_zTXt;
      text[1].key = (png_charp)"Comment";
      text[1].text = (png_charp)"a remark long enough to be worth compressing, over and over again";
      png_set_text(p, i, text, 2);

      png_set_gAMA(p, i, 0.45455);
      png_write_info(p, i);

      {
         int passes = interlaced ? png_set_interlace_handling(p) : 1;
         int pass;

         for (pass = 0; pass < passes; pass++)
            for (y = 0; y < 8; y++)
               png_write_row(p, scanline);
      }

      png_write_end(p, i);
   }

   png_destroy_write_struct(&p, &i);

   return t->overflowed ? -1 : t->live;
}

int main(int argc, char **argv)
{
   struct tracker t;
   int argument;
   int failures = 0;
   long images = 0;
   long runs = 0;

   memset(&t, 0, sizeof t);

   for (argument = 1; argument < argc; argument++)
   {
      const char *path = argv[argument];
      long total;
      long which;
      long left;

      /* What an undisturbed read costs, which says how many ways there are to disturb it. */
      t.refuse = 0;
      t.warn_leave = 0;
      t.read_leave = 0;
      left = run(path, &t);
      total = t.allocations;
      runs++;

      if (left != 0)
      {
         printf("%s: %ld blocks left after an ordinary read\n", path, left);
         failures++;
         continue;
      }

      images++;

      for (which = 1; which <= total; which++)
      {
         t.refuse = which;
         t.warn_leave = 0;
         t.read_leave = 0;
         left = run(path, &t);
         runs++;

         if (left != 0)
         {
            printf("%s: %ld blocks left with allocation %ld refused, of", path, left, which);
            {
               int index;
               for (index = 0; index < t.live; index++)
               {
                  size_t byte;
                  printf(" [%lu:", (unsigned long)t.sizes[index]);
                  for (byte = 0; byte < t.sizes[index] && byte < 24; byte++)
                  {
                     unsigned char c = ((unsigned char *)t.blocks[index])[byte];
                     printf("%c", (c >= 32 && c < 127) ? c : '.');
                  }
                  printf("]");
               }
            }
            printf(" bytes\n");
            failures++;
         }
      }

      for (which = 1; which <= 8; which++)
      {
         t.refuse = 0;
         t.warn_leave = which;
         t.read_leave = 0;
         left = run(path, &t);
         runs++;

         if (left != 0)
         {
            printf("%s: %ld blocks left leaving at warning %ld\n", path, left, which);
            failures++;
         }
      }

      for (which = 1; which <= 12; which++)
      {
         t.refuse = 0;
         t.warn_leave = 0;
         t.read_leave = which;
         left = run(path, &t);
         runs++;

         if (left != 0)
         {
            printf("%s: %ld blocks left leaving at read %ld\n", path, left, which);
            failures++;
         }
      }

      /* The same file pushed in, which abandons from inside a callback rather than between calls. */
      t.refuse = 0;
      t.warn_leave = 0;
      t.read_leave = 0;
      t.row_leave = 0;
      left = run_pushed(path, &t);
      total = t.allocations;
      runs++;

      if (left != 0)
      {
         printf("%s: %ld blocks left after an ordinary pushed read\n", path, left);
         failures++;
      }

      for (which = 1; which <= total; which++)
      {
         t.refuse = which;
         t.row_leave = 0;
         left = run_pushed(path, &t);
         runs++;

         if (left != 0)
         {
            printf("%s: %ld blocks left with allocation %ld refused while pushing\n",
                   path, left, which);
            failures++;
         }
      }

      for (which = 1; which <= 8; which++)
      {
         t.refuse = 0;
         t.row_leave = which;
         left = run_pushed(path, &t);
         runs++;

         if (left != 0)
         {
            printf("%s: %ld blocks left leaving at pushed row %ld\n", path, left, which);
            failures++;
         }
      }

      t.row_leave = 0;
   }

   /* And the other direction, which owes nothing to the corpus: the rows are made up here, so this
    * runs once rather than once per file.
    */
   {
      static const struct { int colour; int depth; int interlaced; const char *name; } shapes[] = {
         { PNG_COLOR_TYPE_RGB, 8, 0, "colour" },
         { PNG_COLOR_TYPE_RGB_ALPHA, 16, 0, "colour with alpha, sixteen bit" },
         { PNG_COLOR_TYPE_PALETTE, 4, 0, "indexed at four bits" },
         { PNG_COLOR_TYPE_GRAY, 8, 1, "grey, interlaced" },
      };
      unsigned shape;

      for (shape = 0; shape < sizeof shapes / sizeof *shapes; shape++)
      {
         long total;
         long which;
         long left;

         t.refuse = 0;
         t.warn_leave = 0;
         t.write_leave = 0;
         left = run_write(&t, shapes[shape].colour, shapes[shape].depth, shapes[shape].interlaced);
         total = t.allocations;
         runs++;

         if (left != 0)
         {
            printf("writing %s: %ld blocks left after an ordinary write\n",
                   shapes[shape].name, left);
            failures++;
            continue;
         }

         for (which = 1; which <= total; which++)
         {
            t.refuse = which;
            t.write_leave = 0;
            left = run_write(&t, shapes[shape].colour, shapes[shape].depth,
                             shapes[shape].interlaced);
            runs++;

            if (left != 0)
            {
               printf("writing %s: %ld blocks left with allocation %ld refused\n",
                      shapes[shape].name, left, which);
               failures++;
            }
         }

         for (which = 1; which <= 12; which++)
         {
            t.refuse = 0;
            t.write_leave = which;
            left = run_write(&t, shapes[shape].colour, shapes[shape].depth,
                             shapes[shape].interlaced);
            runs++;

            if (left != 0)
            {
               printf("writing %s: %ld blocks left leaving at write %ld, of",
                      shapes[shape].name, left, which);
               {
                  int index;
                  for (index = 0; index < t.live; index++)
                     printf(" %lu", (unsigned long)t.sizes[index]);
               }
               printf(" bytes\n");
               failures++;
            }
         }
      }
   }

   printf("%ld images, %ld uses abandoned every way there was, %d left something behind\n",
          images, runs, failures);

   return failures != 0;
}
