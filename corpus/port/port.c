#include "port.h"

char console[CONSOLE_SIZE];
unsigned console_len = 0;

void console_put(char c) {
    if (console_len < CONSOLE_SIZE) console[console_len++] = c;
}

void console_hex(unsigned value) {
    static const char digits[] = "0123456789abcdef";
    for (int i = 7; i >= 0; i--) console_put(digits[(value >> (i * 4)) & 15u]);
}

unsigned console_crc(void) {
    unsigned c = 0xffffffffu;
    for (unsigned i = 0; i < console_len; i++) {
        c ^= (unsigned char)console[i];
        for (int b = 0; b < 8; b++) c = (c >> 1) ^ (0xedb88320u & -(c & 1u));
    }
    return ~c;
}

static void unhandled(char tag) {
    console_put(tag);
    bench_exit(console_crc());
}

__attribute__((weak)) void irq_handler(unsigned line) {
    (void)line;
    unhandled('I');
}

#if defined(__arm__)
__attribute__((weak)) void nmi_handler(void) { unhandled('N'); }
__attribute__((weak)) void hard_fault_handler(void) { unhandled('H'); }
__attribute__((weak)) void mem_manage_handler(void) { unhandled('M'); }
__attribute__((weak)) void bus_fault_handler(void) { unhandled('B'); }
__attribute__((weak)) void usage_fault_handler(void) { unhandled('U'); }
__attribute__((weak)) void svc_handler(void) { unhandled('S'); }
__attribute__((weak)) void debug_handler(void) { unhandled('D'); }
__attribute__((weak)) void pendsv_handler(void) { unhandled('P'); }
__attribute__((weak)) void systick_handler(void) { unhandled('T'); }

void irq_entry(void) {
    unsigned number;
    __asm__ volatile("mrs %0, ipsr" : "=r"(number));
    irq_handler(number - 16u);
}
#else
__attribute__((weak)) void exception_handler(void) { unhandled('X'); }

__attribute__((interrupt("machine"))) void exception_entry(void) { exception_handler(); }

__attribute__((interrupt("machine"))) void irq_entry(void) {
    irq_handler(csr_read("mcause") & 31u);
}
#endif
