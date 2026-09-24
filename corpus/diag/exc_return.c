#include "port.h"

__attribute__((naked)) void systick_handler(void) {
    __asm__ volatile(".globl fault_site\nfault_site: mvn r0, #15\n\tbx r0");
}

int main(void) {
    SYST_RVR = 16;
    SYST_CVR = 0;
    SYST_CSR = 3;
    for (;;) {
    }
}
