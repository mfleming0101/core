//! What the library knows about each Cortex-M core, one Spec per core. A Spec is comptime
//! data: the architecture, the exception entry and exit cycles, the priority bits, CPUID and
//! MVFR, the reset CCR, the MPU region count, and which of the Security, floating-point, MVE
//! and PACBTI extensions are fitted. Cores are written as differences from one another. fitOf
//! holds the cycle tables fitted to boards; a core with none charges one cycle an instruction.
const std = @import("std");
const Class = @import("isa").arm.instruction.Class;
const Architecture = @import("isa").arm.Architecture;
const Rules = @import("isa").arm.step.Model.Rules;

/// The Cortex-M cores this half models.
pub const Core = enum { m0, m0plus, m1, m23, m3, m4, m7, m33, m55, m85 };

/// One core as comptime data: its architecture, its exception cycles, its ids and its extensions.
pub const Spec = struct {
    core: Core,
    architecture: Architecture,
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

/// A cycle table: each class's cost, the extra when taken, and what each register of its list adds.
pub const Table = struct { cycles: std.EnumArray(Class, u8), taken: std.EnumArray(Class, u8), per_register: std.EnumArray(Class, u8) };

const register_lists: std.EnumArray(Class, u8) = .init(.{ .data_processing = 0, .load = 0, .store = 0, .load_multiple = 1, .store_multiple = 1, .push = 1, .pop = 1, .pop_pc = 1, .branch = 0, .branch_link = 0, .system = 0, .sleep = 0, .special_register = 0, .barrier = 0, .divide = 0, .multiply = 0 });

/// Which cycles a core charges: one per instruction, or the fitted table with its rules.
pub const Timing = enum { unknown, fitted };

/// For each class, a set of the classes that may follow it.
pub const Pairs = std.EnumArray(Class, std.EnumSet(Class));

/// How a core issues after the previous instruction: pairing, waits, stalls, penalties, prefetch, fetch
/// words, branch targets, IT/NOP folding.
pub const Issue = struct { pairs: Pairs, waits: Pairs, delays: std.EnumSet(Class), address: u8, product: u8, load: u8, shift: u8, pipelined: bool, width: u8, miss: u8, mispredict: u8, flush: u8, forward: u8, rmw: u8, indexed: u8, buffer: u8, slow: u8, prefetch: u8, fetch: u8, targets: u8, reach: u32, table: u8, settle: u8, fold: bool, stack: bool };

/// A fitted table, the rules it needs beyond one cost a class, and how the core issues.
pub const Fit = struct { table: Table, rules: Rules, issue: ?Issue = null };

/// The size of a level 1 cache, as M7 TRM Table 3-7 lists them.
pub const CacheSize = enum { none, kb4, kb8, kb16, kb32, kb64 };

/// The size of a tightly-coupled memory, as the SZ encodings of M7 TRM Table 3-9 list them.
pub const TcmSize = enum(u4) { none = 0, kb4 = 3, kb8, kb16, kb32, kb64, kb128, kb256, kb512, mb1, mb2, mb4, mb8, mb16 };

/// A part's tightly-coupled memory: size and reset EN, RMW and RETEN, as in CM7_ITCMCR and
/// CM7_DTCMCR, M7 TRM 3.3.6.
pub const Tcm = packed struct { enabled: bool = false, read_modify_write: bool = false, retry: bool = false, size: TcmSize = .none };

/// The size of the AHB peripheral interface, as the SZ encodings of M7 TRM Table 3-10 list them.
pub const AhbpSize = enum(u3) { none, mb64, mb128, mb256, mb512 };

/// A part's AHB peripheral interface: size and reset EN, as in CM7_AHBPCR, M7 TRM 3.3.7.
pub const Ahbp = packed struct { enabled: bool = false, size: AhbpSize = .none };

/// What one part was built with that its core's TRM leaves to it; a core without an option ignores
/// it.
pub const Part = struct {
    /// Level 1 data cache of the M7, M55 or M85, M7 TRM Table 1-1.
    data: CacheSize = .none,
    /// Level 1 instruction cache of the M7, M55 or M85, M7 TRM Table 1-1.
    instruction: CacheSize = .none,
    /// M7 ITCM, M7 TRM Table 1-1; M55 and M85 ITCMCR size and enable, M55 and M85 TRM Table 5-42.
    itcm: Tcm = .{},
    /// M7 DTCM, M7 TRM Table 1-1; M55 and M85 DTCMCR size and enable, M55 and M85 TRM Table 5-42.
    dtcm: Tcm = .{},
    /// M7 AHBP, M7 TRM Table 1-1; M55 and M85 P-AHB size and enable, M55 and M85 TRM Table 5-28.
    ahbp: Ahbp = .{},
    /// ECC fitted, M7 TRM Table 1-1, and MSCR ECCEN on the M55 and M85, M55 and M85 TRM Table 5-27.
    ecc: bool = false,
    /// MPU region count; null is the core's default.
    mpu_regions: ?u8 = null,
    /// Non-secure MPU region count; null is the core's default.
    mpu_ns_regions: ?u8 = null,
    /// SAU region count; null is the core's default.
    sau_regions: ?u8 = null,
    /// Implemented priority bits; null is the core's default.
    priority_bits: ?u4 = null,
    /// External interrupt count; null is the core's default.
    interrupts: ?u16 = null,
    /// REVIDRNUM the M55 and M85 read in REVIDR, M55 and M85 TRM 5.7.
    revidr: u4 = 0,
    /// Reset VTOR, from M7 INITVTOR, M7 TRM Table 3-1, M23 pins, M23 TRM Table 5-1, or INITSVTOR
    /// elsewhere.
    vtor: u32 = 0,
    /// Non-secure reset VTOR, from INITNSVTOR, M33 TRM Table 3-1, M55 and M85 TRM Table 5-1.
    vtor_ns: u32 = 0,
    /// SYST_CALIB: SKEW and TENMS as CFGSTCALIB wires them, M7 TRM Table 3-2, or CFGSSTCALIB, M55
    /// and M85 TRM C.3.
    calibration: u32 = 0,
    /// Whether an M23 fits the Non-secure SysTick, M23 TRM Table 2-1; the M33, M55 and M85 always
    /// do, v8-M D1.2.240.
    systick_ns: bool = false,
    /// SYST_CALIB_NS from CFGNSSTCALIB, M55 and M85 TRM C.3; NOREF reads one in both, as no
    /// reference clock is fitted.
    calibration_ns: u32 = 0,
    /// EWIC events an M55 or M85 supports: zero for none, else 4 to 483, M55 and M85 TRM A.1.
    ewic: u16 = 0,
};

/// The values a part may choose for one option, as its TRM lists them.
pub const Choice = union(enum) {
    only: []const u16,
    range: struct { least: u16, most: u16 },

    /// The most a part may choose.
    pub fn most(self: Choice) u16 {
        return switch (self) {
            .only => |values| values[values.len - 1],
            .range => |r| r.most,
        };
    }

    /// A part's value lowered to the nearest listed value, else the least listed, or clamped to the
    /// range.
    pub fn fit(self: Choice, value: u16) u16 {
        switch (self) {
            .only => |values| {
                var out = values[0];
                for (values) |v| {
                    if (v <= value) out = v;
                }
                return out;
            },
            .range => |r| return std.math.clamp(value, r.least, r.most),
        }
    }
};

/// What a part of one core may choose, each from its TRM's configuration options.
pub const Choices = struct { mpu_regions: Choice, mpu_ns_regions: Choice, sau_regions: Choice, priority_bits: Choice, interrupts: Choice };

/// What a core lets a part choose for MPU and SAU regions, priority bits and interrupts, per its
/// TRM.
pub fn choicesOf(comptime core: Core) Choices {
    const none: Choice = .{ .only = &.{0} };
    const fours: Choice = .{ .only = &.{ 0, 4, 8, 12, 16 } };
    const two: Choice = .{ .only = &.{2} };
    const three_to_eight: Choice = .{ .range = .{ .least = 3, .most = 8 } };
    const sau: Choice = .{ .only = &.{ 0, 4, 8 } };
    const up_to_240: Choice = .{ .range = .{ .least = 1, .most = 240 } };
    const up_to_480: Choice = .{ .range = .{ .least = 1, .most = 480 } };
    return switch (core) {
        .m0 => .{ .mpu_regions = none, .mpu_ns_regions = none, .sau_regions = none, .priority_bits = two, .interrupts = .{ .only = &.{ 1, 2, 4, 8, 16, 24, 32 } } },
        .m1 => .{ .mpu_regions = none, .mpu_ns_regions = none, .sau_regions = none, .priority_bits = two, .interrupts = .{ .only = &.{ 1, 8, 16, 32 } } },
        .m0plus => .{ .mpu_regions = .{ .only = &.{ 0, 8 } }, .mpu_ns_regions = none, .sau_regions = none, .priority_bits = two, .interrupts = .{ .range = .{ .least = 0, .most = 32 } } },
        .m3, .m4 => .{ .mpu_regions = .{ .only = &.{ 0, 8 } }, .mpu_ns_regions = none, .sau_regions = none, .priority_bits = three_to_eight, .interrupts = up_to_240 },
        .m7 => .{ .mpu_regions = .{ .only = &.{ 0, 8, 16 } }, .mpu_ns_regions = none, .sau_regions = none, .priority_bits = three_to_eight, .interrupts = up_to_240 },
        .m23 => .{ .mpu_regions = fours, .mpu_ns_regions = fours, .sau_regions = sau, .priority_bits = two, .interrupts = up_to_240 },
        .m33, .m55, .m85 => .{ .mpu_regions = fours, .mpu_ns_regions = fours, .sau_regions = sau, .priority_bits = three_to_eight, .interrupts = up_to_480 },
    };
}

/// A core's spec from its TRM: interrupt entry and exit cycles, M4 TRM 3.9.2, ids and extensions.
pub fn spec(comptime core: Core) Spec {
    @setEvalBranchQuota(200_000);
    var out: Spec = switch (core) {
        .m0plus => .{
            .core = .m0plus,
            .architecture = .armv6m,
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
            .cpuid = 0x410c_c200,
        }),
        .m1 => like(.m0, .{ .cpuid = 0x410c_c210 }),
        .m23 => like(.m0plus, .{
            .architecture = .armv8m_base,
            .cpuid = 0x411c_d200,
            .ccr = 0x0000_0209,
            .security = true,
        }),
        .m3 => like(.m4, .{ .architecture = .armv7m, .cpuid = 0x410f_c231, .exit = 12, .floating_point = false, .mvfr = [3]u32{ 0, 0, 0 } }),
        .m7 => like(.m4, .{ .cpuid = 0x411f_c272, .ccr = 0x0004_0200, .double_precision = true, .fpv5 = true, .mvfr = [3]u32{ 0x1011_0221, 0x1200_0011, 0x0000_0040 }, .caches = true }),
        .m33 => like(.m4, .{ .architecture = .armv8m_main, .cpuid = 0x410f_d213, .ccr = 0x0000_0201, .security = true, .fpv5 = true, .mvfr = [3]u32{ 0x1011_0021, 0x1100_0011, 0x0000_0040 } }),
        .m55 => like(.m33, .{ .architecture = .armv8_1m_main, .cpuid = 0x411f_d221, .double_precision = true, .half_precision = true, .mve = true, .mvfr = [3]u32{ 0x1011_0221, 0x1210_0211, 0x0000_0040 }, .caches = true }),
        .m85 => like(.m55, .{ .cpuid = 0x411f_d230, .pacbti = true }),
    };
    out.core = core;
    return out;
}

/// A core's fitted timing, or null where it has none.
pub fn fitOf(comptime core: Core) ?Fit {
    return switch (core) {
        .m0plus => .{
            .table = .{
                .cycles = .init(.{ .data_processing = 1, .load = 2, .store = 2, .load_multiple = 1, .store_multiple = 1, .push = 1, .pop = 1, .pop_pc = 3, .branch = 1, .branch_link = 2, .system = 1, .sleep = 2, .special_register = 3, .barrier = 3, .divide = 1, .multiply = 1 }),
                .taken = .init(.{ .data_processing = 1, .load = 0, .store = 0, .load_multiple = 0, .store_multiple = 0, .push = 0, .pop = 0, .pop_pc = 0, .branch = 1, .branch_link = 1, .system = 0, .sleep = 0, .special_register = 0, .barrier = 0, .divide = 0, .multiply = 0 }),
                .per_register = register_lists,
            },
            .rules = .{},
        },
        .m4 => blk: {
            const table: Table = .{
                .cycles = .init(.{ .data_processing = 1, .load = 2, .store = 1, .load_multiple = 1, .store_multiple = 1, .push = 1, .pop = 1, .pop_pc = 1, .branch = 1, .branch_link = 1, .system = 1, .sleep = 1, .special_register = 1, .barrier = 1, .divide = 12, .multiply = 1 }),
                .taken = .init(.{ .data_processing = 2, .load = 2, .store = 0, .load_multiple = 2, .store_multiple = 0, .push = 0, .pop = 0, .pop_pc = 3, .branch = 1, .branch_link = 1, .system = 0, .sleep = 0, .special_register = 0, .barrier = 0, .divide = 0, .multiply = 0 }),
                .per_register = register_lists,
            };
            const alone: Pairs = .initFill(.initEmpty());
            break :blk .{ .table = table, .rules = .{ .divide = .{ .zero_divisor = 2, .zero_dividend = 2, .narrower = 3, .base = 4, .bits = 4, .signed = 0 }, .straddle = true }, .issue = .{ .pairs = alone, .waits = alone, .delays = .initMany(&.{ .data_processing, .multiply }), .address = 1, .product = 0, .load = 0, .shift = 0, .pipelined = true, .width = 0, .miss = 0, .mispredict = 0, .flush = 2, .forward = 0, .rmw = 0, .indexed = 1, .buffer = 0, .slow = 0, .prefetch = 12, .fetch = 0, .targets = 0, .reach = 0, .table = 4, .settle = 0, .fold = true, .stack = true } };
        },
        .m7 => blk: {
            var table: Table = .{ .cycles = .initFill(1), .taken = .initFill(0), .per_register = .initFill(0) };
            table.cycles.set(.load_multiple, 0);
            table.cycles.set(.store_multiple, 0);
            table.cycles.set(.pop, 0);
            table.cycles.set(.pop_pc, 0);
            table.taken.set(.pop_pc, 7);
            table.cycles.set(.barrier, 5);
            table.cycles.set(.special_register, 4);
            const single: std.EnumSet(Class) = .initMany(&.{ .data_processing, .load, .store, .branch, .system, .multiply });
            var pairs: Pairs = .initFill(.initEmpty());
            for ([_]Class{ .data_processing, .load, .store, .branch, .system, .multiply }) |first| {
                var second = single;
                if (first != .data_processing and first != .system and first != .load) second.remove(first);
                pairs.set(first, second);
            }
            var waits: Pairs = .initFill(.initEmpty());
            waits.set(.data_processing, .initOne(.data_processing));
            waits.set(.load, .initOne(.data_processing));
            break :blk .{ .table = table, .rules = .{ .divide = .{ .zero_divisor = 3, .zero_dividend = 7, .narrower = 3, .base = 3, .bits = 2, .signed = 1 }, .straddle = true }, .issue = .{ .pairs = pairs, .waits = waits, .delays = .initFull(), .address = 1, .product = 1, .load = 2, .shift = 1, .pipelined = false, .width = 2, .miss = 3, .mispredict = 6, .flush = 2, .forward = 5, .rmw = 4, .indexed = 0, .buffer = 11, .slow = 2, .prefetch = 0, .fetch = 8, .targets = 34, .reach = 4096, .table = 1, .settle = 2, .fold = false, .stack = false } };
        },
        else => null,
    };
}

fn like(comptime base: Core, comptime changes: anytype) Spec {
    var out = spec(base);
    for (@typeInfo(@TypeOf(changes)).@"struct".fields) |field| {
        @field(out, field.name) = @field(changes, field.name);
    }
    return out;
}
