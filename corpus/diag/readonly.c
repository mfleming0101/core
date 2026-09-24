#include "port.h"
static unsigned * const target = (unsigned *)0x100;

int main(void) {
#if defined(__arm__)
    __asm__ volatile(".globl fault_site\nfault_site: str %0, [%1]" :: "r"(1u), "r"(target) : "memory");
#else
    __asm__ volatile(".globl fault_site\nfault_site: sw %0, 0(%1)" :: "r"(1u), "r"(target) : "memory");
#endif
    console_put('.');
    return 0;
}
