//! What the library knows about each Cortex-M core, one Spec per core. A Spec is comptime
//! data: the architecture, the cycle counts the Technical Reference Manual publishes per
//! instruction class and for a taken branch, the exception entry and exit cycles, the
//! priority bits, CPUID and MVFR, the reset CCR, the MPU region count, and which of the
//! Security, floating-point, MVE and PACBTI extensions are fitted. A core with no published
//! table has null cycles and charges one cycle an instruction. Cores are written as
//! differences from one another.
const std = @import("std");
const Class = @import("isa").arm.instruction.Class;
const Architecture = @import("isa").arm.Architecture;

/// The Cortex-M cores this half models.
pub const Core = enum { m0, m0plus, m1, m23, m3, m4, m7, m33, m55, m85 };

/// One core as comptime data: its architecture, its cycle tables, its ids and its extensions.
pub const Spec = struct {
    core: Core,
    architecture: Architecture,
    cycles: ?std.EnumArray(Class, u8),
    taken: ?std.EnumArray(Class, u8),
    entry: u8,
    exit: u8,
    priority_bits: u4,
    cpuid: u32,
    ccr: u32,
    security: bool,
    floating_point: bool,
    double_precision: bool = false,
    fpv5: bool = false,
    half_precision: bool = false,
    pacbti: bool = false,
    mve: bool = false,
    mpu_regions: u8 = 0,
    mvfr: [3]u32 = @splat(0),
    caches: bool = false,
};

/// The size of a level 1 cache, as M7 TRM Table 3-7 lists them.
pub const CacheSize = enum { none, kb4, kb8, kb16, kb32, kb64 };

/// The size of a tightly-coupled memory, as the SZ encodings of M7 TRM Table 3-9 list them.
pub const TcmSize = enum(u4) { none = 0, kb4 = 3, kb8, kb16, kb32, kb64, kb128, kb256, kb512, mb1, mb2, mb4, mb8, mb16 };

/// One tightly-coupled memory as the part wires it: its size and the reset values of EN, RMW and RETEN, in the bits of CM7_ITCMCR and CM7_DTCMCR, M7 TRM 3.3.6.
pub const Tcm = packed struct { enabled: bool = false, read_modify_write: bool = false, retry: bool = false, size: TcmSize = .none };

/// The size of the AHB peripheral interface, as the SZ encodings of M7 TRM Table 3-10 list them.
pub const AhbpSize = enum(u3) { none, mb64, mb128, mb256, mb512 };

/// The AHB peripheral interface as the part wires it: its size and the reset value of EN, in the bits of CM7_AHBPCR, M7 TRM 3.3.7.
pub const Ahbp = packed struct { enabled: bool = false, size: AhbpSize = .none };

/// What one part was built with that the M7 TRM leaves to it, Table 1-1: its level 1 caches, its TCMs, its AHBP and whether its caches carry ECC; a core that carries none ignores them.
pub const Part = struct {
    data: CacheSize = .none,
    instruction: CacheSize = .none,
    itcm: Tcm = .{},
    dtcm: Tcm = .{},
    ahbp: Ahbp = .{},
    ecc: bool = false,
};

/// The spec of a core, each entry read off its Technical Reference Manual: the cycle tables from its instruction set summary, M4 TRM 3.3, and the entry and exit cycles from its interrupt latency, M4 TRM 3.9.2.
pub fn spec(comptime core: Core) Spec {
    @setEvalBranchQuota(200_000);
    var out: Spec = switch (core) {
        .m0plus => .{
            .core = .m0plus,
            .architecture = .armv6m,
            .cycles = .init(.{ .data_processing = 1, .load = 2, .store = 2, .load_multiple = 1, .store_multiple = 1, .push = 1, .pop = 1, .pop_pc = 3, .branch = 1, .branch_link = 2, .system = 1, .sleep = 2, .special_register = 3, .barrier = 3, .divide = 1 }),
            .taken = .init(.{ .data_processing = 1, .load = 0, .store = 0, .load_multiple = 0, .store_multiple = 0, .push = 0, .pop = 0, .pop_pc = 0, .branch = 1, .branch_link = 1, .system = 0, .sleep = 0, .special_register = 0, .barrier = 0, .divide = 0 }),
            .entry = 15,
            .exit = 10,
            .priority_bits = 2,
            .cpuid = 0x410c_c601,
            .ccr = 0x0000_0208,
            .security = false,
            .floating_point = false,
            .mpu_regions = 8,
        },
        .m4 => .{
            .core = .m4,
            .architecture = .armv7em,
            .cycles = .init(.{ .data_processing = 1, .load = 2, .store = 2, .load_multiple = 1, .store_multiple = 1, .push = 1, .pop = 1, .pop_pc = 1, .branch = 1, .branch_link = 1, .system = 1, .sleep = 1, .special_register = 1, .barrier = 1, .divide = 12 }),
            .taken = .init(.{ .data_processing = 2, .load = 2, .store = 0, .load_multiple = 2, .store_multiple = 0, .push = 0, .pop = 0, .pop_pc = 2, .branch = 2, .branch_link = 2, .system = 0, .sleep = 0, .special_register = 0, .barrier = 0, .divide = 0 }),
            .entry = 12,
            .exit = 10,
            .priority_bits = 4,
            .cpuid = 0x410f_c240,
            .ccr = 0x0000_0200,
            .security = false,
            .floating_point = true,
            .mpu_regions = 8,
            .mvfr = .{ 0x1011_0021, 0x1100_0011, 0x0000_0000 },
        },
        .m0 => like(.m0plus, .{
            .mpu_regions = 0,
            .cycles = std.EnumArray(Class, u8).init(.{ .data_processing = 1, .load = 2, .store = 2, .load_multiple = 1, .store_multiple = 1, .push = 1, .pop = 1, .pop_pc = 4, .branch = 1, .branch_link = 2, .system = 1, .sleep = 2, .special_register = 4, .barrier = 4, .divide = 1 }),
            .taken = std.EnumArray(Class, u8).init(.{ .data_processing = 2, .load = 0, .store = 0, .load_multiple = 0, .store_multiple = 0, .push = 0, .pop = 0, .pop_pc = 0, .branch = 2, .branch_link = 2, .system = 0, .sleep = 0, .special_register = 0, .barrier = 0, .divide = 0 }),
            .cpuid = 0x410c_c200,
        }),
        .m1 => like(.m0, .{ .cpuid = 0x410c_c210, .cycles = null, .taken = null }),
        .m23 => like(.m0plus, .{
            .architecture = .armv8m_base,
            .cycles = blk: {
                var c = spec(.m0plus).cycles.?;
                c.set(.divide, 17);
                break :blk c;
            },
            .cpuid = 0x411c_d200,
            .ccr = 0x0000_0209,
            .security = true,
        }),
        .m3 => like(.m4, .{ .architecture = .armv7m, .cpuid = 0x410f_c231, .exit = 12, .floating_point = false, .mvfr = [3]u32{ 0, 0, 0 } }),
        .m7 => like(.m4, .{ .cpuid = 0x411f_c272, .cycles = null, .taken = null, .ccr = 0x0004_0200, .double_precision = true, .fpv5 = true, .mvfr = [3]u32{ 0x1011_0221, 0x1200_0011, 0x0000_0040 }, .caches = true }),
        .m33 => like(.m4, .{ .architecture = .armv8m_main, .cpuid = 0x410f_d213, .cycles = null, .taken = null, .ccr = 0x0000_0201, .security = true, .fpv5 = true, .mvfr = [3]u32{ 0x1011_0021, 0x1100_0011, 0x0000_0040 } }),
        .m55 => like(.m33, .{ .architecture = .armv8_1m_main, .cpuid = 0x411f_d221, .double_precision = true, .half_precision = true, .mve = true, .mvfr = [3]u32{ 0x1011_0221, 0x1210_0211, 0x0000_0040 }, .caches = true }),
        .m85 => like(.m55, .{ .cpuid = 0x411f_d230, .pacbti = true }),
    };
    out.core = core;
    return out;
}

fn like(comptime base: Core, comptime changes: anytype) Spec {
    var out = spec(base);
    for (@typeInfo(@TypeOf(changes)).@"struct".fields) |field| {
        @field(out, field.name) = @field(changes, field.name);
    }
    return out;
}
