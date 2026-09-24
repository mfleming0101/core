const std = @import("std");
const core = @import("core");

const Cpu = core.arm.Processor(.{ .cores = &.{ .m0plus, .m4, .m7 }, .Bus = core.memory.Regions });

const movs_r0_0: u16 = 0x2000;
const ldr_r1_r0: u16 = 0x6801;
const str_r1_r0: u16 = 0x6001;
const bkpt_0: u16 = 0xbe00;

var bytes: [4096]u8 = @splat(0);
var entries = [_]core.memory.Regions.Entry{
    .{ .memory = .{ .base = 0, .bytes = &bytes, .writable = true } },
};

fn word(at: u32, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}

fn code(at: u32, halfwords: []const u16) void {
    for (halfwords, 0..) |h, i| std.mem.writeInt(u16, bytes[at + 2 * i ..][0..2], h, .little);
}

fn cyclesOn(memory: *core.memory.Regions, which: core.arm.Core) u64 {
    var cpu = Cpu.init(memory, which, .{});
    return cpu.run(.{ .instructions = 100 }).cycles;
}

test "one processor type built for three cores runs the same program with each core's own cycle table" {
    word(0x0, 0x1000);
    word(0x4, 0x8 | 1);
    code(0x8, &.{
        movs_r0_0,
        ldr_r1_r0,
        str_r1_r0,
        bkpt_0,
    });
    var memory = try core.memory.Regions.adopt(&entries);

    try std.testing.expectEqual(@as(u64, 5), cyclesOn(&memory, .m0plus));
    try std.testing.expectEqual(@as(u64, 5), cyclesOn(&memory, .m4));
    try std.testing.expectEqual(@as(u64, 3), cyclesOn(&memory, .m7));
}

test "the cycle table behind those counts is the core's spec, which a caller can read directly" {
    const m0plus = core.arm.spec(.m0plus);
    try std.testing.expectEqual(@as(u8, 2), m0plus.cycles.?.get(.load));
    try std.testing.expectEqual(@as(u8, 15), m0plus.entry);
    try std.testing.expectEqual(@as(?std.EnumArray(core.arm.Class, u8), null), comptime core.arm.spec(.m7).cycles);
    try std.testing.expect(comptime core.arm.spec(.m4).floating_point);
    try std.testing.expect(!m0plus.floating_point);
}
