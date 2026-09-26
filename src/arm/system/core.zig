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

/// What one part was built with that its core's TRM leaves to it: the level 1 caches of the M7, M55 and M85, the M7 TCMs, AHBP and ECC of M7 TRM Table 1-1, the MPU and SAU region counts, the priority bits and the external interrupts; a core that carries none ignores them, and a value left null is the core's default.
pub const Part = struct {
    data: CacheSize = .none,
    instruction: CacheSize = .none,
    itcm: Tcm = .{},
    dtcm: Tcm = .{},
    ahbp: Ahbp = .{},
    ecc: bool = false,
    mpu_regions: ?u8 = null,
    mpu_ns_regions: ?u8 = null,
    sau_regions: ?u8 = null,
    priority_bits: ?u4 = null,
    interrupts: ?u16 = null,
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

    /// A part's value lowered to the nearest value listed, the least where none is below it, or clamped to the range.
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

/// The choices of a core. The MPU: none on the M0, M0 TRM Table 1-1, or the M1, M1 TRM Table 1-1; none or eight regions on the M0+, M0+ TRM Table 1-1, and the M3 and M4, M3 and M4 TRM 1.4 2.2; none, eight or sixteen on the M7, M7 TRM Table 1-1; and none to sixteen in fours for each Security state on the M23, M23 TRM Table 1-1, the M33, M33 TRM 1.3, and the M55 and M85, M55 and M85 TRM Table 3-4. The SAU: none, four or eight regions on those four, the same tables. Priority bits: two on the M0, M0+ and M23, M0, M0+ and M23 TRM 2.1, and the M1, M1 TRM 1.1; three to eight on the rest, the same tables as the MPU. External interrupts: 1, 2, 4, 8, 16, 24 or 32 on the M0; 0 to 32 on the M0+; 1, 8, 16 or 32 on the M1; 1 to 240 on the M3, M4, M7 and M23; and 1 to 480 on the M33, M55 and M85; the same tables as the MPU.
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
