#include "port.h"
static unsigned char buffer[8];
static volatile unsigned taken;

void record_fault(unsigned *frame) {
    taken++;
    frame[6] += 4u;
}

__attribute__((naked)) void usage_fault_handler(void) {
    __asm__ volatile("mrs r0, msp\n\tb record_fault");
}

int main(void) {
    SCB_CCR |= 8u;
    SCB_SHCSR |= 1u << 18;
    unsigned *at = (unsigned *)(buffer + 1);
    __asm__ volatile(".globl fault_site\nfault_site: str.w %0, [%1]" :: "r"(0x12345678u), "r"(at) : "memory");
    console_hex(taken);
    console_hex(SCB_CFSR);
    return 0;
}
