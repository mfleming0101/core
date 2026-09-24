#include "port.h"
static unsigned stack[64] __attribute__((aligned(256)));

void mem_manage_handler(void) {
    console_hex(SCB_CFSR);
    console_hex(SCB_MMFAR);
    bench_exit(console_crc());
}

int main(void) {
    MPU_RNR = 0;
    MPU_RBAR = (unsigned)stack;
    MPU_RASR = 1u | (4u << 1);
    MPU_CTRL = 5u;
    SCB_SHCSR |= 1u << 16;
    __asm__ volatile("mov sp, %0\n\t.globl fault_site\nfault_site: push {r4-r11}" :: "r"(stack + 8) : "memory");
    return 0;
}
