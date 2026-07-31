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
   }

   printf("%ld images, %ld reads abandoned every way there was, %d left something behind\n",
          images, runs, failures);

   return failures != 0;
}
