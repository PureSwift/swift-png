/* link.ld - where things live on the mps2-an386 model this firmware targets
 *
 * Sized generously rather than to the letter of any real chip: this exists to prove the code
 * runs correctly, not to fit a specific part's flash and RAM budget.  RAM in particular is
 * 8 MiB against a 1 MiB arena in shim.c, which leaves headroom to raise the arena for a larger
 * test image without moving this file too.
 */

MEMORY {
    FLASH (rx) : ORIGIN = 0x00000000, LENGTH = 4M
    RAM (rwx)  : ORIGIN = 0x20000000, LENGTH = 8M
}

SECTIONS {
    .isr_vector : { KEEP(*(.isr_vector)) } > FLASH

    .text : { *(.text*) *(.rodata*) } > FLASH

    _sidata = LOADADDR(.data);

    .data : {
        _sdata = .;
        *(.data*)
        _edata = .;
    } > RAM AT> FLASH

    .bss : {
        _sbss = .;
        *(.bss*)
        *(COMMON)
        _ebss = .;
    } > RAM

    . = ALIGN(8);
    . = . + 0x1000; /* the stack, growing down from _estack */
    _estack = .;
}
