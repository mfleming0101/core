extern const unsigned char _stack[];

void _start(void) {
    volatile unsigned *nothing = (volatile unsigned *)0x60000000;
    unsigned value = *nothing;
    __asm__ volatile("bkpt 0" : : "r"(value));
    for (;;) {}
}

__attribute__((section(".vectors"), used)) static const unsigned vectors[2] = { (unsigned)_stack, (unsigned)_start };
