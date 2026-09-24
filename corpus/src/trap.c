#include "port.h"
#ifndef ROUNDS
#define ROUNDS 1
#endif

static volatile unsigned counts[3];
static unsigned sequence;
static unsigned finished;
static unsigned buffer[2];

void exception_handler(void) {
    unsigned cause = csr_read("mcause");
    unsigned pc = csr_read("mepc");
    if (cause == 8u && finished) {
        console_hex(counts[0]);
        console_hex(counts[1]);
        console_hex(counts[2]);
        console_hex(sequence);
        bench_exit(console_crc());
    }
    counts[cause == 8u ? 0u : (cause == 2u ? 1u : 2u)]++;
    sequence = sequence * 31u + cause;
    csr_write("mepc", pc + ((*(const unsigned short *)pc & 3u) == 3u ? 4u : 2u));
}

static void user_task(void) {
    for (unsigned r = 0; r < ROUNDS; r++) {
        unsigned value;
        __asm__ volatile("ecall");
        __asm__ volatile(".option push\n\t.option norvc\n\t.word 0xffffffff\n\t.option pop");
        __asm__ volatile("lw %0, 1(%1)" : "=r"(value) : "r"(buffer) : "memory");
        (void)value;
    }
    finished = 1;
    __asm__ volatile("ecall");
}

int main(void) {
    unsigned flash = 0u | ((0x100000u / 8u) - 1u);
    unsigned ram = (0x200000u >> 2) | ((0x100000u / 8u) - 1u);
    __asm__ volatile("csrw pmpaddr0, %0\n\tcsrw pmpaddr1, %1\n\tcsrw pmpcfg0, %2"
                     :: "r"(flash), "r"(ram), "r"(0x1b1fu));
    csr_write("mstatus", csr_read("mstatus") & ~0x1800u);
    csr_write("mepc", (unsigned)user_task);
    __asm__ volatile("mret");
    return 0;
}
