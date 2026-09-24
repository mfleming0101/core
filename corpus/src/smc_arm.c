#include "port.h"
#ifndef ROUNDS
#define ROUNDS 3000
#endif
static unsigned short body[2];
int main(void) {
    unsigned acc = 0;
    for (unsigned round = 0; round < ROUNDS; round++) {
        unsigned char imm = (unsigned char)(round & 0xff);
        body[0] = (unsigned short)(0x2000u | imm);
        body[1] = 0x4770u;
        unsigned (*run)(void) = (unsigned (*)(void))((unsigned)(void *)body | 1u);
        acc += run();
    }
    console_hex(acc);
    return 0;
}
