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

/* One dependent chain of the instruction, eight bytes a step. */
static inline uint32_t spng_crc32_chain(uint32_t crc, const uint8_t *bytes, size_t count)
{
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

/* Multiplication in GF(2)[x] modulo the format's polynomial, reflected representation:
 * x^0 is the top bit.  The reference's own combine arithmetic, verbatim in shape.
 */
static inline uint32_t spng_crc32_multmodp(uint32_t a, uint32_t b)
{
   uint32_t m = (uint32_t)1 << 31;
   uint32_t p = 0;

   for (;;)
   {
      if (a & m)
      {
         p ^= b;
         if ((a & (m - 1)) == 0) { break; }
      }

      m >>= 1;
      b = (b & 1) ? (b >> 1) ^ 0xEDB88320u : b >> 1;
   }

   return p;
}

/* x^(2^k) mod P, precomputed: what x^(8n) is assembled from along n's bits. */
static const uint32_t spng_crc32_x2n[32] = {
   0x40000000u, 0x20000000u, 0x08000000u, 0x00800000u, 0x00008000u, 0xedb88320u,
   0xb1e6b092u, 0xa06a2517u, 0xed627daeu, 0x88d14467u, 0xd7bbfe6au, 0xec447f11u,
   0x8e7ea170u, 0x6427800eu, 0x4d47bae0u, 0x09fe548fu, 0x83852d0fu, 0x30362f1au,
   0x7b5a9cc3u, 0x31fec169u, 0x9fec022au, 0x6c8dedc4u, 0x15d6874du, 0x5fde7a4eu,
   0xbad90e37u, 0x2e4e5eefu, 0x4eaba214u, 0xa8a472c0u, 0x429a969eu, 0x148d302au,
   0xc40ba6d0u, 0xc4e22c3cu,
};

/* x^(8n) mod P: the register's advance over n zero bytes, as a single multiplier. */
static inline uint32_t spng_crc32_advance(size_t n)
{
   uint32_t p = (uint32_t)1 << 31;
   unsigned k = 3;

   while (n != 0)
   {
      if (n & 1) { p = spng_crc32_multmodp(spng_crc32_x2n[k & 31], p); }
      n >>= 1;
      k++;
   }

   return p;
}

/* `crc` is the raw shift register, uninverted at both ends: the caller owns the
 * pre- and post-conditioning, the same contract its own table loop uses.
 *
 * A large buffer is split into three braided chains walked in one loop, because a single
 * chain is bound by the instruction's own latency: three registers in flight hide it, and
 * the three answers are stitched with the zero-block advance above.  Small buffers take
 * the plain chain — the stitching costs a fixed few microseconds of matrix arithmetic,
 * which a large buffer amortises and a chunk header would not.
 */
static inline uint32_t spng_crc32(uint32_t crc, const uint8_t *bytes, size_t count)
{
   while (((uintptr_t)bytes & 7) != 0 && count > 0)
   {
      crc = __crc32b(crc, *bytes++);
      count--;
   }

   if (count >= 3 * 2048)
   {
      size_t lane = (count / 3) & ~(size_t)7;
      const uint8_t *second = bytes + lane;
      const uint8_t *third = second + lane;
      size_t steps = lane / 8;

      /* The multiplier that stitches one lane onto the next.  The lane length is fixed by the
       * caller's own chunking in practice — an eight-kilobyte read splits as 2728 — so the
       * common advance is a constant and everything else is computed.
       */
      uint32_t advance = lane == 2728 ? 0x94b68ad7u : spng_crc32_advance(lane);

      uint32_t r1 = crc;
      uint32_t r2 = 0;
      uint32_t r3 = 0;

      for (size_t step = 0; step < steps; step++)
      {
         uint64_t w1, w2, w3;
         __builtin_memcpy(&w1, bytes + step * 8, 8);
         __builtin_memcpy(&w2, second + step * 8, 8);
         __builtin_memcpy(&w3, third + step * 8, 8);
         r1 = __crc32d(r1, w1);
         r2 = __crc32d(r2, w2);
         r3 = __crc32d(r3, w3);
      }

      crc = spng_crc32_multmodp(advance, r1) ^ r2;
      crc = spng_crc32_multmodp(advance, crc) ^ r3;

      bytes += 3 * lane;
      count -= 3 * lane;
   }

   return spng_crc32_chain(crc, bytes, count);
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
