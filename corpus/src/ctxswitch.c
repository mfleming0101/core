#include "port.h"
#ifndef ROUNDS
#define ROUNDS 1
#endif

#define STACK_WORDS 256
static unsigned stack_a[STACK_WORDS] __attribute__((aligned(1024)));
static unsigned stack_b[STACK_WORDS] __attribute__((aligned(1024)));
static unsigned *saved[2];
static volatile unsigned counters[2];
static unsigned current;
static unsigned switches;
static unsigned sequence;

static void finish(void) {
    console_hex(counters[0]);
    console_hex(counters[1]);
    console_hex(sequence);
    console_hex(switches);
    bench_exit(console_crc());
}

#if defined(__arm__)
#define RASR_ENABLE 1u
#define RASR_SIZE (9u << 1)
#define RASR_FULL (3u << 24)
#define RASR_NONE (0u << 24)

static void guard(unsigned which) {
    MPU_RNR = 0;
    MPU_RBAR = (unsigned)stack_a;
    MPU_RASR = RASR_ENABLE | RASR_SIZE | (which == 0 ? RASR_FULL : RASR_NONE);
    MPU_RNR = 1;
    MPU_RBAR = (unsigned)stack_b;
    MPU_RASR = RASR_ENABLE | RASR_SIZE | (which == 1 ? RASR_FULL : RASR_NONE);
}

unsigned *ctx_switch(unsigned *sp) {
    saved[current] = sp;
    current ^= 1u;
    sequence = sequence * 31u + current;
    if (++switches >= ROUNDS) finish();
    guard(current);
    return saved[current];
}

__attribute__((naked)) void pendsv_handler(void) {
    __asm__ volatile("mrs r0, psp\n\t"
                     "stmdb r0!, {r4-r11}\n\t"
                     "push {lr}\n\t"
                     "bl ctx_switch\n\t"
                     "pop {lr}\n\t"
                     "ldmia r0!, {r4-r11}\n\t"
                     "msr psp, r0\n\t"
                     "bx lr");
}

void systick_handler(void) { SCB_ICSR = ICSR_PENDSVSET; }

static void task_a(void) { for (;;) counters[0]++; }
static void task_b(void) { for (;;) counters[1]++; }

static unsigned *prepare(unsigned *top, void (*entry)(void)) {
    unsigned *sp = top - 16;
    for (int i = 0; i < 16; i++) sp[i] = 0;
    sp[14] = (unsigned)entry;
    sp[15] = 0x01000000u;
    return sp;
}

int main(void) {
    saved[1] = prepare(stack_b + STACK_WORDS, task_b);
    guard(0);
    MPU_CTRL = 5u;
    SCB_SHPR3 = 0x00f00000u;
    SYST_RVR = 120;
    SYST_CVR = 0;
    SYST_CSR = 3;
    __asm__ volatile("msr psp, %0\n\tmsr control, %1\n\tisb\n\tbx %2" ::
                     "r"(stack_a + STACK_WORDS), "r"(2u), "r"((unsigned)task_a | 1u));
    return 0;
}
#else
static volatile unsigned due;

static void guard(unsigned which) {
    unsigned a = ((unsigned)stack_a >> 2) | 127u;
    unsigned b = ((unsigned)stack_b >> 2) | 127u;
    unsigned cfg = which == 0 ? 0x181bu : 0x1b18u;
    __asm__ volatile("csrw pmpaddr0, %0\n\tcsrw pmpaddr1, %1\n\tcsrw pmpcfg0, %2"
                     :: "r"(a), "r"(b), "r"(cfg));
}

__attribute__((naked)) static void swap(unsigned **save, unsigned **load) {
    __asm__ volatile(
        "addi sp, sp, -56\n\t"
        "sw ra, 0(sp)\n\tsw s0, 4(sp)\n\tsw s1, 8(sp)\n\tsw s2, 12(sp)\n\t"
        "sw s3, 16(sp)\n\tsw s4, 20(sp)\n\tsw s5, 24(sp)\n\tsw s6, 28(sp)\n\t"
        "sw s7, 32(sp)\n\tsw s8, 36(sp)\n\tsw s9, 40(sp)\n\tsw s10, 44(sp)\n\t"
        "sw s11, 48(sp)\n\t"
        "sw sp, 0(a0)\n\tlw sp, 0(a1)\n\t"
        "lw ra, 0(sp)\n\tlw s0, 4(sp)\n\tlw s1, 8(sp)\n\tlw s2, 12(sp)\n\t"
        "lw s3, 16(sp)\n\tlw s4, 20(sp)\n\tlw s5, 24(sp)\n\tlw s6, 28(sp)\n\t"
        "lw s7, 32(sp)\n\tlw s8, 36(sp)\n\tlw s9, 40(sp)\n\tlw s10, 44(sp)\n\t"
        "lw s11, 48(sp)\n\t"
        "addi sp, sp, 56\n\tret");
}

static void yield(void) {
    unsigned old = current;
    due = 0;
    current ^= 1u;
    sequence = sequence * 31u + current;
    if (++switches >= ROUNDS) finish();
    guard(current);
    swap(&saved[old], &saved[current]);
}

void irq_handler(unsigned id) {
    (void)id;
    DEVICE(0, DEV_STATUS) = DEV_RAISED;
    due = 1;
}

static void task_a(void) { for (;;) { counters[0]++; if (due) yield(); } }
static void task_b(void) { for (;;) { counters[1]++; if (due) yield(); } }

static unsigned *prepare(unsigned *top, void (*entry)(void)) {
    unsigned *sp = top - 14;
    for (int i = 0; i < 14; i++) sp[i] = 0;
    sp[0] = (unsigned)entry;
    return sp;
}

int main(void) {
    static unsigned *entry_sp;
    saved[0] = prepare(stack_a + STACK_WORDS, task_a);
    saved[1] = prepare(stack_b + STACK_WORDS, task_b);
    guard(0);
    DEVICE(0, DEV_LINE) = 20;
    DEVICE(0, DEV_RELOAD) = 120;
    DEVICE(0, DEV_CTRL) = DEV_ENABLE | DEV_AUTO;
    line_enable(20, 7, 1);
    irqs_on();
    swap(&entry_sp, &saved[0]);
    return 0;
}
#endif
