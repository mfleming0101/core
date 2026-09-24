static unsigned crc32(const unsigned char *p, unsigned n) {
    unsigned c = 0xffffffff;
    while (n--) {
        c ^= *p++;
        for (int i = 0; i < 8; i++) c = (c >> 1) ^ (0xedb88320 & -(c & 1));
    }
    return ~c;
}

extern const unsigned char _stack[];

#if defined(__riscv)

__asm__(".section .text.entry\n.globl _entry\n_entry: la sp, _stack\n j _start\n");

void _start(void) {
    static const unsigned char check[] = "123456789";
    register unsigned a0 __asm__("a0") = crc32(check, 9);
    __asm__ volatile("ebreak" : : "r"(a0));
    for (;;) {}
}

#else

void _start(void) {
    static const unsigned char check[] = "123456789";
    register unsigned r0 __asm__("r0") = crc32(check, 9);
    __asm__ volatile("bkpt 0" : : "r"(r0));
    for (;;) {}
}

__attribute__((section(".vectors"), used)) static const unsigned vectors[2] = { (unsigned)_stack, (unsigned)_start };

#endif
