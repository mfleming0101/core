pub const Snapshot = extern struct {
    regs: [32]u32 = @splat(0),
    pc: u32 = 0,
    flags: u32 = 0,
    retired: u64 = 0,
    cycles: u64 = 0,
    pending_lo: u64 = 0,
    active_lo: u64 = 0,
    stop: Stop = .running,
    systick_cvr: u32 = 0,
    exception: u16 = 0,
    primask: u8 = 0,
    basepri: u8 = 0,
    faultmask: u8 = 0,
    control: u8 = 0,
};

pub const Stop = enum(u32) {
    running,
    exited,
    undefined_instruction,
    fetch_fault,
    data_fault,
    unaligned,
    breakpoint,
    budget,
};

pub const Trap = struct {
    cause: u32 = 0,
    epc: u32 = 0,
    tval: u32 = 0,
    event: u16 = 0,
};
