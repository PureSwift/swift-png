// loader.c - the "board" for a target no emulator models
//
// Firmware/QEMU's firmware boots on a real emulated board (mps2-an386) that already knows how
// to load an ELF, map memory and reset a CPU. There is no such board for arm64-apple-none-macho:
// Apple ships an embedded standard library for it, meant for real bare-metal contexts like the
// m1n1/Asahi bootloader family, but no emulator to run the result on. Hypervisor.framework is
// the closest thing this host has — a normal, unprivileged macOS process can ask it for a raw
// ARM64 core and a block of memory, with nothing else assumed. Everything an emulated board
// would normally provide, this file provides instead: it parses the Mach-O executable's own
// segment and entry-point load commands to know what to place where, maps guest memory by hand,
// and sets the initial program counter — a minimal, special-purpose Mach-O loader existing
// because the general-purpose one only ever loads things dyld already understands.

#include <Hypervisor/Hypervisor.h>
#include <fcntl.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define CHECK(expression)                                                                       \
    do {                                                                                         \
        hv_return_t status = (expression);                                                       \
        if (status != HV_SUCCESS) {                                                              \
            fprintf(stderr, "%s failed: 0x%x\n", #expression, status);                           \
            return 1;                                                                            \
        }                                                                                        \
    } while (0)

// Where the guest firmware's own log buffer and result word live — fixed addresses guest.c
// writes to and this loader reads back from, the whole of the contract between the two sides.
static const uint64_t log_address = 0x40300000ULL;
static const uint64_t result_address = 0x40280000ULL;

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: loader <mach-o executable>\n");
        return 2;
    }

    int fd = open(argv[1], O_RDONLY);

    if (fd < 0) {
        perror("open");
        return 2;
    }

    struct stat info;
    fstat(fd, &info);

    uint8_t *file = mmap(NULL, (size_t)info.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);

    if (file == MAP_FAILED) {
        perror("mmap");
        return 2;
    }

    struct mach_header_64 *header = (struct mach_header_64 *)file;

    if (header->magic != MH_MAGIC_64) {
        fprintf(stderr, "not a 64-bit Mach-O executable\n");
        return 2;
    }

    CHECK(hv_vm_create(NULL));

    // A flat 16 MiB guest RAM window starting where the linked image expects to be loaded.
    // Generous rather than exact: this exists to prove correctness, not to fit a real part's
    // memory budget, and headroom here is what let the arena in guest.c grow without this file
    // moving too.
    hv_ipa_t guest_base = 0x40000000ULL;
    size_t guest_size = 16 * 1024 * 1024;

    void *guest_mem = mmap(NULL, guest_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    CHECK(hv_vm_map(
        guest_mem, guest_base, guest_size, HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC
    ));

    uint64_t entry_pc = 0;
    uint8_t *command = file + sizeof(struct mach_header_64);

    for (uint32_t index = 0; index < header->ncmds; index++) {
        struct load_command *load = (struct load_command *)command;

        if (load->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment = (struct segment_command_64 *)load;

            if (segment->filesize > 0) {
                uint64_t offset_in_guest = segment->vmaddr - guest_base;
                memcpy(
                    (uint8_t *)guest_mem + offset_in_guest,
                    file + segment->fileoff,
                    segment->filesize
                );
            }
        } else if (load->cmd == LC_UNIXTHREAD) {
            // ARM_THREAD_STATE64: a flavor word, a count word, then 29 general registers
            // (x0...x28), fp, lr, sp, pc, then cpsr. The entry point this executable was linked
            // to start at is exactly what the reset vector of a real board would be told to
            // jump to, just expressed the way a linker records it instead.
            uint64_t *registers = (uint64_t *)(command + sizeof(struct load_command) + 8);
            entry_pc = registers[32];
        }

        command += load->cmdsize;
    }

    if (entry_pc == 0) {
        fprintf(stderr, "no entry point found in the executable\n");
        return 2;
    }

    hv_vcpu_t vcpu;
    hv_vcpu_exit_t *exit_info;
    CHECK(hv_vcpu_create(&vcpu, &exit_info, NULL));

    // A stack well clear of the loaded segments, growing down from near the top of guest RAM.
    uint64_t stack_top = guest_base + guest_size - 0x1000;

    CHECK(hv_vcpu_set_reg(vcpu, HV_REG_PC, entry_pc));
    CHECK(hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_SP_EL1, stack_top));
    CHECK(hv_vcpu_set_reg(vcpu, HV_REG_CPSR, 0x3c5)); // EL1h, interrupts masked

    CHECK(hv_vcpu_run(vcpu));

    if (exit_info->reason != HV_EXIT_REASON_EXCEPTION) {
        fprintf(stderr, "unexpected exit reason: %u\n", exit_info->reason);
        return 1;
    }

    uint64_t *fault = (uint64_t *)((uint8_t *)guest_mem + (0x40290000ULL - guest_base));

    if (fault[0] != 0) {
        // The vector table only ever writes here on a real, unhandled exception — a genuine
        // WFI exit leaves it zeroed — so anything present here is a fault the firmware did not
        // expect, not this loader's own stopping signal.
        fprintf(
            stderr, "guest firmware faulted: elr=0x%llx esr=0x%llx far=0x%llx\n",
            fault[0], fault[1], fault[2]
        );
        return 1;
    }

    char *log = (char *)guest_mem + (log_address - guest_base);
    printf("%s", log);

    int32_t *result = (int32_t *)((uint8_t *)guest_mem + (result_address - guest_base));
    printf("swift_main() returned: %d\n", *result);

    hv_vcpu_destroy(vcpu);
    hv_vm_destroy();

    return *result == 0 ? 0 : 1;
}
