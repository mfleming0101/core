#include "port.h"
static volatile unsigned fired;
static volatile unsigned work;

void irq_handler(unsigned id) {
    (void)id;
    fired++;
}

int main(void) {
    DEVICE(0, DEV_LINE) = 20;
    DEVICE(0, DEV_RELOAD) = 32;
    INTC_PRI(7) = 1;
    INTC_ENABLE = 1u << 7;
    irqs_on();
    DEVICE(0, DEV_CTRL) = DEV_ENABLE | DEV_AUTO;
    for (unsigned i = 0; i < 1000; i++) work += i;
    DEVICE(0, DEV_CTRL) = 0;
    irqs_off();
    console_hex(fired);
    console_hex(DEVICE(0, DEV_DATA));
    return 0;
}
