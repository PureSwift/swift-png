// startup.c - the eleven instructions that run before anything else does
//
// A Cortex-M has no boot ROM to speak of: reset loads the stack pointer and the first
// instruction address straight out of two words at the bottom of flash, and from there it is
// software's job to get the machine into a state C and Swift can assume — a stack, zeroed BSS,
// initialized data, and the FPU turned on before the first double is touched.
//
// The fault handler exists because a silent hang here is nearly undebuggable on real hardware
// and only slightly less so under an emulator: it decodes the automatically-stacked exception
// frame to report where execution was and what the fault status registers say, rather than
// leaving a CI run to time out with no explanation.

#include <stdint.h>

extern uint32_t _estack;
extern uint32_t _sidata, _sdata, _edata, _sbss, _ebss;
void Reset_Handler(void);
void Default_Handler(void);

__attribute__((naked, noreturn)) static void spin(void) { while (1) {} }

extern void write0(const char *);
extern void write_uint(unsigned int);
extern void write_hex(unsigned int);

void hardfault_dump(unsigned int *stacked) {
    write0("HARDFAULT pc=0x"); write_hex(stacked[6]);
    write0(" lr=0x"); write_hex(stacked[5]);
    write0(" cfsr=0x"); write_hex(*(volatile unsigned int *)0xE000ED28);
    write0(" hfsr=0x"); write_hex(*(volatile unsigned int *)0xE000ED2C);
    write0("\n");
    spin();
}

__attribute__((naked)) void HardFault_Handler(void) {
    __asm__ volatile(
        "tst lr, #4 \n"
        "ite eq \n"
        "mrseq r0, msp \n"
        "mrsne r0, psp \n"
        "b hardfault_dump \n"
    );
}

__attribute__((section(".isr_vector")))
void (* const vectors[])(void) = {
    (void (*)(void))&_estack,
    Reset_Handler,
    Default_Handler, HardFault_Handler, Default_Handler, Default_Handler,
    0, 0, 0, 0, 0,
    Default_Handler, Default_Handler, 0, Default_Handler, Default_Handler,
};

void Default_Handler(void) { spin(); }

extern int main(void);

void Reset_Handler(void) {
    // The Swift code below stores doubles in FPU registers regardless of the soft-float ABI
    // used for argument passing; without this the first such instruction traps as NOCP, since
    // Cortex-M leaves its coprocessors disabled until software asks for them.
    *(volatile uint32_t *)0xE000ED88 |= (0xF << 20);
    __asm__ volatile("dsb" ::: "memory");
    __asm__ volatile("isb" ::: "memory");

    uint32_t *src = &_sidata, *dst = &_sdata;
    while (dst < &_edata) *dst++ = *src++;
    dst = &_sbss;
    while (dst < &_ebss) *dst++ = 0;
    main();
    spin();
}
