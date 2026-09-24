#ifndef CORPUS_PORT_H
#define CORPUS_PORT_H

#define CONSOLE_SIZE 4096
extern char console[CONSOLE_SIZE];
extern unsigned console_len;
void console_put(char c);
void console_hex(unsigned value);
unsigned console_crc(void);
void bench_exit(unsigned code);

void irq_handler(unsigned line);

#if defined(__arm__)
#define DEVICE_BASE 0x40010000u
void nmi_handler(void);
void hard_fault_handler(void);
void mem_manage_handler(void);
void bus_fault_handler(void);
void usage_fault_handler(void);
void svc_handler(void);
void debug_handler(void);
void pendsv_handler(void);
void systick_handler(void);

#define SYST_CSR (*(volatile unsigned *)0xe000e010u)
#define SYST_RVR (*(volatile unsigned *)0xe000e014u)
#define SYST_CVR (*(volatile unsigned *)0xe000e018u)
#define NVIC_ISER ((volatile unsigned *)0xe000e100u)
#define NVIC_ICPR ((volatile unsigned *)0xe000e280u)
#define NVIC_IPR ((volatile unsigned *)0xe000e400u)
#define SCB_ICSR (*(volatile unsigned *)0xe000ed04u)
#define SCB_VTOR (*(volatile unsigned *)0xe000ed08u)
#define SCB_CCR (*(volatile unsigned *)0xe000ed14u)
#define SCB_SHPR3 (*(volatile unsigned *)0xe000ed20u)
#define SCB_SHCSR (*(volatile unsigned *)0xe000ed24u)
#define SCB_CFSR (*(volatile unsigned *)0xe000ed28u)
#define SCB_MMFAR (*(volatile unsigned *)0xe000ed34u)
#define SCB_STIR (*(volatile unsigned *)0xe000ef00u)
#define MPU_CTRL (*(volatile unsigned *)0xe000ed94u)
#define MPU_RNR (*(volatile unsigned *)0xe000ed98u)
#define MPU_RBAR (*(volatile unsigned *)0xe000ed9cu)
#define MPU_RASR (*(volatile unsigned *)0xe000eda0u)
#define ICSR_PENDSVSET (1u << 28)

static inline void irqs_on(void) { __asm__ volatile("cpsie i" ::: "memory"); }
static inline void irqs_off(void) { __asm__ volatile("cpsid i" ::: "memory"); }

static inline void line_enable(unsigned line, unsigned priority) {
    volatile unsigned *ipr = &NVIC_IPR[line / 4];
    unsigned shift = (line % 4) * 8;
    *ipr = (*ipr & ~(0xffu << shift)) | (priority << shift);
    NVIC_ISER[line / 32] = 1u << (line % 32);
}
#else
#define DEVICE_BASE 0x60010000u
void exception_handler(void);

#define INTC_MAP(source) (*(volatile unsigned *)(0x600c2000u + 4u * (source)))
#define INTC_ENABLE (*(volatile unsigned *)0x600c2104u)
#define INTC_PRI(id) (*(volatile unsigned *)(0x600c2118u + 4u * ((id) - 1)))
#define INTC_THRESHOLD (*(volatile unsigned *)0x600c2194u)

#define csr_read(name) ({ unsigned v; __asm__ volatile("csrr %0, " name : "=r"(v)); v; })
#define csr_write(name, value) __asm__ volatile("csrw " name ", %0" ::"r"(value))

static inline void irqs_on(void) { __asm__ volatile("csrsi mstatus, 8" ::: "memory"); }
static inline void irqs_off(void) { __asm__ volatile("csrci mstatus, 8" ::: "memory"); }

static inline void line_enable(unsigned source, unsigned id, unsigned priority) {
    INTC_MAP(source) = id;
    INTC_PRI(id) = priority;
    INTC_ENABLE |= 1u << id;
}
#endif

#define DEVICE(n, r) (*(volatile unsigned *)(DEVICE_BASE + (n) * 0x100u + (r)))
#define DEV_CTRL 0x00u
#define DEV_RELOAD 0x04u
#define DEV_STATUS 0x0cu
#define DEV_LINE 0x10u
#define DEV_DATA 0x14u
#define DEV_ENABLE 1u
#define DEV_AUTO 2u
#define DEV_RAISED 1u

#endif
