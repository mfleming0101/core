typedef unsigned u32;

#define SYS_WRITE0 0x04

static void write0(const char *s) {
    register u32 a0 __asm__("a0") = SYS_WRITE0;
    register u32 a1 __asm__("a1") = (u32)s;
    __asm__ volatile(".option push\n\t.option norvc\n\t"
                     "slli zero, zero, 0x1f\n\tebreak\n\tsrai zero, zero, 7\n\t"
                     ".option pop"
                     : "+r"(a0) : "r"(a1) : "memory");
}

static char line[32];

static void p(const char *name, u32 v) {
    unsigned i = 0;
    while (*name) line[i++] = *name++;
    line[i++] = '=';
    for (unsigned k = 0; k < 8; k++) line[i++] = "0123456789abcdef"[(v >> (28 - 4 * k)) & 15];
    line[i++] = '\n';
    line[i] = 0;
    write0(line);
}

static u32 cell[4];

static u32 record[8];
extern char trap_vector[];

#define SENTINEL 0xdeadbeefu

static void clear(void) {
    for (unsigned i = 0; i < 8; i++) record[i] = 0;
}

static void install(void) {
    __asm__ volatile("csrw mscratch, %0\n\tcsrw mtvec, %1"
                     : : "r"((u32)(unsigned long)record), "r"(((u32)(unsigned long)trap_vector) | 1u) : "memory");
}

#define CSRR(name, csr)                                                 \
    do {                                                                \
        u32 r = SENTINEL;                                               \
        clear();                                                        \
        __asm__ volatile(".option push\n\t.option norvc\n\tcsrr %0, " csr "\n\t.option pop" : "+r"(r) : : "memory"); \
        p(name ".value", r);                                            \
        p(name ".cause", record[0]);                                    \
    } while (0)

#define CSRR_CAUSE(name, csr)                                           \
    do {                                                                \
        u32 r = SENTINEL;                                               \
        clear();                                                        \
        __asm__ volatile(".option push\n\t.option norvc\n\tcsrr %0, " csr "\n\t.option pop" : "+r"(r) : : "memory"); \
        p(name ".cause", record[0]);                                    \
    } while (0)

#define CSRWR(name, csr, value)                                         \
    do {                                                                \
        u32 r = SENTINEL;                                               \
        clear();                                                        \
        __asm__ volatile(".option push\n\t.option norvc\n\tcsrw " csr ", %1\n\tcsrr %0, " csr "\n\t.option pop" \
                         : "+r"(r) : "r"((u32)(value)) : "memory");     \
        p(name, r);                                                     \
    } while (0)

static void machine(void) {
    u32 r;

    __asm__ volatile("csrw mscratch, %1\n\tcsrr %0, mscratch" : "=r"(r) : "r"(0x12345678u));
    p("mscratch", r);

    install();

    CSRR("misa", "misa");
    CSRR("mvendorid", "mvendorid");
    CSRR("marchid", "marchid");
    CSRR("mimpid", "mimpid");
    CSRR("mhartid", "mhartid");

    CSRWR("misa.written", "misa", 0xffffffffu);

    CSRWR("mstatus.fields", "mstatus", (1u << 3) | (1u << 7) | (1u << 21));
    CSRWR("mstatus.mpp1", "mstatus", 1u << 11);
    CSRWR("mstatus.all", "mstatus", 0xffffffffu);
    __asm__ volatile("csrw mstatus, zero");

    CSRR("mie", "mie");
    CSRR("mip", "mip");

    clear();
    __asm__ volatile("csrw mtvec, %1\n\tcsrr %0, mtvec" : "=r"(r) : "r"((u32)(unsigned long)trap_vector));
    p("mtvec.direct", r - (u32)(unsigned long)trap_vector);
    __asm__ volatile("csrw mtvec, %1\n\tcsrr %0, mtvec" : "=r"(r) : "r"(((u32)(unsigned long)trap_vector + 4) | 1u));
    p("mtvec.unaligned", r - (u32)(unsigned long)trap_vector);
    install();

    CSRWR("mepc.low", "mepc", 0xcafeba5fu);
    CSRWR("mtval.written", "mtval", 0xcafeba5fu);
    CSRWR("mcause.written", "mcause", 0xffffffffu);
    __asm__ volatile("csrw mcause, zero\n\tcsrw mtval, zero");

    u32 first = SENTINEL, second = SENTINEL;
    clear();
    __asm__ volatile(".option push\n\t.option norvc\n\tcsrr %0, mcycle\n\tcsrr %1, mcycle\n\t.option pop"
                     : "+r"(first), "+r"(second) : : "memory");
    p("mcycle.rises", second > first);
    p("mcycle.cause", record[0]);
    first = SENTINEL;
    second = SENTINEL;
    clear();
    __asm__ volatile(".option push\n\t.option norvc\n\tcsrr %0, minstret\n\tcsrr %1, minstret\n\t.option pop"
                     : "+r"(first), "+r"(second) : : "memory");
    p("minstret.rises", second > first);
    p("minstret.cause", record[0]);
    CSRR_CAUSE("cycle", "cycle");
    CSRR_CAUSE("time", "time");
    CSRR_CAUSE("instret", "instret");
}

static void nesting(void) {
    u32 r;
    install();
    __asm__ volatile(".option push\n\t.option norvc\n\tcsrsi mstatus, 8\n\tecall\n\tcsrr %0, mstatus\n\t.option pop"
                     : "=r"(r) : : "memory");
    p("mstatus.trap.set", r & 0x1888u);
    __asm__ volatile(".option push\n\t.option norvc\n\tcsrci mstatus, 8\n\tecall\n\tcsrr %0, mstatus\n\t.option pop"
                     : "=r"(r) : : "memory");
    p("mstatus.trap.clear", r & 0x1888u);
    __asm__ volatile("csrw mstatus, zero");
}

static void traps(void) {
    u32 here, r;

    clear();
    __asm__ volatile(".option push\n\t.option norvc\n\tauipc %0, 0\n\t.insn r 0x33, 0, 0x7f, a0, a0, a0\n\t.option pop"
                     : "=r"(here) : : "a0", "memory");
    p("trap.illegal.cause", record[0]);
    p("trap.illegal.tval", record[1]);
    p("trap.illegal.epc", record[2] - here - 4);

    clear();
    __asm__ volatile(".option push\n\t.option norvc\n\tauipc %0, 0\n\tecall\n\t.option pop" : "=r"(here) : : "memory");
    p("trap.ecall.cause", record[0]);
    p("trap.ecall.tval", record[1]);
    p("trap.ecall.epc", record[2] - here - 4);

    cell[0] = 0x44332211;
    cell[1] = 0x88776655;
    r = SENTINEL;
    clear();
    __asm__ volatile(".option push\n\t.option norvc\n\tlw %0, 1(%1)\n\t.option pop" : "+r"(r) : "r"(&cell[0]) : "memory");
    p("trap.mload.cause", record[0]);
    p("trap.mload.tval", record[1] ? record[1] - (u32)(unsigned long)&cell[0] : 0);
    p("trap.mload.value", r);

    clear();
    __asm__ volatile(".option push\n\t.option norvc\n\tsw %0, 2(%1)\n\t.option pop" : : "r"(0x99999999u), "r"(&cell[2]) : "memory");
    p("trap.mstore.cause", record[0]);
    p("trap.mstore.tval", record[1] ? record[1] - (u32)(unsigned long)&cell[0] : 0);

    r = SENTINEL;
    clear();
    __asm__ volatile(".option push\n\t.option norvc\n\tlw %0, 0(%1)\n\t.option pop" : "+r"(r) : "r"(0x10000000u) : "memory");
    p("trap.unmapped.cause", record[0]);
    p("trap.unmapped.tval", record[1]);
    p("trap.unmapped.value", r);

    clear();
    __asm__ volatile(".option push\n\t.option norvc\n\t"
                     "la t0, 1f\n\t"
                     "csrw mepc, t0\n\t"
                     "li t0, 0x1800\n\t"
                     "csrc mstatus, t0\n\t"
                     "mret\n\t"
                     "1: ecall\n\t"
                     "nop\n\t"
                     ".option pop"
                     : : : "t0", "memory");
    p("trap.uecall.cause", record[0]);
    p("trap.uecall.tval", record[1]);

    p("trap.uecall.count", record[3]);

    clear();
    __asm__ volatile(".option push\n\t.option norvc\n\t"
                     "li t0, 0x200000\n\tcsrs mstatus, t0\n\t"
                     "la t0, 1f\n\tcsrw mepc, t0\n\t"
                     "li t0, 0x1800\n\tcsrc mstatus, t0\n\tmret\n\t"
                     "1: wfi\n\tecall\n\t"
                     "li t0, 0x200000\n\tcsrc mstatus, t0\n\t"
                     ".option pop"
                     : : : "t0", "memory");
    p("trap.utw.cause", record[6]);
    p("trap.utw.tval", record[7]);
}

#define GUARD 0x3fc90000u

#define PMPADDR(n, value) __asm__ volatile("csrw pmpaddr" #n ", %0" : : "r"((u32)(value)) : "memory")
#define PMPCFG(n, value) __asm__ volatile("csrw pmpcfg" #n ", %0" : : "r"((u32)(value)) : "memory")

static u32 napot(u32 base, u32 size) {
    return (base >> 2) | ((size >> 3) - 1);
}

#define IN_USER(insn, ...)                                                       \
    __asm__ volatile(".option push\n\t.option norvc\n\t"                         \
                     "la t0, 1f\n\tcsrw mepc, t0\n\t"                            \
                     "li t0, 0x1800\n\tcsrc mstatus, t0\n\tmret\n\t"             \
                     "1: " insn "\n\tecall\n\t"                                  \
                     ".option pop"                                               \
                     : __VA_ARGS__)

static void protection(void) {
    u32 r;
    const u32 ro = GUARD;
    const u32 locked = GUARD + 0x10;

    PMPCFG(0, 0);
    __asm__ volatile("csrw pmpaddr0, %1\n\tcsrr %0, pmpaddr0" : "=r"(r) : "r"(0xffffffffu));
    p("pmp.grain", r);

    __asm__ volatile("csrw pmpcfg0, %1\n\tcsrr %0, pmpcfg0" : "=r"(r) : "r"(0x00000062u));
    p("pmp.cfg.warl", r);

    __asm__ volatile("csrw pmpcfg0, %1\n\tcsrr %0, pmpcfg0\n\tcsrw pmpcfg0, zero" : "=r"(r) : "r"(0x0000001au));
    p("pmp.cfg.wx", r);

    *(volatile u32 *)ro = 0x11111111u;
    *(volatile u32 *)locked = 0xa5a5a5a5u;
    PMPADDR(0, napot(0x42000000u, 4u << 20));
    PMPADDR(1, 0x3FC80000u >> 2);
    PMPADDR(2, ro >> 2);
    PMPADDR(3, (ro + 4) >> 2);
    PMPADDR(4, locked >> 2);
    PMPADDR(5, (locked + 4) >> 2);
    PMPADDR(6, 0x3FCE0000u >> 2);
    PMPCFG(1, 0x000b000bu);
    PMPCFG(0, 0x090b001du);

    clear();
    IN_USER("nop", : : "t0", "memory");
    p("pmp.uecall.cause", record[6]);
    p("pmp.uecall.count", record[3]);

    r = SENTINEL;
    clear();
    IN_USER("lw %0, 0(%1)", "+r"(r) : "r"(ro) : "t0", "memory");
    p("pmp.uread.cause", record[6]);
    p("pmp.uread.value", r);

    clear();
    IN_USER("sw %0, 0(%1)", : "r"(0x22222222u), "r"(ro) : "t0", "memory");
    p("pmp.ustore.cause", record[6]);
    p("pmp.ustore.tval", record[7] - ro);
    p("pmp.ustore.value", *(volatile u32 *)ro);

    r = SENTINEL;
    clear();
    IN_USER("lw %0, 0(%1)", "+r"(r) : "r"(locked) : "t0", "memory");
    p("pmp.uload.cause", record[6]);
    p("pmp.uload.tval", record[7] - locked);
    p("pmp.uload.value", r);

    clear();
    __asm__ volatile(".option push\n\t.option norvc\n\t"
                     "mv t1, %[bad]\n\t"
                     "la t0, 2f\n\tsw t0, 20(%[rec])\n\t"
                     "la t0, 1f\n\tcsrw mepc, t0\n\t"
                     "li t0, 0x1800\n\tcsrc mstatus, t0\n\tmret\n\t"
                     "1: jalr zero, 0(t1)\n\t"
                     "2: nop\n\t"
                     ".option pop"
                     : : [bad] "r"(locked), [rec] "r"(record) : "t0", "t1", "memory");
    p("pmp.ufetch.cause", record[6]);
    p("pmp.ufetch.tval", record[7] - locked);

    PMPADDR(7, locked >> 2);
    PMPCFG(1, 0x910b000bu);
    clear();
    __asm__ volatile(".option push\n\t.option norvc\n\tsw %0, 0(%1)\n\t.option pop"
                     : : "r"(0x33333333u), "r"(locked) : "memory");
    p("pmp.mstore.cause", record[0]);
    p("pmp.mstore.tval", record[1] - locked);
    clear();
    __asm__ volatile(".option push\n\t.option norvc\n\tlw %0, 0(%1)\n\t.option pop"
                     : "=r"(r) : "r"(locked) : "memory");
    p("pmp.mload.cause", record[0]);
    p("pmp.mload.value", r);

    PMPCFG(1, 0x000b000bu);
    PMPADDR(7, 0);
    __asm__ volatile("csrr %0, pmpcfg1" : "=r"(r));
    p("pmp.lock.cfg", r);
    __asm__ volatile("csrr %0, pmpaddr7" : "=r"(r));
    p("pmp.lock.addr", r - (locked >> 2));

    PMPADDR(8, 0x50000000u >> 2);
    PMPADDR(9, 0x50001000u >> 2);
    PMPCFG(2, 0x00008f00u);
    PMPADDR(8, 0);
    __asm__ volatile("csrr %0, pmpaddr8" : "=r"(r));
    p("pmp.tor.frozen", r - (0x50000000u >> 2));

    PMPADDR(10, ro >> 2);
    PMPCFG(2, 0x00138f00u);
    clear();
    IN_USER("sw %0, 0(%1)", : "r"(0x44444444u), "r"(ro) : "t0", "memory");
    p("pmp.overlap.cause", record[6]);
    p("pmp.overlap.value", *(volatile u32 *)ro);
}

#define INTC 0x600C2000u
#define INTC_MAP(n) (*(volatile u32 *)(INTC + 4u * (n)))
#define INTC_ENABLE (*(volatile u32 *)(INTC + 0x104u))
#define INTC_TYPE (*(volatile u32 *)(INTC + 0x108u))
#define INTC_CLEAR (*(volatile u32 *)(INTC + 0x10Cu))
#define INTC_EIP (*(volatile u32 *)(INTC + 0x110u))
#define INTC_PRI(n) (*(volatile u32 *)(INTC + 0x114u + 4u * (n)))
#define INTC_THRESH (*(volatile u32 *)(INTC + 0x194u))

static void interrupts(void) {

    INTC_MAP(15) = 3;
    p("int.map15", INTC_MAP(15));
    INTC_MAP(15) = 0;
    INTC_MAP(61) = 9;
    p("int.map61", INTC_MAP(61));
    INTC_MAP(61) = 0;
    INTC_MAP(50) = 0xffffffffu;
    p("int.map.mask", INTC_MAP(50));
    INTC_MAP(50) = 0;

    INTC_MAP(62) = 0x1f;
    p("int.map62", INTC_MAP(62));
    INTC_MAP(62) = 0;

    INTC_ENABLE = 0xffffffffu;
    p("int.enable.mask", INTC_ENABLE);
    INTC_ENABLE = 0;
    INTC_TYPE = 0xffffffffu;
    p("int.type.mask", INTC_TYPE);
    INTC_TYPE = 0;
    INTC_CLEAR = 0xffffffffu;
    p("int.clear.mask", INTC_CLEAR);
    INTC_CLEAR = 0;
    INTC_PRI(1) = 0xffffffffu;
    p("int.pri1.mask", INTC_PRI(1));
    INTC_PRI(1) = 0;
    INTC_PRI(31) = 0xfu;
    p("int.pri31", INTC_PRI(31));
    INTC_PRI(31) = 0;
    INTC_THRESH = 0xffffffffu;
    p("int.thresh.mask", INTC_THRESH);
    INTC_THRESH = 0;

    p("int.eip.idle", INTC_EIP);

    INTC_PRI(0) = 0xfu;
    p("int.pri0", INTC_PRI(0));
    INTC_PRI(0) = 0;
    INTC_EIP = 0xffffffffu;
    p("int.eip.written", INTC_EIP);

    INTC_ENABLE = 0x12345678u;
    p("int.byte.read", *(volatile unsigned char *)(INTC + 0x105u));
    *(volatile unsigned char *)(INTC + 0x104u) = 0xffu;
    p("int.byte.write", INTC_ENABLE);
    INTC_ENABLE = 0;
}

int main(void) {
    machine();
    nesting();
    protection();
    traps();
    interrupts();
    return 0;
}
