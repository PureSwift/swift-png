/* pngsimple.c - read an image the short way
 *
 * The simplified API asks a client for one thing: what the pixels should look like when they arrive.
 * Everything else — the depth the file used, whether it was indexed or interlaced, what its
 * transparency meant — is the library's to work out.
 *
 * So this drives it the way a client would: open, look at what the file says it is, ask for a format,
 * and print what comes back.  The header alone is worth comparing on its own, because a client decides
 * what to ask for from it.
 *
 * usage: pngsimple <file.png> [format]
 */

#include <png.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
   png_image image;

   if (argc < 2)
   {
      fprintf(stderr, "usage: pngsimple <file.png> [format]\n");
      return 2;
   }

   memset(&image, 0, sizeof image);
   image.version = PNG_IMAGE_VERSION;

   if (png_image_begin_read_from_file(&image, argv[1]) == 0)
   {
      printf("begin failed: %s\n", image.message);
      return 1;
   }

   printf("header width=%u height=%u format=0x%x colormap_entries=%u\n",
          (unsigned)image.width, (unsigned)image.height, (unsigned)image.format,
          (unsigned)image.colormap_entries);

   if (argc > 2)
   {
      png_bytep buffer;
      size_t size;
      size_t k;

      image.format = (png_uint_32)strtol(argv[2], NULL, 0);
      size = PNG_IMAGE_SIZE(image);
      buffer = malloc(size != 0 ? size : 1);

      if (png_image_finish_read(&image, NULL, buffer, 0, NULL) == 0)
      {
         printf("finish failed: %s\n", image.message);
         free(buffer);
         return 1;
      }

      printf("read format=0x%x size=%u stride=%u\n", (unsigned)image.format,
             (unsigned)size, (unsigned)PNG_IMAGE_ROW_STRIDE(image));

      for (k = 0; k < size; k++)
      {
         if (k % 32 == 0) printf("\n ");

         printf(" %02x", buffer[k]);
      }

      printf("\n");
      free(buffer);
   }

   png_image_free(&image);

   return 0;
}
