#include "port.h"
static const unsigned marker = 0x5eed1234u;
static unsigned probe;

static void user_task(void) {
    unsigned value;
    __asm__ volatile(".globl fault_site\nfault_site: lw %0, 0(%1)" : "=r"(value) : "r"(probe) : "memory");
    (void)value;
    for (;;) {
    }
}

int main(void) {
    probe = (unsigned)&marker;
    unsigned flash = 0u | ((0x100000u / 8u) - 1u);
    unsigned ram = (0x200000u >> 2) | ((0x100000u / 8u) - 1u);
    __asm__ volatile("csrw pmpaddr0, %0\n\tcsrw pmpaddr1, %1\n\tcsrw pmpcfg0, %2"
                     :: "r"(flash), "r"(ram), "r"(0x1b1cu));
    csr_write("mstatus", csr_read("mstatus") & ~0x1800u);
    csr_write("mepc", (unsigned)user_task);
    __asm__ volatile("mret");
    return 0;
}
