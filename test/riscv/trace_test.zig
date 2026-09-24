const std = @import("std");
const State = @import("isa").riscv.State;
const trace = @import("../../src/riscv/trace.zig");
const groups = @import("isa").riscv.decode.every;

fn record(pc: u32, code: ?u32, changed: u32, values: trace.Registers, access: ?u32) trace.Record {
    return .{ .pc = pc, .code = code orelse 0, .changed = changed, .values = values, .access = access, .cycles = 0, .note = .{ .fetched = code != null } };
}

test "snapshot lists x1 to x31 and leaves x0 out, since it never changes" {
    var s: State = .{};
    s.x[1] = 0xdead_beef;
    s.x[31] = 31;
    const shot = trace.snapshot(&s);
    try std.testing.expectEqual(@as(usize, 31), shot.len);
    try std.testing.expectEqual(@as(u32, 0xdead_beef), shot[0]);
    try std.testing.expectEqual(@as(u32, 31), shot[30]);
    try std.testing.expectEqualStrings("ra", trace.register_names[0]);
    try std.testing.expectEqualStrings("sp", trace.register_names[1]);
    try std.testing.expectEqualStrings("t6", trace.register_names[30]);
}

test "write marks each register whose value changed, stores those values, and advances the previous snapshot" {
    var last: trace.Registers = @splat(0);
    var s: State = .{};
    s.x[10] = 5;
    var r: trace.Record = undefined;
    r.write(0x4200_0000, 0x0025_0593, &last, &s, null, 7, .{});
    try std.testing.expectEqual(@as(u32, 1 << 9), r.changed);
    try std.testing.expectEqual(@as(u64, 7), r.cycles);
    try std.testing.expectEqual(@as(u32, 5), r.values[9]);
    try std.testing.expectEqual(trace.snapshot(&s), last);
    r.write(0x4200_0004, 0x0025_0593, &last, &s, null, 8, .{});
    try std.testing.expectEqual(@as(u32, 0), r.changed);
}

test "a record renders as one line: the address, the code, the assembly, then the changed registers" {
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    var values: trace.Registers = @splat(0);
    values[10] = 15;
    try trace.writeLine(&w, record(0x4200_0000, 0x0025_0593, 1 << 10, values, null), groups);
    try std.testing.expectEqualStrings("at      0  pc=42000000 code=00250593 addi a1, a0, 2 ; a1=0000000f\n", w.buffered());
}

test "a record of a data access ends with the first address the instruction touched" {
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try trace.writeLine(&w, record(0x4200_0004, 0xfea1_2e23, 0, @splat(0), 0x3fc8_0000), groups);
    try std.testing.expectEqualStrings("at      0  pc=42000004 code=fea12e23 sw a0, -4(sp) ; mem=3fc80000\n", w.buffered());
}

test "a compressed instruction prints its parcel in four digits and a 32-bit one prints eight, Unprivileged 1.5" {
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    var values: trace.Registers = @splat(0);
    values[9] = 5;
    try trace.writeLine(&w, record(0x4200_0000, 0x4515, 1 << 9, values, null), groups);
    try std.testing.expectEqualStrings("at      0  pc=42000000 code=4515 c.li a0, 5 ; a0=00000005\n", w.buffered());

    var second: std.Io.Writer = .fixed(&buffer);
    try trace.writeLine(&second, record(0x4200_0002, 0x0035_0593, 0, @splat(0), null), groups);
    try std.testing.expectEqualStrings("at      0  pc=42000002 code=00350593 addi a1, a0, 3\n", second.buffered());
}

test "a record whose fetch answered nothing renders without a code" {
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try trace.writeLine(&w, record(0x4200_0008, null, 0, @splat(0), null), groups);
    try std.testing.expectEqualStrings("at      0  pc=42000008 code=--------\n", w.buffered());
}

test "explain says which stop ended the run and recaps the last lines of the trace" {
    var records: [4]trace.Record = undefined;
    var ring: trace.Ring = try .init(&records);
    ring.reserve().* = record(0x4200_0010, 0x0010_0073, 0, @splat(0), null);
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try trace.explain(&w, .breakpoint, &ring, 0, groups);
    try std.testing.expectEqualStrings("The core stopped at EBREAK at pc=42000010.\n", w.buffered());

    var second: std.Io.Writer = .fixed(&buffer);
    try trace.explain(&second, .unrecoverable_trap, &ring, 1, groups);
    try std.testing.expectEqualStrings(
        \\The code 00100073 at pc=42000010 is the first instruction of the trap handler and it trapped, so the hart would take that trap for ever. The core locked up.
        \\The last 1 lines of the trace:
        \\at      0  pc=42000010 code=00100073 ebreak
        \\
    , second.buffered());
}
