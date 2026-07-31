/* pngsimplewrite.c - write an image the short way, then read it back
 *
 * The writing half of the simplified API.  A client describes what it is holding and hands over the
 * pixels; everything about how they become a file is the library's.
 *
 * Compared the way the other writer is: not by the bytes of the file, which two correct encoders need
 * not agree on, but by what the file means.  The image written here is generated, so the reading is
 * the only thing worth looking at — and it is read back through the same simplified API, which is
 * what a client of it would do.
 *
 * usage: pngsimplewrite <output.png> <format> <width> <height> [memory]
 */

#include <png.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int channels_of(png_uint_32 format)
{
   int channels = (format & PNG_FORMAT_FLAG_COLOR) != 0 ? 3 : 1;

   if ((format & PNG_FORMAT_FLAG_ALPHA) != 0) channels++;

   return channels;
}

int main(int argc, char **argv)
{
   png_image image;
   png_bytep pixels;
   png_uint_32 format;
   png_uint_32 width, height;
   size_t size;
   size_t k;
   int to_memory;

   if (argc < 5)
   {
      fprintf(stderr, "usage: pngsimplewrite <output.png> <format> <width> <height> [memory]\n");
      return 2;
   }

   format = (png_uint_32)strtol(argv[2], NULL, 0);
   width = (png_uint_32)atoi(argv[3]);
   height = (png_uint_32)atoi(argv[4]);
   to_memory = argc > 5;

   size = (size_t)width * height * channels_of(format);
   pixels = malloc(size != 0 ? size : 1);

   /* Deliberately not smooth, so that a channel written into the wrong place is visible. */
   for (k = 0; k < size; k++)
      pixels[k] = (png_byte)((k * 37 + (k & 7) * 29) & 0xFF);

   memset(&image, 0, sizeof image);
   image.version = PNG_IMAGE_VERSION;
   image.width = width;
   image.height = height;
   image.format = format;

   if (to_memory)
   {
      png_alloc_size_t needed = 0;

      /* Asked for the size first, with nowhere to put the bytes, which is how a client finds out. */
      if (png_image_write_to_memory(&image, NULL, &needed, 0, pixels, 0, NULL) == 0)
      {
         printf("sizing failed: %s\n", image.message);
         free(pixels);
         return 1;
      }

      /* The number itself is not compared: how well an image compresses is the encoder's choice, and
       * two correct ones need not agree.  What is compared is that a size was offered at all.
       */
      printf("memory sizing offered\n");

      {
         png_bytep block = malloc(needed != 0 ? needed : 1);
         png_alloc_size_t room = needed;
         FILE *fp;

         memset(&image, 0, sizeof image);
         image.version = PNG_IMAGE_VERSION;
         image.width = width;
         image.height = height;
         image.format = format;

         if (png_image_write_to_memory(&image, block, &room, 0, pixels, 0, NULL) == 0)
         {
            printf("write failed: %s\n", image.message);
            free(block);
            free(pixels);
            return 1;
         }

         /* This one *is* worth checking, against the sizing call rather than against the other
          * library: a client sets aside what it was told and a writer that then needed more would
          * have overrun it.
          */
         printf("memory written %s\n",
                room == needed ? "as sized" : "a different amount from the sizing");

         fp = fopen(argv[1], "wb");
         fwrite(block, 1, room, fp);
         fclose(fp);
         free(block);
      }
   }
   else if (png_image_write_to_file(&image, argv[1], 0, pixels, 0, NULL) == 0)
   {
      printf("write failed: %s\n", image.message);
      free(pixels);
      return 1;
   }

   free(pixels);

   /* And back, through the same API a client would use. */
   {
      png_image back;
      png_bytep buffer;

      memset(&back, 0, sizeof back);
      back.version = PNG_IMAGE_VERSION;

      if (png_image_begin_read_from_file(&back, argv[1]) == 0)
      {
         printf("read failed: %s\n", back.message);
         return 1;
      }

      printf("read width=%u height=%u format=0x%x\n",
             (unsigned)back.width, (unsigned)back.height, (unsigned)back.format);

      back.format = format;
      buffer = calloc(1, PNG_IMAGE_SIZE(back) != 0 ? PNG_IMAGE_SIZE(back) : 1);

      if (png_image_finish_read(&back, NULL, buffer, 0, NULL) == 0)
      {
         printf("finish failed: %s\n", back.message);
         free(buffer);
         return 1;
      }

      for (k = 0; k < PNG_IMAGE_SIZE(back); k++)
      {
         if (k % 32 == 0) printf("\n ");

         printf(" %02x", buffer[k]);
      }

      printf("\n");
      free(buffer);
   }

   return 0;
}
