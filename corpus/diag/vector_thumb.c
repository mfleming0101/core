#include "port.h"
static unsigned table[64] __attribute__((aligned(256)));

int main(void) {
    const unsigned *original = (const unsigned *)SCB_VTOR;
    for (unsigned i = 0; i < 64; i++) table[i] = original[i];
    table[15] &= ~1u;
    SCB_VTOR = (unsigned)table;
    SYST_RVR = 16;
    SYST_CVR = 0;
    SYST_CSR = 3;
    __asm__ volatile(".globl fault_site\nfault_site: b fault_site");
    return 0;
}
