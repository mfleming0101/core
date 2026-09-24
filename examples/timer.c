#define TIMER_CTRL (*(volatile unsigned *)(TIMER_BASE + 0x0))
#define TIMER_RELOAD (*(volatile unsigned *)(TIMER_BASE + 0x4))
#define TIMER_STATUS (*(volatile unsigned *)(TIMER_BASE + 0x8))

extern const unsigned char _stack[];

static volatile unsigned ticks;

#if defined(__riscv)

#define TIMER_BASE 0x60010000u
#define INTC_MAP(source) (*(volatile unsigned *)(0x600c2000u + 4u * (source)))
#define INTC_ENABLE (*(volatile unsigned *)0x600c2104u)
#define INTC_PRIORITY(id) (*(volatile unsigned *)(0x600c2118u + 4u * ((id) - 1)))

__attribute__((interrupt, used)) void timer_handler(void) {
    TIMER_STATUS = 1;
    ticks++;
}

__asm__(".section .text.entry\n.globl _entry\n_entry: la sp, _stack\n j _start\n"
        ".option push\n.option norvc\n.p2align 8\n.globl vectors\nvectors: j .\n j timer_handler\n.option pop\n");

void _start(void) {
    extern const char vectors[];
    __asm__ volatile("csrw mtvec, %0" : : "r"((unsigned)vectors | 1));
    INTC_MAP(5) = 1;
    INTC_PRIORITY(1) = 1;
    INTC_ENABLE = 1u << 1;
    TIMER_RELOAD = 100;
    TIMER_CTRL = 1;
    __asm__ volatile("csrsi mstatus, 8" ::: "memory");
    while (ticks < 5) __asm__ volatile("wfi");
    TIMER_CTRL = 0;
    register unsigned a0 __asm__("a0") = ticks;
    __asm__ volatile("ebreak" : : "r"(a0));
    for (;;) {}
}

#else

#define TIMER_BASE 0x40010000u
#define NVIC_ISER (*(volatile unsigned *)0xe000e100u)

static void timer_handler(void) {
    TIMER_STATUS = 1;
    ticks++;
}

void _start(void) {
    NVIC_ISER = 1u << 0;
    TIMER_RELOAD = 100;
    TIMER_CTRL = 1;
    __asm__ volatile("cpsie i" ::: "memory");
    while (ticks < 5) __asm__ volatile("wfi");
    TIMER_CTRL = 0;
    register unsigned r0 __asm__("r0") = ticks;
    __asm__ volatile("bkpt 0" : : "r"(r0));
    for (;;) {}
}

__attribute__((section(".vectors"), used)) static const unsigned vectors[17] = {
    (unsigned)_stack, (unsigned)_start, [16] = (unsigned)timer_handler,
};

#endif
