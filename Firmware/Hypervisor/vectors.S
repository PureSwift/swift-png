// vectors.S - where a real fault goes to be reported rather than to vanish
//
// AArch64 requires VBAR_EL1 to point at a 2 KiB-aligned table of sixteen 0x80-byte slots before
// any synchronous exception, IRQ, FIQ or SError can be taken cleanly; leave it at its reset
// value and a real fault — a bad pointer, a misaligned access the MMU identity map in guest.c
// does not excuse, anything Swift's generated code did not expect — vectors through whatever
// VBAR_EL1 happens to hold, which is unmapped guest memory, producing a second fault on top of
// the first with no way to tell what the original one was.
//
// Every slot shares one handler: read the registers that say what happened (ELR_EL1, the
// return address; ESR_EL1, the cause; FAR_EL1, the faulting address for the exceptions that
// have one) and store them where the host loader knows to look, then WFI. A firmware meant to
// keep running after a fault would need sixteen different handlers; this one only needs to say
// what went wrong before stopping, which every slot can do identically. This is exactly what
// found the CPACR and MMU steps in guest.c: without it, both faults reported nothing more
// useful than "something happened."

.text
.align 11 // VBAR_EL1 must be 2 KiB (2^11) aligned
.global _vector_table
_vector_table:
.rept 16
.align 7 // each of the 16 vector slots is 0x80 bytes apart
mrs x0, elr_el1
mrs x1, esr_el1
mrs x2, far_el1
ldr x3, =0x40290000
str x0, [x3]
str x1, [x3, #8]
str x2, [x3, #16]
1: wfi
b 1b
.endr
