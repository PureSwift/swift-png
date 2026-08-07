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

#if defined(__ARM_FEATURE_AES) || defined(__ARM_FEATURE_CRYPTO)

#include <arm_neon.h>

#define SPNG_CRC32_FOLDED 1

/* Folding moves a 128-bit block of the message forward past `n` bits of zeros by carryless
 * multiplication: each 64-bit half times x^(distance to where that half's contribution must
 * land), both products XORed.  The multipliers are x^n mod P in the same reflected bit order
 * the instruction uses, shifted up one so the product's alignment matches what the final
 * per-doubleword reduction below expects; with that convention a fold by the constant pair
 * for n advances the block n+32 bits, which the distances here already account for.
 */
static inline uint64x2_t spng_crc32_fold128(uint64x2_t block, poly64x2_t k)
{
   uint64x2_t low = vreinterpretq_u64_p128(
      vmull_p64((poly64_t)vgetq_lane_u64(block, 0), (poly64_t)vgetq_lane_p64(k, 0)));
   uint64x2_t high = vreinterpretq_u64_p128(vmull_high_p64(vreinterpretq_p64_u64(block), k));
   return veorq_u64(low, high);
}

static inline poly64x2_t spng_crc32_fold_k(uint64_t low, uint64_t high)
{
   return vreinterpretq_p64_u64(vcombine_u64(vcreate_u64(low), vcreate_u64(high)));
}

/* Standing distances from each accumulator's block to the last one's: seven blocks
 * ahead down to one, each less the 32 bits the reduction convention already advances.
 */
static const uint64_t spng_crc32_fold_comb[7][2] = {
   {0x1ea89367eull, 0x1d7cfc6acull},
   {0x0df068dc2ull, 0x18cb44e58ull},
   {0x1c7569e54ull, 0x0ae0b5394ull},
   {0x154442bd4ull, 0x1c6e41596ull},
   {0x03db1ecdcull, 0x174359406ull},
   {0x0f1da05aaull, 0x15a546366ull},
   {0x1751997d0ull, 0x0ccaa009eull},
};

/* The wide bulk loop: eight 128-bit accumulators stride 128 bytes a step, each folded
 * over the 1024 bits between one of its blocks and the next and XORed with the incoming
 * block.  Eight independent fold-XOR chains cover the multiplier's latency the same way
 * the braid below covers the CRC instruction's — eight is the measured knee, wider
 * spills registers and pays a longer combine for nothing.  The accumulators are then
 * folded onto the last one at their standing distances, reduced to the 32-bit register
 * with two CRC instruction steps (which divide by x^128 exactly, since a fold by zero
 * bits is the identity), and the sub-stride remainder goes through the plain chain.
 *
 * Same raw-register contract as everything here: no inversion at either end.
 */
static inline uint32_t spng_crc32_folded(uint32_t crc, const uint8_t *bytes, size_t count)
{
   /* x^(n+64) and x^n for n = 992: one 128-byte stride back from the same block position. */
   const poly64x2_t step = spng_crc32_fold_k(0x1e88ef372ull, 0x14a7fe880ull);

   uint64x2_t a[8];

   for (int i = 0; i < 8; i++)
   {
      a[i] = vreinterpretq_u64_u8(vld1q_u8(bytes + 16 * i));
   }

   /* The incoming register enters as the first four message bytes do: XORed in place. */
   a[0] = veorq_u64(a[0], vcombine_u64(vcreate_u64((uint64_t)crc), vcreate_u64(0)));

   size_t offset = 128;

   while (offset + 128 <= count)
   {
      for (int i = 0; i < 8; i++)
      {
         a[i] = veorq_u64(
            spng_crc32_fold128(a[i], step),
            vreinterpretq_u64_u8(vld1q_u8(bytes + offset + 16 * i)));
      }

      offset += 128;
   }

   uint64x2_t total = a[7];

   for (int i = 0; i < 7; i++)
   {
      total = veorq_u64(total, spng_crc32_fold128(
         a[i], spng_crc32_fold_k(spng_crc32_fold_comb[i][0], spng_crc32_fold_comb[i][1])));
   }

   crc = __crc32d(0, vgetq_lane_u64(total, 0));
   crc = __crc32d(crc, vgetq_lane_u64(total, 1));

   return spng_crc32_chain(crc, bytes + offset, count - offset);
}

#endif

/* `crc` is the raw shift register, uninverted at both ends: the caller owns the
 * pre- and post-conditioning, the same contract its own table loop uses.
 *
 * A large buffer goes through the carryless-multiply fold where the processor has one:
 * that path moves 64 bytes per step and is bound only by the multiplier's throughput.
 * Otherwise it is split into three braided chains walked in one loop, because a single
 * chain of the CRC instruction is bound by its own latency: three registers in flight
 * hide it, and the three answers are stitched with the zero-block advance above.  Small
 * buffers take the plain chain — both wide paths cost a fixed setup that a large buffer
 * amortises and a chunk header would not.
 */
static inline uint32_t spng_crc32(uint32_t crc, const uint8_t *bytes, size_t count)
{
#if defined(SPNG_CRC32_FOLDED)
   if (count >= 192)
   {
      return spng_crc32_folded(crc, bytes, count);
   }
#endif

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
