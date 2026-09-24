//! What the library knows about each Espressif part, one Spec per core. A Spec is comptime
//! data: the decode groups the part implements, its cycle table or null where none is
//! published, its reset PC and flat memory, its CSR implementation, the addresses of its
//! interrupt matrix and controller, and its PMP priority rule. Processor builds a table of
//! these and holds the one it was built as; nothing here is read on the instruction path.
const std = @import("std");
const Class = @import("isa").riscv.instruction.Class;
const decode = @import("isa").riscv.decode;
const csr = @import("isa").riscv.csr;
const intc = @import("intc.zig");

/// The Espressif parts this half models.
pub const Core = enum { esp32c3, esp32c6 };

/// Where the flash and the RAM of a part begin, for a caller building a bus with no map.
pub const Flat = struct {
    flash_base: u32,
    ram_base: u32,
};

/// One part as comptime data: its groups, its cycle table, its reset and its blocks.
pub const Spec = struct {
    core: Core,
    groups: decode.Groups,
    cycles: ?std.EnumArray(Class, u8),
    taken: ?std.EnumArray(Class, u8),
    reset_pc: u32,
    flat: Flat,

    /// The CSR implementation: isa's word for which registers the part has and what they hold.
    model: csr.Implementation,

    /// Where the part puts its interrupt matrix and controller registers.
    intc: intc.Layout,

    /// Whether the lowest matching PMP entry decides, rather than any match granting.
    pmp_static_priority: bool,
};

const esp32c3_csr: csr.Implementation = .{
    .isa = 0x4010_1104,
    .vendor_id = 0x0000_0612,
    .architecture_id = 0x8000_0001,
    .implementation_id = 0x0000_0001,
    .mstatus_writable = 0x0020_1888,
    .cause_mask = 0x8000_001f,
    .tvec_base_mask = 0xffff_ff00,
    .tvec_modes = .vectored,
    .misaligned = .refused,
    .sc_failure = 1,
    .interrupt_csrs = false,
    .float = false,
};

const esp32c6_csr: csr.Implementation = blk: {
    var m = esp32c3_csr;
    m.isa = 0x4010_1105;
    m.architecture_id = 0x8000_0002;
    m.implementation_id = 0x0000_0002;
    m.interrupt_csrs = true;
    break :blk m;
};

/// The spec of a part; the C6 is written as the C3 with its differences applied.
pub fn spec(comptime core: Core) Spec {
    var out: Spec = switch (core) {
        .esp32c3 => .{
            .core = .esp32c3,
            .groups = decode.only(&.{ .rv32i, .m, .c, .zicsr }),
            .cycles = null,
            .taken = null,
            .reset_pc = 0x4200_0000,
            .flat = .{ .flash_base = 0x4200_0000, .ram_base = 0x3FC8_0000 },
            .model = esp32c3_csr,
            .intc = intc.esp32c3,
            .pmp_static_priority = false,
        },
        .esp32c6 => like(.esp32c3, .{
            .groups = decode.only(&.{ .rv32i, .m, .a, .c, .zicsr }),
            .flat = Flat{ .flash_base = 0x4200_0000, .ram_base = 0x4080_0000 },
            .model = esp32c6_csr,
            .intc = intc.esp32c6,
            .pmp_static_priority = true,
        }),
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
