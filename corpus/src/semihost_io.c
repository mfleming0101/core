#include "port.h"
#ifndef ROUNDS
#define ROUNDS 1
#endif

static unsigned semihost(unsigned op, const void *arg) {
#if defined(__arm__)
    register unsigned r0 __asm__("r0") = op;
    register unsigned r1 __asm__("r1") = (unsigned)arg;
    __asm__ volatile("bkpt 0xab" : "+r"(r0) : "r"(r1) : "memory");
    return r0;
#else
    register unsigned a0 __asm__("a0") = op;
    register unsigned a1 __asm__("a1") = (unsigned)arg;
    __asm__ volatile(".option push\n\t.option norvc\n\t"
                     "slli x0, x0, 0x1f\n\tebreak\n\tsrai x0, x0, 7\n\t"
                     ".option pop"
                     : "+r"(a0) : "r"(a1) : "memory");
    return a0;
#endif
}

static char line[17];

int main(void) {
    unsigned left = 0;
    for (unsigned round = 0; round < ROUNDS; round++) {
        for (unsigned i = 0; i < 16; i++) line[i] = (char)('a' + ((round + i) & 15));
        line[16] = 0;
        left += semihost(0x04, line);
        unsigned block[3] = {1, (unsigned)line, 16};
        left += semihost(0x05, block);
    }
    console_hex(left);
    return 0;
}
