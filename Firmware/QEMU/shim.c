// shim.c - what a hosted C library would otherwise provide
//
// Two different things live here, and the distinction matters. The Host abstraction in
// Sources/PNG/Memory/Host.swift is how this library gets its buffers everywhere it runs —
// that seam is what lets this file hand it a bump allocator instead of a real one. But Embedded
// Swift's own runtime — allocating a class instance, zero-filling a struct, seeding the
// Hashable salt — reaches for a small fixed set of POSIX- and EABI-shaped C symbols directly,
// under the assumption that *something* provides them, the way libc would on every other
// target this library builds for. This file is that something, sized for a demonstration
// rather than for production: a single arena, freed all at once, and library routines
// implemented as the handful of lines each one actually needs on this target rather than
// pulled in from a portable library that assumes more platform than exists here.

#include <stddef.h>
#include <stdint.h>

// -- allocation --------------------------------------------------------------

// Sized for one encode-then-decode of the smoke test's image, dominated by LZ77.Deflate's
// match-finding hash table (32768 Int entries — 128 KiB on this 32-bit target) at the default
// compression level. A real firmware would tune the compression settings, the arena, or both.
static unsigned char arena[1024 * 1024] __attribute__((aligned(16)));
static size_t arena_offset = 0;

void write0(const char *s);
void write_uint(uint32_t value);
void exit_semihosting(int code);

// Not static: this is also what App.swift hands to PNG as its Host allocator, separately
// from the posix_memalign path Embedded Swift's own runtime uses for class instances.
void *bump_malloc(size_t size) {
    size = (size + 15) & ~((size_t)15);

    if (arena_offset + size > sizeof(arena)) return NULL;

    void *block = &arena[arena_offset];
    arena_offset += size;
    return block;
}

// Freed in bulk by resetting the arena between images rather than reclaimed piece by piece:
// this library only ever needs one context's worth of memory live at a time in this harness.
void bump_free(void *ptr) { (void)ptr; }

void bump_reset(void) { arena_offset = 0; }

int posix_memalign(void **memptr, size_t alignment, size_t size) {
    unsigned char *raw = (unsigned char *)bump_malloc(size + alignment);

    if (!raw) {
        write0("posix_memalign OOM: size=");
        write_uint((uint32_t)size);
        write0(" align=");
        write_uint((uint32_t)alignment);
        write0(" used=");
        write_uint((uint32_t)arena_offset);
        write0("\n");
        return 12; // ENOMEM
    }

    uintptr_t aligned = ((uintptr_t)raw + alignment - 1) & ~(uintptr_t)(alignment - 1);
    *memptr = (void *)aligned;
    return 0;
}

void free(void *ptr) { bump_free(ptr); }
void *malloc(size_t size) { return bump_malloc(size); }

// -- ARM semihosting: this target's only I/O ---------------------------------
//
// A debug facility QEMU (and real debug probes) implement by trapping a fixed breakpoint
// instruction and inspecting r0/r1 for an operation number and its argument, per the ARM
// Semihosting specification. There is no UART configured on this board model, so this is the
// only way bytes leave the emulated machine.

void write0(const char *s) {
    register long r0 __asm__("r0") = 0x04; // SYS_WRITE0
    register long r1 __asm__("r1") = (long)s;
    __asm__ volatile("bkpt 0xAB" : "+r"(r0) : "r"(r1));
}

void exit_semihosting(int code) {
    static volatile long block[2];
    block[0] = 0x20026; // ADP_Stopped_ApplicationExit
    block[1] = code;

    register long r0 __asm__("r0") = 0x18; // SYS_EXIT
    register long r1 __asm__("r1") = (long)block;
    __asm__ volatile("bkpt 0xAB" : "+r"(r0) : "r"(r1));
}

// A number, printed without pulling in libc's own formatting.
void write_uint(uint32_t value) {
    char buf[11];
    int i = 10;
    buf[10] = 0;

    if (value == 0) {
        write0("0");
        return;
    }

    while (value > 0 && i > 0) {
        buf[--i] = '0' + (value % 10);
        value /= 10;
    }

    write0(&buf[i]);
}

void write_hex(uint32_t value) {
    char buf[9];
    const char *digits = "0123456789abcdef";

    for (int i = 7; i >= 0; i--) {
        buf[i] = digits[value & 0xF];
        value >>= 4;
    }

    buf[8] = 0;
    write0(buf);
}

// -- the DWT cycle counter ------------------------------------------------
//
// Wired up and left in place even though QEMU's Cortex-M model does not implement it (it reads
// zero throughout): on real hardware this is what a firmware would read, and stripping it back
// out would make the difference between an emulator and real silicon into something this file
// no longer says out loud.

#define DEMCR (*(volatile uint32_t *)0xE000EDFC)
#define DWT_CTRL (*(volatile uint32_t *)0xE0001000)
#define DWT_CYCCNT (*(volatile uint32_t *)0xE0001004)

void dwt_enable(void) {
    DEMCR |= (1 << 24); // TRCENA
    DWT_CYCCNT = 0;
    DWT_CTRL |= 1; // CYCCNTENA
}

uint32_t dwt_cycles(void) { return DWT_CYCCNT; }

// -- what the ARM EABI and Embedded Swift's runtime call directly ------------
//
// A hosted C library supplies these without a client ever naming them: the EABI's own calling
// convention lowers a struct copy or a zero-fill to a call to one of the `__aeabi_*` names
// below rather than inlining it, and Swift's runtime reaches for `arc4random_buf` to seed
// `Hashable`'s per-process salt the first time anything hashes. Each is implemented as exactly
// what it needs to be on a target with no entropy source and no cache hierarchy to exploit —
// not copied from a real libc, because a real libc is precisely what is absent here.

uintptr_t __stack_chk_guard = 0xDEADBEEF;

void __stack_chk_fail(void) {
    write0("STACK SMASHING DETECTED\n");
    exit_semihosting(99);
}

void __aeabi_memclr(void *dest, size_t n) {
    unsigned char *d = (unsigned char *)dest;
    while (n--) *d++ = 0;
}

void __aeabi_memclr4(void *dest, size_t n) { __aeabi_memclr(dest, n); }
void __aeabi_memclr8(void *dest, size_t n) { __aeabi_memclr(dest, n); }

void __aeabi_memset(void *dest, size_t n, int c) {
    unsigned char *d = (unsigned char *)dest;
    while (n--) *d++ = (unsigned char)c;
}

void __aeabi_memset4(void *dest, size_t n, int c) { __aeabi_memset(dest, n, c); }
void __aeabi_memset8(void *dest, size_t n, int c) { __aeabi_memset(dest, n, c); }

void *__aeabi_memcpy(void *dest, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) *d++ = *s++;
    return dest;
}

void *__aeabi_memcpy4(void *dest, const void *src, size_t n) {
    return __aeabi_memcpy(dest, src, n);
}
void *__aeabi_memcpy8(void *dest, const void *src, size_t n) {
    return __aeabi_memcpy(dest, src, n);
}

void *__aeabi_memmove(void *dest, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;

    if (d < s) {
        while (n--) *d++ = *s++;
    } else {
        d += n;
        s += n;
        while (n--) *--d = *--s;
    }

    return dest;
}

void *__aeabi_memmove4(void *dest, const void *src, size_t n) {
    return __aeabi_memmove(dest, src, n);
}
void *__aeabi_memmove8(void *dest, const void *src, size_t n) {
    return __aeabi_memmove(dest, src, n);
}

// No entropy source on bare metal; a fixed xorshift stream seeds Swift's Hashable/Dictionary
// salt. Fine for this smoke test, which does not rely on hash order and has no adversary.
void arc4random_buf(void *buffer, size_t count) {
    static uint32_t state = 0x2545F491;
    unsigned char *b = (unsigned char *)buffer;

    while (count--) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        *b++ = (unsigned char)state;
    }
}

// No libm on this target either. A cast-and-adjust floor is exact across the range this
// library's gamma arithmetic uses (small values near 0..65535), which is well inside what a
// 64-bit integer represents exactly.
double floor(double x) {
    long long truncated = (long long)x;
    double result = (double)truncated;

    if (result > x) result -= 1.0;

    return result;
}

double round(double x) {
    if (x >= 0) return floor(x + 0.5);

    double f = floor(x);
    return (x - f >= 0.5) ? f + 1.0 : f;
}
