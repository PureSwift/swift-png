/* version_probe.c - the substitutability check
 *
 * Compiled against the reference libpng headers, not ours, and linked against
 * this library.  That is the whole point of the exercise: a program built for
 * libpng has to work against us without being changed or recompiled against
 * different declarations.
 *
 * It exercises only the functions that need no library state, so it stays
 * meaningful from the first commit onwards and grows into the fuller
 * conformance programs later.
 */

#include <png.h>

#include <stdio.h>
#include <string.h>

static int failures = 0;

static void
check(int condition, const char *what)
{
   if (!condition)
   {
      fprintf(stderr, "FAIL: %s\n", what);
      ++failures;
   }
}

static void
check_version(void)
{
   png_uint_32 runtime = png_access_version_number();

   /* The library must report the version its header advertises; a client that
    * compiled against a different one would be relying on declarations we do
    * not provide.
    */
   check(runtime == PNG_LIBPNG_VER, "png_access_version_number matches header");
   check(strcmp(png_get_libpng_ver(NULL), PNG_LIBPNG_VER_STRING) == 0,
       "png_get_libpng_ver matches header");
   check(strcmp(png_get_header_ver(NULL), PNG_LIBPNG_VER_STRING) == 0,
       "png_get_header_ver matches header");

   /* Not simply PNG_HEADER_VERSION_STRING: the reference build appends a further
    * newline, so the text ends in a blank line.  Checked exactly, because
    * programs print it verbatim.
    */
   check(strcmp(png_get_header_version(NULL), PNG_HEADER_VERSION_STRING "\n") == 0,
       "png_get_header_version matches header plus its trailing newline");

   /* The reference build starts the notice with a newline and lists the
    * copyright holders in a fixed order; anything printing it expects that
    * shape.
    */
   check(strcmp(png_get_copyright(NULL),
       "\nlibpng version " PNG_LIBPNG_VER_STRING "\n"
       "Copyright (c) 2018-2026 Cosmin Truta\n"
       "Copyright (c) 1998-2002,2004,2006-2018 Glenn Randers-Pehrson\n"
       "Copyright (c) 1996-1997 Andreas Dilger\n"
       "Copyright (c) 1995-1996 Guy Eric Schalnat, Group 42, Inc.\n") == 0,
       "png_get_copyright matches the reference notice");
}

static void
check_signature(void)
{
   png_byte good[8] = { 137, 80, 78, 71, 13, 10, 26, 10 };
   png_byte bad[8] = { 137, 80, 78, 72, 13, 10, 26, 10 };

   check(png_sig_cmp(good, 0, 8) == 0, "png_sig_cmp accepts the signature");
   check(png_sig_cmp(bad, 0, 8) != 0, "png_sig_cmp rejects a corrupt signature");
   check(png_sig_cmp(good, 0, 4) == 0, "png_sig_cmp accepts a prefix");
   check(png_sig_cmp(bad, 0, 3) == 0, "png_sig_cmp ignores bytes past the range");
   check(png_sig_cmp(good, 4, 4) == 0, "png_sig_cmp honours a start offset");
}

static void
check_integers(void)
{
   png_byte buf[4];

   png_save_uint_32(buf, 0x01020304U);
   check(buf[0] == 1 && buf[1] == 2 && buf[2] == 3 && buf[3] == 4,
       "png_save_uint_32 writes big-endian");
   check(png_get_uint_32(buf) == 0x01020304U, "png_get_uint_32 round-trips");

   png_save_uint_16(buf, 0xABCDU);
   check(buf[0] == 0xAB && buf[1] == 0xCD, "png_save_uint_16 writes big-endian");
   check(png_get_uint_16(buf) == 0xABCDU, "png_get_uint_16 round-trips");

   png_save_int_32(buf, -66051);
   check(buf[0] == 0xFF && buf[1] == 0xFE && buf[2] == 0xFD && buf[3] == 0xFD,
       "png_save_int_32 writes two's complement");
   check(png_get_int_32(buf) == -66051, "png_get_int_32 round-trips a negative");

   png_save_int_32(buf, 66051);
   check(png_get_int_32(buf) == 66051, "png_get_int_32 round-trips a positive");

   png_save_int_32(buf, -1);
   check(png_get_int_32(buf) == -1, "png_get_int_32 round-trips minus one");

   /* The most negative pattern has no valid negation and appears in no
    * conforming stream, so it reads back as zero rather than trapping.
    */
   buf[0] = 0x80;
   buf[1] = 0x00;
   buf[2] = 0x00;
   buf[3] = 0x00;
   check(png_get_int_32(buf) == 0, "png_get_int_32 rejects the unrepresentable value");
}

static void
check_grayscale_palette(void)
{
   png_color palette[256];

   memset(palette, 0, sizeof palette);
   png_build_grayscale_palette(4, palette);

   check(palette[0].red == 0x00, "grey ramp starts at black");
   check(palette[1].red == 0x11, "grey ramp steps evenly");
   check(palette[15].red == 0xFF, "grey ramp ends at white");
   check(palette[15].red == palette[15].green &&
       palette[15].red == palette[15].blue, "grey ramp is neutral");
}

int
main(void)
{
   check_version();
   check_signature();
   check_integers();
   check_grayscale_palette();

   if (failures != 0)
   {
      fprintf(stderr, "%d check(s) failed\n", failures);
      return 1;
   }

   printf("version_probe: all checks passed against libpng %s\n",
       png_get_libpng_ver(NULL));
   return 0;
}
