#include "port.h"
#ifndef ROUNDS
#define ROUNDS 1
#endif

static volatile unsigned polls;

int main(void) {
    DEVICE(0, DEV_LINE) = 200;
    DEVICE(0, DEV_RELOAD) = 64;
    DEVICE(0, DEV_CTRL) = DEV_ENABLE | DEV_AUTO;
    for (unsigned r = 0; r < ROUNDS; r++) {
        unsigned seen = DEVICE(0, DEV_DATA);
        while (DEVICE(0, DEV_DATA) == seen) polls++;
        DEVICE(0, DEV_STATUS) = DEV_RAISED;
    }
    DEVICE(0, DEV_CTRL) = 0;
    console_hex(polls);
    console_hex(DEVICE(0, DEV_DATA));
    return 0;
}
