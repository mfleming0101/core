#include "port.h"
static unsigned table[64] __attribute__((aligned(256)));

int main(void) {
    table[0] = 0xffffffffu;
    csr_write("mtvec", (unsigned)table);
    __asm__ volatile(".globl fault_site\nfault_site: ecall");
    console_put('.');
    return 0;
}
