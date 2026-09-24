static unsigned semihost(unsigned op, const void *arg) {
    register unsigned r0 __asm__("r0") = op;
    register unsigned r1 __asm__("r1") = (unsigned)arg;
    __asm__ volatile("bkpt 0xab" : "+r"(r0) : "r"(r1) : "memory");
    return r0;
}

extern const unsigned char _stack[];

void _start(void) {
    semihost(0x04, "hello from the core\n");
    semihost(0x18, (void *)0x20026);
    for (;;) {}
}

__attribute__((section(".vectors"), used)) static const unsigned vectors[2] = { (unsigned)_stack, (unsigned)_start };
