#include "port.h"
#ifndef ROUNDS
#define ROUNDS 1
#endif

static const unsigned marker = 0x5eed1234u;
static unsigned probe;
static volatile unsigned refusals;
static unsigned cause_seen;
static unsigned value_seen;

void exception_handler(void) {
    unsigned cause = csr_read("mcause");
    unsigned pc = csr_read("mepc");
    if (cause == 8u) {
        console_hex(refusals);
        console_hex(cause_seen);
        console_hex(value_seen);
        bench_exit(console_crc());
    }
    cause_seen = cause;
    value_seen = csr_read("mtval");
    refusals++;
    csr_write("mepc", pc + ((*(const unsigned short *)pc & 3u) == 3u ? 4u : 2u));
}

static void user_task(void) {
    for (unsigned r = 0; r < ROUNDS; r++) {
        unsigned value;
        __asm__ volatile("lw %0, 0(%1)" : "=r"(value) : "r"(probe) : "memory");
        (void)value;
    }
    __asm__ volatile("ecall");
}

int main(void) {
    probe = (unsigned)&marker;
    unsigned flash = 0u | ((0x100000u / 8u) - 1u);
    unsigned ram = (0x200000u >> 2) | ((0x100000u / 8u) - 1u);
    __asm__ volatile("csrw pmpaddr0, %0\n\tcsrw pmpaddr1, %1\n\tcsrw pmpcfg0, %2"
                     :: "r"(flash), "r"(ram), "r"(0x1b1cu));
    csr_write("mstatus", csr_read("mstatus") & ~0x1800u);
    csr_write("mepc", (unsigned)user_task);
    __asm__ volatile("mret");
    return 0;
}
