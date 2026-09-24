const std = @import("std");
const State = @import("isa").arm.State;
const trace = @import("../../src/arm/trace.zig");
const groups = @import("isa").arm.decode.selectionOf(.armv7m).groups;
var records: [256]trace.Record = undefined;
var shallow: [4]trace.Record = undefined;

fn push(ring: anytype, r: trace.Record) void {
    ring.reserve().* = r;
}

fn record(pc: u32, code: ?u32) trace.Record {
    return .{ .pc = pc, .code = code orelse 0, .changed = 0, .values = @splat(0), .access = null, .cycles = 0, .note = .{ .fetched = code != null } };
}

test "snapshot lists r0 to r12, the selected stack pointer, lr, and xpsr" {
    var s: State = .{ .msp = 0x2000_1000, .psp = 0x2000_2000, .lr = 0xffff_ffff, .xpsr = State.flag_t };
    s.r[12] = 12;
    const shot = trace.snapshot(&s);
    try std.testing.expectEqual(@as(u32, 12), shot[12]);
    try std.testing.expectEqual(@as(u32, 0x2000_1000), shot[13]);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), shot[14]);
    try std.testing.expectEqual(State.flag_t, shot[15]);
    s.control = State.control_spsel;
    try std.testing.expectEqual(@as(u32, 0x2000_2000), trace.snapshot(&s)[13]);
}

test "write marks each register whose value changed, stores those values, and advances the previous snapshot" {
    var last: trace.Registers = @splat(0);
    var s: State = .{ .xpsr = State.flag_z };
    s.r[1] = 3;
    var r: trace.Record = undefined;
    r.write(0xa, 0x1c81, &last, &s, null, 7, .{});
    try std.testing.expectEqual(@as(u16, (1 << 1) | (1 << 15)), r.changed);
    try std.testing.expectEqual(@as(u64, 7), r.cycles);
    try std.testing.expectEqual(@as(u32, 3), r.values[1]);
    try std.testing.expectEqual(State.flag_z, r.values[15]);
    try std.testing.expectEqual(trace.snapshot(&s), last);
    try std.testing.expectEqual(@as(?u32, null), r.access);
    r.write(0xc, 0x1c81, &last, &s, null, 8, .{});
    try std.testing.expectEqual(@as(u16, 0), r.changed);
}

test "a record renders as one line: the address, the code, the assembly, then the changed registers" {
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    var values: trace.Registers = @splat(0);
    values[0] = 1;
    values[15] = State.flag_t;
    try trace.writeLine(&w, .{ .pc = 8, .code = 0x2001, .changed = 1, .values = values, .access = null, .cycles = 0, .note = .{ .fetched = true } }, groups);
    try std.testing.expectEqualStrings("at      0  pc=00000008 code=2001 movs r0, #1 ; r0=00000001\n", w.buffered());
}

test "a record of a data access ends with the first address the instruction touched" {
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try trace.writeLine(&w, .{ .pc = 0xc, .code = 0x6008, .changed = 0, .values = @splat(0), .access = 0x400, .cycles = 0, .note = .{ .fetched = true } }, groups);
    try std.testing.expectEqualStrings("at      0  pc=0000000c code=6008 str r0, [r1, #0] ; mem=00000400\n", w.buffered());
    var values: trace.Registers = @splat(0);
    values[2] = 5;
    var both: std.Io.Writer = .fixed(&buffer);
    try trace.writeLine(&both, .{ .pc = 0xe, .code = 0x680a, .changed = 1 << 2, .values = values, .access = 0x400, .cycles = 0, .note = .{ .fetched = true } }, groups);
    try std.testing.expectEqualStrings("at      0  pc=0000000e code=680a ldr r2, [r1, #0] ; r2=00000005 mem=00000400\n", both.buffered());
}

test "the lines only the core writes: an entry with its line and latency, a return, and a refused access" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    var values: trace.Registers = @splat(0);
    values[13] = 0x2000_0fe0;
    values[14] = 0xffff_fff9;
    values[15] = 0x0100_0021;
    try trace.writeLine(&w, .{ .pc = 0x130, .code = 0, .changed = 0xe000, .values = values, .access = null, .cycles = 431, .note = .{ .kind = .irq, .number = 17, .latency = 15 } }, groups);
    try std.testing.expectEqualStrings("at    431  pc=00000130 code=---- ; sp=20000fe0 lr=fffffff9 xpsr=01000021 irq=17 latency=15\n", w.buffered());

    var back: std.Io.Writer = .fixed(&buffer);
    try trace.writeLine(&back, .{ .pc = 0x12e, .code = 0, .changed = 0, .values = values, .access = null, .cycles = 461, .note = .{ .kind = .exit, .latency = 10 } }, groups);
    try std.testing.expectEqualStrings("at    461  pc=0000012e code=---- ; return latency=10\n", back.buffered());

    var refused: std.Io.Writer = .fixed(&buffer);
    try trace.writeLine(&refused, .{ .pc = 0xc, .code = 0x6008, .changed = 0, .values = @splat(0), .access = 0x400, .cycles = 9, .note = .{ .fetched = true, .refused = .protection } }, groups);
    try std.testing.expectEqualStrings("at      9  pc=0000000c code=6008 str r0, [r1, #0] ; mem=00000400 refused=protection\n", refused.buffered());
}

test "a record of a step that never fetched renders its address and no code" {
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try trace.writeLine(&w, record(0x10, null), groups);
    try std.testing.expectEqualStrings("at      0  pc=00000010 code=----\n", w.buffered());
}

test "explain says the T bit was clear and why" {
    var ring: trace.Ring = try .init(&records);
    push(&ring, record(0x10, null));
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try trace.explain(&w, .not_t32_state, &ring, 0, groups);
    try std.testing.expectEqualStrings("The core reached pc=00000010 outside T32 state, because the address loaded into pc was even. The core locked up.\n", w.buffered());
}

test "a record of a code that is not an instruction renders as undefined" {
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try trace.writeLine(&w, record(0x10, 0xde00), groups);
    try std.testing.expectEqualStrings("at      0  pc=00000010 code=de00 undefined\n", w.buffered());
}

test "a ring refuses a depth that is not a power of two rather than quietly keeping fewer records" {
    var odd: [6]trace.Record = undefined;
    try std.testing.expectError(error.NotPowerOfTwo, trace.Ring.init(&odd));
}

test "a ring keeps the newest records up to its depth and counts every push" {
    var ring: trace.Ring = try .init(&shallow);
    try std.testing.expectEqual(@as(?trace.Record, null), ring.last());
    for (0..6) |i| push(&ring, record(@intCast(i), 0));
    try std.testing.expectEqual(@as(u64, 6), ring.written);
    try std.testing.expectEqual(@as(u32, 5), ring.last().?.pc);
    try std.testing.expectEqual(@as(u32, 4), ring.at(1).?.pc);
    try std.testing.expectEqual(@as(u32, 2), ring.at(3).?.pc);
    try std.testing.expectEqual(@as(?trace.Record, null), ring.at(4));
    try std.testing.expectEqual(@as(usize, 4), ring.records.len);
}

test "explain names the stop, its address, and then the trace that led to it" {
    var ring: trace.Ring = try .init(&records);
    push(&ring, record(8, 0x2001));
    push(&ring, record(0xa, 0xbe03));
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try trace.explain(&w, .breakpoint, &ring, 8, groups);
    try std.testing.expectEqualStrings(
        \\The core stopped at BKPT #3 at pc=0000000a.
        \\The last 2 lines of the trace:
        \\at      0  pc=00000008 code=2001 movs r0, #1
        \\at      0  pc=0000000a code=be03 bkpt #3
        \\
    , w.buffered());
}

test "explain says which code was not an instruction and where" {
    var ring: trace.Ring = try .init(&records);
    push(&ring, record(0x10, 0xde00));
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try trace.explain(&w, .undefined_instruction, &ring, 8, groups);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "The code de00 at pc=00000010 is not an instruction of this architecture. The core locked up.\n"));
}

test "explain names an unimplemented instruction by its assembly text and blames the emulator" {
    var ring: trace.Ring = try .init(&records);
    push(&ring, record(8, 0xdf01));
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try trace.explain(&w, .unimplemented, &ring, 0, groups);
    try std.testing.expectEqualStrings("The code df01 at pc=00000008 is svc #1, which this emulator does not implement yet.\n", w.buffered());
}

test "explain names the address of a data fault and of an unaligned access" {
    var ring: trace.Ring = try .init(&records);
    var r = record(0xa, 0x6808);
    r.access = 0xffff_0000;
    push(&ring, r);
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try trace.explain(&w, .data_fault, &ring, 0, groups);
    try std.testing.expectEqualStrings("No memory answered the data access to ffff0000 by the code 6808 at pc=0000000a. The core locked up.\n", w.buffered());
    r.access = 0x401;
    push(&ring, r);
    var again: std.Io.Writer = .fixed(&buffer);
    try trace.explain(&again, .unaligned_access, &ring, 0, groups);
    try std.testing.expectEqualStrings("The code 6808 at pc=0000000a accessed 00000401, which is not aligned to the size of the access. The core locked up.\n", again.buffered());
}

test "writeLast renders the newest n records in order, or every record when fewer exist" {
    var ring: trace.Ring = try .init(&records);
    for (0..3) |i| push(&ring, record(@intCast(8 + 2 * i), 0x2001));
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try trace.writeLast(&w, &ring, 2, groups);
    try std.testing.expectEqualStrings("at      0  pc=0000000a code=2001 movs r0, #1\nat      0  pc=0000000c code=2001 movs r0, #1\n", w.buffered());
    var all: std.Io.Writer = .fixed(&buffer);
    try trace.writeLast(&all, &ring, 10, groups);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, all.buffered(), "\n"));
}

test "the recap header counts the lines a full ring can still show" {
    var ring: trace.Ring = try .init(&shallow);
    for (0..6) |i| push(&ring, record(@intCast(8 + 2 * i), 0x2001));
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try trace.explain(&w, .breakpoint, &ring, 8, groups);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "The last 4 lines of the trace:\n") != null);
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, w.buffered(), "\n"));
}

test "explain with no recap is the one sentence about the stop" {
    var ring: trace.Ring = try .init(&records);
    push(&ring, record(0xa, 0xbe03));
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try trace.explain(&w, .breakpoint, &ring, 0, groups);
    try std.testing.expectEqualStrings("The core stopped at BKPT #3 at pc=0000000a.\n", w.buffered());
}

test "a record of a 32-bit instruction renders its eight-digit code in the assembly of its architecture" {
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    var values: trace.Registers = @splat(0);
    values[0] = 0x1234;
    try trace.writeLine(&w, .{ .pc = 8, .code = 0xf2412034, .changed = 1, .values = values, .access = null, .cycles = 0, .note = .{ .fetched = true } }, groups);
    try std.testing.expectEqualStrings("at      0  pc=00000008 code=f2412034 movw r0, #4660 ; r0=00001234\n", w.buffered());
    var ring: trace.Ring = try .init(&records);
    push(&ring, .{ .pc = 8, .code = 0xf8505e04, .changed = 0, .values = values, .access = null, .cycles = 0, .note = .{ .fetched = true } });
    var again: std.Io.Writer = .fixed(&buffer);
    try trace.explain(&again, .unimplemented, &ring, 0, groups);
    try std.testing.expectEqualStrings("The code f8505e04 at pc=00000008 is ldrt r5, [r0, #4], which this emulator does not implement yet.\n", again.buffered());
}
