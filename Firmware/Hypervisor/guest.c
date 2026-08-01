// guest.c - what a hosted C library and a boot ROM would otherwise provide
//
// The counterpart to Firmware/QEMU/shim.c, for a different kind of "bare metal": this code
// runs inside a VM created by Hypervisor.framework rather than inside an emulated microcontroller,
// but the obligation is the same — Embedded Swift's own runtime still reaches for a small set of
// POSIX- and EABI-shaped C symbols directly, and this file is what answers.
//
// It carries one job the Cortex-M firmware does not have to: this environment starts the vCPU
// exactly where the architecture resets it, not where a board's boot ROM would leave it, so
// reset_entry brings the core the rest of the way up itself — enabling the FPU, building a
// one-entry identity page table, and turning the MMU on — before Swift's generated code, which
// assumes all of that already happened, gets to run.

#include <stddef.h>
#include <stdint.h>

// -- allocation --------------------------------------------------------------

static unsigned char arena[2 * 1024 * 1024] __attribute__((aligned(16)));
static size_t arena_offset = 0;

void *bump_malloc(size_t size) {
    size = (size + 15) & ~((size_t)15);

    if (arena_offset + size > sizeof(arena)) return NULL;

    void *block = &arena[arena_offset];
    arena_offset += size;
    return block;
}

void bump_free(void *ptr) { (void)ptr; }

int posix_memalign(void **memptr, size_t alignment, size_t size) {
    unsigned char *raw = (unsigned char *)bump_malloc(size + alignment);

    if (!raw) return 12; // ENOMEM

    uintptr_t aligned = ((uintptr_t)raw + alignment - 1) & ~(uintptr_t)(alignment - 1);
    *memptr = (void *)aligned;
    return 0;
}

void free(void *ptr) { bump_free(ptr); }
void *malloc(size_t size) { return bump_malloc(size); }

// -- what a hosted libc would otherwise supply --------------------------------
//
// Full-size versions rather than EABI-style split names this time: this is Mach-O, linked with
// Apple's own `ld` against ordinary `_memcpy`/`_memset`/`_memmove` symbol names, not the
// `__aeabi_*` family the GNU ARM EABI toolchain in Firmware/QEMU calls instead.

void *memset(void *dest, int c, size_t n) {
    unsigned char *d = (unsigned char *)dest;
    while (n--) *d++ = (unsigned char)c;
    return dest;
}

void *memcpy(void *dest, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) *d++ = *s++;
    return dest;
}

void *memmove(void *dest, const void *src, size_t n) {
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

uintptr_t __stack_chk_guard = 0xDEADBEEF;
void __stack_chk_fail(void) {
    while (1) { __asm__ volatile("wfi"); }
}

// No entropy source; a fixed xorshift stream seeds Swift's Hashable/Dictionary salt. Fine for a
// smoke test with no adversary and no dependence on hash order.
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

// No libm on this target either.
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

// A real cycle counter is available on some Apple Silicon at EL1 (PMCCNTR_EL0-style access is
// gated behind PMUSERENR_EL0, which the reset state does not grant), so this stays a stub for
// the same honest reason Firmware/QEMU's DWT reading stays zero: no meaningful number is worth
// reporting without one, and a fabricated one would be worse than none.
uint32_t dwt_cycles(void) { return 0; }

// -- the only I/O this environment has ----------------------------------------
//
// A growing log buffer at a fixed guest address, read back by the host loader as a plain C
// string once the vCPU has stopped. There is no console device model here the way QEMU's board
// models provide one — Hypervisor.framework gives a CPU and memory, nothing else — so this and
// the result word below are this firmware's entire contract with the process hosting it.

static char *log_buffer = (char *)0x40300000UL;
static size_t log_offset = 0;
static const size_t log_capacity = 0x100000;

void write0(const char *s) {
    while (*s && log_offset + 1 < log_capacity) {
        log_buffer[log_offset++] = *s++;
    }

    log_buffer[log_offset] = 0;
}

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

// -- bringing the core the rest of the way up ---------------------------------

extern int swift_main(void);
extern char vector_table[];

// A level-1 translation table for a 4 KiB granule, 39-bit input address space: 512 entries of
// 1 GiB each. Only entry 1 (covering 0x40000000...0x7FFFFFFF, which is all of guest RAM) is ever
// made valid; every other gigabyte of address space stays a translation fault, which is correct
// for an identity map that has no reason to cover more than it uses.
static uint64_t l1_table[512] __attribute__((aligned(4096)));

int reset_entry(void) {
    __asm__ volatile("msr vbar_el1, %0" ::"r"(vector_table));

    // PNGCore's gamma correction uses Double arithmetic, which on AArch64 means SIMD/FP register
    // access — trapped by default at EL1 until CPACR_EL1.FPEN is set, the same requirement the
    // Cortex-M firmware's CPACR FPU-enable step exists for.
    uint64_t cpacr;
    __asm__ volatile("mrs %0, cpacr_el1" : "=r"(cpacr));
    cpacr |= (3UL << 20); // FPEN = 0b11: no trapping
    __asm__ volatile("msr cpacr_el1, %0" ::"r"(cpacr));

    // With the MMU off, EL1 accesses fall back to a stricter default memory type that enforces
    // natural alignment on every access — not only the ones the architecture normally requires
    // — which a 128-bit SIMD register spill in the Swift runtime's own prologue does not always
    // land on. Clearing SCTLR_EL1.A alone does not change this; the fix is what real AArch64
    // bring-up does next regardless: turn the MMU on, with a one-entry identity map so ordinary
    // Normal-memory rules apply to the whole of guest RAM.
    l1_table[1] =
        0x1             // valid, block descriptor at level 1
        | (0b11UL << 8) // SH = inner shareable
        | (1UL << 10)   // AF = 1 (access flag; unset and every access faults)
        | 0x40000000UL; // output address: the 1 GiB block starting at guest RAM's base

    __asm__ volatile("msr mair_el1, %0" ::"r"((uint64_t)0xFF)); // index 0: Normal WB
    __asm__ volatile("msr ttbr0_el1, %0" ::"r"((uint64_t)l1_table));

    uint64_t tcr = 25UL      // T0SZ = 25: 39-bit input address space
        | (0b01UL << 8)      // IRGN0 = Normal WB, read/write-allocate
        | (0b01UL << 10)     // ORGN0 = same
        | (0b11UL << 12)     // SH0 = inner shareable
        | (1UL << 23);       // EPD1 = 1: no TTBR1 walk, this map only covers low VA
    __asm__ volatile("msr tcr_el1, %0" ::"r"(tcr));
    __asm__ volatile("isb" ::: "memory");

    uint64_t sctlr;
    __asm__ volatile("mrs %0, sctlr_el1" : "=r"(sctlr));
    sctlr |= 1UL;         // M = 1: enable the MMU
    sctlr &= ~(1UL << 1); // A = 0: no need for stricter-than-architectural alignment either
    __asm__ volatile("msr sctlr_el1, %0" ::"r"(sctlr));
    __asm__ volatile("isb" ::: "memory");

    arena_offset = 0;
    log_offset = 0;
    log_buffer[0] = 0;

    int result = swift_main();

    volatile int *result_slot = (volatile int *)0x40280000UL;
    *result_slot = result;

    // A real hypervisor trap rather than the accidental one an unhandled exception would cause:
    // WFI is architecturally defined to exit to the host, needs no vector table of its own, and
    // by the time it runs, everything above has already been committed to guest memory for the
    // host to read.
    __asm__ volatile("wfi");
    return result;
}
