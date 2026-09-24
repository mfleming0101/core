#include "port.h"
#ifndef ROUNDS
#define ROUNDS 1
#endif

static volatile unsigned woke;
static volatile unsigned work;

void irq_handler(unsigned line) {
    (void)line;
    DEVICE(0, DEV_STATUS) = DEV_RAISED;
    woke++;
}

int main(void) {
    DEVICE(0, DEV_RELOAD) = 512;
#if defined(__arm__)
    DEVICE(0, DEV_LINE) = 5;
    line_enable(5, 0);
#else
    DEVICE(0, DEV_LINE) = 20;
    line_enable(20, 5, 1);
#endif
    DEVICE(0, DEV_CTRL) = DEV_ENABLE | DEV_AUTO;
    irqs_on();
    for (unsigned r = 0; r < ROUNDS; r++) {
        __asm__ volatile("wfi" ::: "memory");
        work += r;
    }
    DEVICE(0, DEV_CTRL) = 0;
    irqs_off();
    console_hex(woke);
    console_hex(work);
    return 0;
}
