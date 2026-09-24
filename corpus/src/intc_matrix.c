#include "port.h"
#ifndef ROUNDS
#define ROUNDS 1
#endif

static volatile unsigned counts[2];
static volatile unsigned sequence;

void irq_handler(unsigned id) {
    DEVICE(0, DEV_STATUS) = DEV_RAISED;
    counts[id == 7u ? 0u : 1u]++;
    sequence = sequence * 31u + id;
}

int main(void) {
    DEVICE(0, DEV_LINE) = 20;
    DEVICE(0, DEV_RELOAD) = 40;
    INTC_PRI(7) = 1;
    INTC_PRI(12) = 1;
    irqs_on();
    for (unsigned r = 0; r < ROUNDS; r++) {
        unsigned slot = r & 1u;
        unsigned id = slot == 0u ? 7u : 12u;
        INTC_MAP(20) = id;
        INTC_ENABLE = 1u << id;
        unsigned seen = counts[slot];
        DEVICE(0, DEV_CTRL) = DEV_ENABLE;
        while (counts[slot] == seen) {
        }
        INTC_ENABLE = 0;
    }
    irqs_off();
    console_hex(counts[0]);
    console_hex(counts[1]);
    console_hex(sequence);
    return 0;
}
