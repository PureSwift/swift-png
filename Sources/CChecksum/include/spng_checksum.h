/* spng_checksum.h - the CRC-32 instruction, where the processor has one
 *
 * The checksum runs over every payload byte of a file, and a table-driven loop is the
 * largest single line in a decode's profile once no zlib is linked to do it in hardware.
 * ARM's CRC32 extension computes the same polynomial the format specifies, so where the
 * compiler says it exists this hands eight bytes at a time to the processor.
 *
 * Header-only, deliberately: the point of the build this serves is that it links nothing.
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

#if defined(__ARM_FEATURE_CRC32)

#include <arm_acle.h>

static inline int spng_crc32_in_hardware(void)
{
   return 1;
}

/* `crc` is the raw shift register, uninverted at both ends: the caller owns the
 * pre- and post-conditioning, the same contract its own table loop uses.
 */
static inline uint32_t spng_crc32(uint32_t crc, const uint8_t *bytes, size_t count)
{
   while (((uintptr_t)bytes & 7) != 0 && count > 0)
   {
      crc = __crc32b(crc, *bytes++);
      count--;
   }

   while (count >= 8)
   {
      uint64_t word;
      __builtin_memcpy(&word, bytes, 8);
      crc = __crc32d(crc, word);
      bytes += 8;
      count -= 8;
   }

   while (count > 0)
   {
      crc = __crc32b(crc, *bytes++);
      count--;
   }

   return crc;
}

#else

static inline int spng_crc32_in_hardware(void)
{
   return 0;
}

/* Correct but never the fast path: a caller is expected to ask the function above and
 * keep its own loop when the answer is no.  Present so the pair is always well-formed.
 */
static inline uint32_t spng_crc32(uint32_t crc, const uint8_t *bytes, size_t count)
{
   while (count > 0)
   {
      crc ^= *bytes++;

      for (int bit = 0; bit < 8; bit++)
      {
         crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
      }

      count--;
   }

   return crc;
}

#endif
