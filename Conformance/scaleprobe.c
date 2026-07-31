/* scaleprobe.c - how a library writes the scale chunk's numbers
 *
 * The one chunk that stores numbers as text, so the two libraries have to agree on formatting or they
 * write different files for the same value.  This prints what each makes of a spread of values —
 * whole, fractional, very large, very small, and the ones that round into a different shape.
 */

#include <png.h>
#include <stdio.h>

int main(void)
{
   static const double values[] = {
      1.0, 2.5, 10.0, 100000.0, 1e6, 1e-7, 0.5, 0.333333333, 12345.6789, 9.99999999,
      0.000123456, 1e10, 1e-10, 3.14159265358979, 65535.0, 0.1, 0.99999, 123456789.0,
      2.0000001, 1.00001, 1e-5, 7.5e-3,
   };

   static const png_fixed_point fixed[] = {
      100000, 250000, 1, 10, 100, 99999, 2147483647, 33333, 500000, 1000000, 12345678,
   };

   png_structp p = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
   png_infop i = png_create_info_struct(p);
   int unit;
   png_charp width, height;
   unsigned k;

   if (setjmp(png_jmpbuf(p))) { printf("error\n"); return 1; }

   for (k = 0; k < sizeof values / sizeof *values; k++)
   {
      png_set_sCAL(p, i, 1, values[k], 1.0);

      if (png_get_sCAL_s(p, i, &unit, &width, &height))
         printf("floating %-22g \"%s\"\n", values[k], width);
      else
         printf("floating %-22g (refused)\n", values[k]);
   }

   for (k = 0; k < sizeof fixed / sizeof *fixed; k++)
   {
      png_set_sCAL_fixed(p, i, 1, fixed[k], 100000);

      if (png_get_sCAL_s(p, i, &unit, &width, &height))
         printf("fixed    %-22d \"%s\"\n", (int)fixed[k], width);
      else
         printf("fixed    %-22d (refused)\n", (int)fixed[k]);
   }

   /* And the way back: which strings are accepted at all, and what they read as.
    *
    * Each on its own structure, because a string the library refuses is refused with an error and the
    * structure it was refused on cannot be used again.
    */
   {
      static const char *strings[] = {
         "1", "2.5", ".5", "1E5", "12346E-8", "1e-7", "0.25", "-3", "+3", "1.5E+2",
         "not a number", "", "1.", ".", "0", "00.50", "1E", "1E+", "  1", "1 ", "1.5.5",
      };
      double w, h;

      for (k = 0; k < sizeof strings / sizeof *strings; k++)
      {
         png_structp q = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
         png_infop j = png_create_info_struct(q);

         if (setjmp(png_jmpbuf(q)))
         {
            printf("reading  %-22s (refused)\n", strings[k]);
            png_destroy_write_struct(&q, &j);
            continue;
         }

         png_set_sCAL_s(q, j, 1, strings[k], "1");

         if (png_get_sCAL(q, j, &unit, &w, &h))
            printf("reading  %-22s %g\n", strings[k], w);
         else
            printf("reading  %-22s (not a number)\n", strings[k]);

         png_destroy_write_struct(&q, &j);
      }
   }

   return 0;
}
