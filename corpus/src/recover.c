#include "port.h"
#ifndef ROUNDS
#define ROUNDS 1
#endif

static volatile unsigned faults;
static unsigned * const refused = (unsigned *)0x80000000u;

#if defined(__arm__)
void recover_fault(unsigned *frame) {
    unsigned pc = frame[6];
    unsigned short first = *(const unsigned short *)pc;
    frame[6] = pc + ((first >> 11) >= 0x1du ? 4u : 2u);
    frame[0] = 0xa5a5a5a5u;
    faults++;
}

__attribute__((naked)) void hard_fault_handler(void) {
    __asm__ volatile("mrs r0, msp\n\tb recover_fault");
}

static unsigned refuse(void) {
    register unsigned value __asm__("r0");
    __asm__ volatile("ldr r0, [%1]" : "=r"(value) : "r"(refused) : "memory");
    return value;
}
#else
void exception_handler(void) {
    unsigned pc = csr_read("mepc");
    unsigned code = *(const unsigned short *)pc;
    csr_write("mepc", pc + ((code & 3u) == 3u ? 4u : 2u));
    faults++;
}

static unsigned refuse(void) {
    unsigned value = 0xa5a5a5a5u;
    __asm__ volatile("lw %0, 0(%1)" : "+r"(value) : "r"(refused) : "memory");
    return value;
}
#endif

int main(void) {
    unsigned acc = 0;
    for (unsigned round = 0; round < ROUNDS; round++) acc += refuse() + round;
    console_hex(acc);
    console_hex(faults);
    return 0;
}
