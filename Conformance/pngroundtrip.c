/* pngroundtrip.c - read a file, write it back, read that, and say what survived
 *
 * The writer's counterpart to the decode comparison, and the widest check on it: pngwrite makes its
 * own images from a short list of shapes, while this takes every file in the corpus — with whatever
 * awkward geometry, depth and metadata it was built to have — and asks whether the library can
 * reproduce it.
 *
 * What is printed is the *second* reading, of the file this program wrote.  Run against both
 * libraries, the outputs must match, which says the two wrote the same picture and the same metadata.
 * A third run reads one library's output with the other, which is what catches a file only its own
 * writer understands.
 *
 * Deliberately not a comparison of the two readings within one run.  A library that reads a chunk
 * wrongly and writes it back the same way would pass that, and this is meant to catch exactly such a
 * pair.
 *
 * usage: pngroundtrip <input.png> <output.png> [dump]
 */

#include <png.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static png_bytepp allocate_rows(png_structp p, png_infop i, png_uint_32 height)
{
   png_bytepp rows = malloc(sizeof(png_bytep) * (height ? height : 1));
   png_uint_32 y;

   for (y = 0; y < height; y++)
      rows[y] = calloc(1, png_get_rowbytes(p, i) + 8);

   return rows;
}

static void free_rows(png_bytepp rows, png_uint_32 height)
{
   png_uint_32 y;

   for (y = 0; y < height; y++) free(rows[y]);

   free(rows);
}

/* Reads a whole file into rows and an info structure.
 *
 * Nothing is transformed: the rows are whatever the file stores, so what is written back out is the
 * same image rather than a rendering of it.
 */
static int read_file(const char *path, png_structp *pp, png_infop *ip, png_bytepp *rows)
{
   FILE *fp = fopen(path, "rb");
   png_structp p;
   png_infop i;
   png_uint_32 height;
   int passes, pass;
   png_uint_32 y;

   if (fp == NULL) return 1;

   p = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
   i = png_create_info_struct(p);

   if (setjmp(png_jmpbuf(p)))
   {
      png_destroy_read_struct(&p, &i, NULL);
      fclose(fp);
      return 1;
   }

   png_init_io(p, fp);
   png_read_info(p, i);

   height = png_get_image_height(p, i);
   passes = png_set_interlace_handling(p);
   *rows = allocate_rows(p, i, height);

   for (pass = 0; pass < passes; pass++)
      for (y = 0; y < height; y++)
         png_read_row(p, (*rows)[y], NULL);

   png_read_end(p, i);
   fclose(fp);

   *pp = p;
   *ip = i;

   return 0;
}

/* Writes what was read, keeping everything the info structure carries. */
static int write_file(const char *path, png_structp source, png_infop info, png_bytepp rows)
{
   FILE *fp = fopen(path, "wb");
   png_structp p;
   png_infop i;
   png_uint_32 width, height;
   int depth, color_type, interlace, compression, filter;
   png_colorp palette;
   int entries;
   png_bytep alphas;
   int num_alphas;
   png_color_16p transparent;
   png_color_16p background;
   png_fixed_point gamma;
   png_textp texts;
   int num_texts;
   int passes, pass;
   png_uint_32 y;

   if (fp == NULL) return 1;

   p = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
   i = png_create_info_struct(p);

   if (setjmp(png_jmpbuf(p)))
   {
      png_destroy_write_struct(&p, &i);
      fclose(fp);
      return 1;
   }

   png_init_io(p, fp);

   png_get_IHDR(source, info, &width, &height, &depth, &color_type, &interlace,
                &compression, &filter);
   png_set_IHDR(p, i, width, height, depth, color_type, interlace, compression, filter);

   if (png_get_PLTE(source, info, &palette, &entries))
      png_set_PLTE(p, i, palette, entries);

   if (png_get_gAMA_fixed(source, info, &gamma))
      png_set_gAMA_fixed(p, i, gamma);

   {
      png_fixed_point wx, wy, rx, ry, gx, gy, bx, by;

      if (png_get_cHRM_fixed(source, info, &wx, &wy, &rx, &ry, &gx, &gy, &bx, &by))
         png_set_cHRM_fixed(p, i, wx, wy, rx, ry, gx, gy, bx, by);
   }

   {
      int intent;

      if (png_get_sRGB(source, info, &intent))
         png_set_sRGB(p, i, intent);
   }

   {
      png_color_8p sig_bits;

      if (png_get_sBIT(source, info, &sig_bits))
         png_set_sBIT(p, i, sig_bits);
   }

   if (png_get_tRNS(source, info, &alphas, &num_alphas, &transparent))
      png_set_tRNS(p, i, alphas, num_alphas, transparent);

   if (png_get_bKGD(source, info, &background))
      png_set_bKGD(p, i, background);

   {
      png_uint_32 res_x, res_y;
      int unit;

      if (png_get_pHYs(source, info, &res_x, &res_y, &unit))
         png_set_pHYs(p, i, res_x, res_y, unit);
   }

   {
      png_int_32 off_x, off_y;
      int unit;

      if (png_get_oFFs(source, info, &off_x, &off_y, &unit))
         png_set_oFFs(p, i, off_x, off_y, unit);
   }

   {
      png_timep when;

      if (png_get_tIME(source, info, &when))
         png_set_tIME(p, i, when);
   }

   {
      png_charp name;
      int compression_type;
      png_bytep profile;
      png_uint_32 profile_length;

      if (png_get_iCCP(source, info, &name, &compression_type, &profile, &profile_length))
         png_set_iCCP(p, i, name, compression_type, profile, profile_length);
   }

   {
      /* The scale, which is the one chunk holding its numbers as text.  Copied as text rather than as
       * numbers, since that is what the file carries and what a client is entitled to get back.
       */
      int scale_unit;
      png_charp scale_width, scale_height;

      if (png_get_sCAL_s(source, info, &scale_unit, &scale_width, &scale_height))
         png_set_sCAL_s(p, i, scale_unit, scale_width, scale_height);
   }

   {
      png_uint_32 num_exif;
      png_bytep exif;

      if (png_get_eXIf_1(source, info, &num_exif, &exif))
         png_set_eXIf_1(p, i, num_exif, exif);
   }

   {
      png_charp purpose, units, *params;
      png_int_32 x0, x1;
      int type, nparams;

      if (png_get_pCAL(source, info, &purpose, &x0, &x1, &type, &nparams, &units, &params))
         png_set_pCAL(p, i, purpose, x0, x1, type, nparams, units, params);
   }

   {
      png_sPLT_tp palettes;
      int count = png_get_sPLT(source, info, &palettes);

      if (count > 0)
         png_set_sPLT(p, i, palettes, count);
   }

   num_texts = png_get_text(source, info, &texts, NULL);

   if (num_texts > 0)
      png_set_text(p, i, texts, num_texts);

   png_write_info(p, i);

   passes = png_set_interlace_handling(p);

   for (pass = 0; pass < passes; pass++)
      for (y = 0; y < height; y++)
         png_write_row(p, rows[y]);

   png_write_end(p, i);
   png_destroy_write_struct(&p, &i);
   fclose(fp);

   return 0;
}

/* Prints what a file holds: the geometry, the metadata, and every row. */
static int dump_file(const char *path)
{
   png_structp p;
   png_infop i;
   png_bytepp rows;
   png_uint_32 height, y;
   png_colorp palette;
   int entries;

   if (read_file(path, &p, &i, &rows) != 0) { printf("read error\n"); return 1; }

   height = png_get_image_height(p, i);

   printf("ihdr width=%u height=%u depth=%d color=%d interlace=%d\n",
          (unsigned)png_get_image_width(p, i), (unsigned)height,
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

   {
      png_fixed_point gamma;
      png_fixed_point wx, wy, rx, ry, gx, gy, bx, by;
      int intent;
      png_color_8p sig_bits;
      png_color_16p background;
      png_uint_32 res_x, res_y;
      int unit;
      png_int_32 off_x, off_y;
      png_timep when;
      png_bytep alphas;
      int num_alphas;
      png_color_16p transparent;
      png_charp name;
      int compression_type;
      png_bytep profile;
      png_uint_32 profile_length;
      png_textp texts;
      int num_texts, k;

      if (png_get_gAMA_fixed(p, i, &gamma)) printf("gama %d\n", (int)gamma);

      if (png_get_cHRM_fixed(p, i, &wx, &wy, &rx, &ry, &gx, &gy, &bx, &by))
         printf("chrm %d %d %d %d %d %d %d %d\n", (int)wx, (int)wy, (int)rx, (int)ry,
                (int)gx, (int)gy, (int)bx, (int)by);

      if (png_get_sRGB(p, i, &intent)) printf("srgb %d\n", intent);

      if (png_get_sBIT(p, i, &sig_bits))
         printf("sbit r=%d g=%d b=%d gray=%d alpha=%d\n", sig_bits->red, sig_bits->green,
                sig_bits->blue, sig_bits->gray, sig_bits->alpha);

      if (png_get_bKGD(p, i, &background))
         printf("bkgd index=%d red=%d green=%d blue=%d gray=%d\n", background->index,
                background->red, background->green, background->blue, background->gray);

      if (png_get_pHYs(p, i, &res_x, &res_y, &unit))
         printf("phys x=%u y=%u unit=%d\n", (unsigned)res_x, (unsigned)res_y, unit);

      if (png_get_oFFs(p, i, &off_x, &off_y, &unit))
         printf("offs x=%d y=%d unit=%d\n", (int)off_x, (int)off_y, unit);

      if (png_get_tIME(p, i, &when))
         printf("time %d-%d-%d %d:%d:%d\n", when->year, when->month, when->day,
                when->hour, when->minute, when->second);

      if (png_get_tRNS(p, i, &alphas, &num_alphas, &transparent))
      {
         printf("trns count=%d:", num_alphas);

         if (alphas != NULL)
            for (k = 0; k < num_alphas; k++) printf(" %02x", alphas[k]);

         if (transparent != NULL)
            printf(" color=%d,%d,%d,%d", transparent->red, transparent->green,
                   transparent->blue, transparent->gray);

         printf("\n");
      }

      if (png_get_iCCP(p, i, &name, &compression_type, &profile, &profile_length))
      {
         /* The profile's bytes rather than a summary: a writer that compressed it wrongly would
          * still produce something of the right length.
          */
         printf("iccp name=%s length=%u:", name, (unsigned)profile_length);

         for (k = 0; k < (int)profile_length && k < 32; k++) printf(" %02x", profile[k]);

         printf("\n");
      }

      {
         int scale_unit;
         png_charp scale_width, scale_height;
         double dw, dh;
         png_fixed_point fw, fh;

         if (png_get_sCAL_s(p, i, &scale_unit, &scale_width, &scale_height))
            printf("scal unit=%d width=%s height=%s\n", scale_unit, scale_width, scale_height);

         /* And as numbers, which is a different code path and can disagree with the strings. */
         if (png_get_sCAL(p, i, &scale_unit, &dw, &dh))
            printf("scal numbers %g %g\n", dw, dh);

         if (png_get_sCAL_fixed(p, i, &scale_unit, &fw, &fh))
            printf("scal fixed %d %d\n", (int)fw, (int)fh);
      }

      {
         png_uint_32 num_exif;
         png_bytep exif;

         if (png_get_eXIf_1(p, i, &num_exif, &exif))
         {
            printf("exif length=%u:", (unsigned)num_exif);

            for (k = 0; k < (int)num_exif && k < 32; k++) printf(" %02x", exif[k]);

            printf("\n");
         }
      }

      {
         png_charp purpose, units, *params;
         png_int_32 x0, x1;
         int type, nparams;

         if (png_get_pCAL(p, i, &purpose, &x0, &x1, &type, &nparams, &units, &params))
         {
            printf("pcal %s %d %d type=%d units=%s:", purpose, (int)x0, (int)x1, type, units);

            for (k = 0; k < nparams; k++) printf(" %s", params[k]);

            printf("\n");
         }
      }

      {
         png_sPLT_tp palettes;
         int count = png_get_sPLT(p, i, &palettes);
         int e;

         for (k = 0; k < count; k++)
         {
            printf("splt %s depth=%d entries=%d:", palettes[k].name, palettes[k].depth,
                   (int)palettes[k].nentries);

            for (e = 0; e < palettes[k].nentries && e < 4; e++)
               printf(" %u,%u,%u,%u/%u", palettes[k].entries[e].red,
                      palettes[k].entries[e].green, palettes[k].entries[e].blue,
                      palettes[k].entries[e].alpha, palettes[k].entries[e].frequency);

            printf("\n");
         }
      }

      num_texts = png_get_text(p, i, &texts, NULL);

      for (k = 0; k < num_texts; k++)
         printf("text compression=%d key=%s lang=%s lang_key=%s len=%u text=%s\n",
                texts[k].compression, texts[k].key,
                texts[k].lang != NULL ? texts[k].lang : "",
                texts[k].lang_key != NULL ? texts[k].lang_key : "",
                (unsigned)texts[k].text_length,
                texts[k].text != NULL ? texts[k].text : "");
   }

   for (y = 0; y < height; y++)
   {
      size_t k;

      printf("row %u", (unsigned)y);

      for (k = 0; k < png_get_rowbytes(p, i); k++)
         printf(" %02x", rows[y][k]);

      printf("\n");
   }

   free_rows(rows, height);
   png_destroy_read_struct(&p, &i, NULL);

   return 0;
}

int main(int argc, char **argv)
{
   png_structp p;
   png_infop i;
   png_bytepp rows;
   png_uint_32 height;

   if (argc < 3)
   {
      fprintf(stderr, "usage: pngroundtrip <input.png> <output.png> [dump]\n");
      return 2;
   }

   /* Reading alone, for the swap: one library reads what the other wrote. */
   if (strcmp(argv[2], "dump") == 0)
      return dump_file(argv[1]);

   if (read_file(argv[1], &p, &i, &rows) != 0) { printf("read error\n"); return 1; }

   height = png_get_image_height(p, i);

   if (write_file(argv[2], p, i, rows) != 0) { printf("write error\n"); return 1; }

   free_rows(rows, height);
   png_destroy_read_struct(&p, &i, NULL);

   return dump_file(argv[2]);
}
