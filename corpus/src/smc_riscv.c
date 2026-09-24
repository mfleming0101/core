#include "port.h"
#ifndef ROUNDS
#define ROUNDS 3000
#endif
static unsigned code[2];
int main(void) {
    unsigned acc = 0;
    for (unsigned round = 0; round < ROUNDS; round++) {
        unsigned imm = round & 0x7ff;
        code[0] = (imm << 20) | (10u << 7) | 0x13u;
        code[1] = 0x00008067u;
        __asm__ volatile("fence" ::: "memory");
        unsigned (*run)(void) = (unsigned (*)(void))(void *)code;
        acc += run();
    }
    console_hex(acc);
    return 0;
}
