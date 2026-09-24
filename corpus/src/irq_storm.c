#include "port.h"
#ifndef ROUNDS
#define ROUNDS 1
#endif

static volatile unsigned entries[4];
static volatile unsigned sequence;
static volatile unsigned work;

static void spin(unsigned n) {
    for (unsigned i = 0; i < n; i++) work += i;
}

static void enter(unsigned slot, unsigned n) {
    entries[slot]++;
    sequence = sequence * 31u + slot + 1u;
    spin(n);
}

static void arm(void) {
    for (unsigned i = 1; i < 4; i++) {
        DEVICE(i, DEV_RELOAD) = 4u + 6u * (i - 1u);
        DEVICE(i, DEV_CTRL) = DEV_ENABLE;
    }
}

#if defined(__arm__)
void systick_handler(void) {
    arm();
    enter(0, 12);
}

void irq_handler(unsigned line) {
    unsigned slot = line - 4u;
    DEVICE(slot, DEV_STATUS) = DEV_RAISED;
    enter(slot, 6);
}

int main(void) {
    for (unsigned i = 1; i < 4; i++) {
        DEVICE(i, DEV_LINE) = 4u + i;
        line_enable(4u + i, 0x80u - 0x40u * (i - 1u));
    }
    SCB_SHPR3 = 0xc0000000u;
    SYST_RVR = 2000;
    SYST_CVR = 0;
    SYST_CSR = 3;
    irqs_on();
    for (unsigned r = 0; r < ROUNDS; r++) work += r;
    SYST_CSR = 0;
    irqs_off();
#else
void irq_handler(unsigned id) {
    unsigned slot = id - 4u;
    unsigned epc = csr_read("mepc");
    unsigned status = csr_read("mstatus");
    unsigned threshold = INTC_THRESHOLD;
    DEVICE(slot, DEV_STATUS) = DEV_RAISED;
    INTC_THRESHOLD = slot + 2u;
    irqs_on();
    if (slot == 0) arm();
    enter(slot, slot == 0 ? 12u : 6u);
    irqs_off();
    INTC_THRESHOLD = threshold;
    csr_write("mstatus", status);
    csr_write("mepc", epc);
}

int main(void) {
    for (unsigned i = 0; i < 4; i++) {
        DEVICE(i, DEV_LINE) = 20u + i;
        line_enable(20u + i, 4u + i, 1u + i);
    }
    DEVICE(0, DEV_RELOAD) = 2000;
    DEVICE(0, DEV_CTRL) = DEV_ENABLE | DEV_AUTO;
    irqs_on();
    for (unsigned r = 0; r < ROUNDS; r++) work += r;
    DEVICE(0, DEV_CTRL) = 0;
    irqs_off();
#endif
    for (unsigned i = 0; i < 4; i++) console_hex(entries[i]);
    console_hex(sequence);
    console_hex(work);
    return 0;
}
