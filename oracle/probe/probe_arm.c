typedef unsigned u32;

#define REG(at) (*(volatile u32 *)(at))

#define ICSR 0xe000ed04u
#define VTOR 0xe000ed08u
#define AIRCR 0xe000ed0cu
#define CCR 0xe000ed14u
#define SHCSR 0xe000ed24u
#define CFSR 0xe000ed28u
#define DEMCR 0xe000edfcu
#define STIR 0xe000ef00u
#define SYST_CSR 0xe000e010u
#define SYST_RVR 0xe000e014u
#define SYST_CVR 0xe000e018u
#define NVIC_ISER 0xe000e100u
#define NVIC_ICER 0xe000e180u
#define NVIC_ISPR 0xe000e200u
#define NVIC_ICPR 0xe000e280u
#define NVIC_IABR 0xe000e300u
#define NVIC_IPR0 0xe000e400u
#define MPU_RNR 0xe000ed98u
#define MPU_RBAR 0xe000ed9cu
#define MPU_RASR 0xe000eda0u
#define DWT_CTRL 0xe0001000u
#define DWT_CYCCNT 0xe0001004u

#define PENDSTSET (1u << 26)
#define PENDSTCLR (1u << 25)
#define PENDSVSET (1u << 28)
#define PENDSVCLR (1u << 27)
#define USGFAULTENA (1u << 18)
#define DIV_0_TRP (1u << 4)
#define TRCENA (1u << 24)
#define CYCCNTENA (1u << 0)

u32 fault_ipsr, fault_cfsr, fault_hfsr, fault_shcsr;
u32 irq_ipsr, irq_iabr, irq_icsr, irq_shcsr;
u32 system_ipsr;

static char line[40];

static void p(const char *name, u32 v) {
    unsigned i = 0;
    while (*name) line[i++] = *name++;
    line[i++] = '=';
    for (unsigned k = 0; k < 8; k++) line[i++] = "0123456789abcdef"[(v >> (28 - 4 * k)) & 15];
    line[i++] = '\n';
    line[i] = 0;
    register u32 r0 __asm__("r0") = 4;
    register u32 r1 __asm__("r1") = (u32)line;
    __asm__ volatile("bkpt 0xab" : "+r"(r0) : "r"(r1) : "memory");
}

static const struct { const char *name; u32 at; } present[] = {
    { "cpuid", 0xe000ed00 },      { "icsr", ICSR },
    { "vtor", VTOR },             { "aircr", AIRCR },
    { "scr", 0xe000ed10 },        { "ccr", CCR },
    { "shpr1", 0xe000ed18 },      { "shpr2", 0xe000ed1c },
    { "shpr3", 0xe000ed20 },      { "shcsr", SHCSR },
    { "cfsr", CFSR },             { "hfsr", 0xe000ed2c },
    { "dfsr", 0xe000ed30 },       { "mmfar", 0xe000ed34 },
    { "bfar", 0xe000ed38 },       { "afsr", 0xe000ed3c },
    { "cpacr", 0xe000ed88 },      { "demcr", DEMCR },
    { "syst_csr", SYST_CSR },     { "syst_rvr", SYST_RVR },
    { "syst_cvr", SYST_CVR },     { "syst_calib", 0xe000e01c },
    { "nvic_iser", NVIC_ISER },   { "nvic_icer", NVIC_ICER },
    { "nvic_ispr", NVIC_ISPR },   { "nvic_icpr", NVIC_ICPR },
    { "nvic_iabr", NVIC_IABR },   { "nvic_ipr0", NVIC_IPR0 },
    { "nvic_ipr1", 0xe000e404 },  { "nvic_ipr2", 0xe000e408 },
    { "nvic_ipr3", 0xe000e40c },  { "nvic_ipr4", 0xe000e410 },
    { "nvic_ipr5", 0xe000e414 },  { "nvic_ipr6", 0xe000e418 },
    { "nvic_ipr7", 0xe000e41c },  { "mpu_type", 0xe000ed90 },
    { "mpu_ctrl", 0xe000ed94 },   { "mpu_rnr", MPU_RNR },
    { "mpu_rbar", MPU_RBAR },     { "mpu_rasr", MPU_RASR },
    { "dwt_ctrl", DWT_CTRL },     { "dwt_cyccnt", DWT_CYCCNT },
};

static const struct { const char *name; u32 at; u32 put; } masked[] = {
    { "cpuid.w", 0xe000ed00, 0xffffffff },     { "vtor.w", VTOR, 0xffffffff },
    { "aircr.w", AIRCR, 0xffffffff },          { "scr.w", 0xe000ed10, 0xffffffff },
    { "ccr.w", CCR, 0xffffffff },              { "shpr1.w", 0xe000ed18, 0xffffffff },
    { "shpr2.w", 0xe000ed1c, 0xffffffff },     { "shpr3.w", 0xe000ed20, 0xffffffff },
    { "shcsr.w", SHCSR, 0xffffffff },          { "cfsr.w", CFSR, 0xffffffff },
    { "hfsr.w", 0xe000ed2c, 0xffffffff },      { "dfsr.w", 0xe000ed30, 0xffffffff },
    { "mmfar.w", 0xe000ed34, 0xffffffff },     { "bfar.w", 0xe000ed38, 0xffffffff },
    { "afsr.w", 0xe000ed3c, 0xffffffff },      { "cpacr.w", 0xe000ed88, 0xffffffff },
    { "demcr.w", DEMCR, 0xffffffff },          { "syst_csr.w", SYST_CSR, 0xffffffff },
    { "syst_rvr.w", SYST_RVR, 0xffffffff },    { "syst_cvr.w", SYST_CVR, 0xffffffff },
    { "syst_calib.w", 0xe000e01c, 0xffffffff }, { "nvic_ipr0.w", NVIC_IPR0, 0xffffffff },
    { "nvic_ipr1.w", 0xe000e404, 0xffffffff }, { "nvic_ipr2.w", 0xe000e408, 0xffffffff },
    { "nvic_ipr3.w", 0xe000e40c, 0xffffffff }, { "nvic_ipr4.w", 0xe000e410, 0xffffffff },
    { "nvic_ipr5.w", 0xe000e414, 0xffffffff }, { "nvic_ipr6.w", 0xe000e418, 0xffffffff },
    { "nvic_ipr7.w", 0xe000e41c, 0xffffffff }, { "mpu_type.w", 0xe000ed90, 0xffffffff },
    { "mpu_ctrl.w", 0xe000ed94, 0xffffffff },  { "mpu_rnr.w", MPU_RNR, 0xffffffff },
    { "mpu_rasr.w", MPU_RASR, 0xffffffff },    { "mpu_rbar.w", MPU_RBAR, 0xffffffe0 },
    { "dwt_ctrl.w", DWT_CTRL, 0xffffffff },
};

static void pend(const char *name, u32 bit) {
    REG(ICSR) = bit;
    p(name, REG(ICSR));
}

static void spin(void) {
    for (u32 i = 0; i < 200; i++) __asm__ volatile("nop");
}

int main(void) {
    for (unsigned i = 0; i < sizeof present / sizeof present[0]; i++) p(present[i].name, REG(present[i].at));

    __asm__ volatile("cpsid i" ::: "memory");
    for (unsigned i = 0; i < sizeof masked / sizeof masked[0]; i++) {
        u32 saved = REG(masked[i].at);
        REG(masked[i].at) = masked[i].put;
        p(masked[i].name, REG(masked[i].at));
        REG(masked[i].at) = saved;
    }

    pend("icsr.pendst", PENDSTSET);
    pend("icsr.pendst.clr", PENDSTCLR);
    pend("icsr.pendsv", PENDSVSET);
    pend("icsr.pendsv.clr", PENDSVCLR);

    REG(NVIC_ISER) = 0xffffffff;
    p("nvic_iser.set", REG(NVIC_ISER));
    REG(NVIC_ISPR) = 0xffffffff;
    p("nvic_ispr.set", REG(NVIC_ISPR));
    p("nvic_iabr.pending", REG(NVIC_IABR));
    p("icsr.pending", REG(ICSR));
    REG(NVIC_ICPR) = 0xffffffff;
    p("nvic_ispr.clr", REG(NVIC_ISPR));
    REG(NVIC_ICER) = 0xffffffff;
    p("nvic_iser.clr", REG(NVIC_ISER));

    REG(STIR) = 3;
    p("stir.pends", REG(NVIC_ISPR));
    REG(NVIC_ICPR) = 0xffffffff;

    REG(MPU_RBAR) = 0x15;
    p("mpu_rbar.valid", REG(MPU_RNR));
    p("mpu_rbar.region", REG(MPU_RBAR));
    REG(MPU_RNR) = 0;
    REG(MPU_RBAR) = 0;

    REG(AIRCR) = 0x05fa0700;
    p("aircr.keyed", REG(AIRCR));

    REG(NVIC_ISER) = 1;
    REG(NVIC_ISPR) = 1;
    p("irq.masked", REG(NVIC_ISPR));
    __asm__ volatile("cpsie i\n\tisb" ::: "memory");
    p("irq.ipsr", irq_ipsr);
    p("irq.iabr", irq_iabr);
    p("irq.icsr", irq_icsr);
    p("irq.shcsr", irq_shcsr);
    p("irq.iabr.after", REG(NVIC_IABR));
    p("irq.ispr.after", REG(NVIC_ISPR));
    REG(NVIC_ICER) = 1;

    REG(SHCSR) = USGFAULTENA;
    REG(CCR) = REG(CCR) | DIV_0_TRP;
    __asm__ volatile("movs r1, #1\n\tmovs r2, #0\n\tudiv r0, r1, r2" ::: "r0", "r1", "r2", "memory");
    p("fault.ipsr", fault_ipsr);
    p("fault.cfsr", fault_cfsr);
    p("fault.hfsr", fault_hfsr);
    p("fault.shcsr", fault_shcsr);
    p("fault.cfsr.after", REG(CFSR));
    REG(CFSR) = 0xffffffff;
    p("fault.cfsr.cleared", REG(CFSR));
    REG(CCR) = REG(CCR) & ~DIV_0_TRP;
    REG(SHCSR) = 0;

    __asm__ volatile("svc #0" ::: "memory");
    p("svc.ipsr", system_ipsr);

    REG(DEMCR) = TRCENA;
    REG(DWT_CTRL) = REG(DWT_CTRL) | CYCCNTENA;
    u32 first = REG(DWT_CYCCNT);
    spin();
    p("dwt.cyccnt.rises", REG(DWT_CYCCNT) != first);
    REG(DWT_CTRL) = REG(DWT_CTRL) & ~CYCCNTENA;
    REG(DWT_CYCCNT) = 0;
    p("dwt.cyccnt.zeroed", REG(DWT_CYCCNT));
    REG(DEMCR) = 0;
    return 0;
}
