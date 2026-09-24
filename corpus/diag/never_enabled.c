#include "port.h"
static volatile unsigned fired;
static volatile unsigned work;

void irq_handler(unsigned line) {
    (void)line;
    fired++;
}

int main(void) {
    SCB_STIR = 7;
    for (unsigned i = 0; i < 1000; i++) work += i;
    console_hex(fired);
    console_hex(NVIC_ICPR[0]);
    return 0;
}
