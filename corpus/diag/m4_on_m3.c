#include "port.h"

int main(void) {
    __asm__ volatile(".globl fault_site\nfault_site: .short 0xfa81\n\t.short 0xf002");
    console_put('.');
    return 0;
}
