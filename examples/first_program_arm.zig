const std = @import("std");
const core = @import("core");

const Cpu = core.arm.Processor(.{ .cores = &.{.m0plus}, .Bus = core.memory.Regions });

const movs_r0_1: u16 = 0x2001;
const adds_r1_r0_2: u16 = 0x1c81;
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

test "three instructions in memory, a vector table in front of them, and a core that runs them to the breakpoint" {
    word(0x0, 0x1000);
    word(0x4, 0x8 | 1);
    code(0x8, &.{
        movs_r0_1,
        adds_r1_r0_2,
        bkpt_0,
    });

    var memory = try core.memory.Regions.adopt(&entries);
    var cpu = Cpu.init(&memory, .m0plus, .{}, .{});
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.state.sp());
    try std.testing.expectEqual(@as(u32, 0x8), cpu.state.pc);

    const ran = cpu.run(.{ .instructions = 100 });

    try std.testing.expectEqual(@as(?core.arm.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(@as(u64, 2), ran.instructions);
    try std.testing.expectEqual(@as(u32, 1), cpu.state.r[0]);
    try std.testing.expectEqual(@as(u32, 3), cpu.state.r[1]);
    try std.testing.expectEqual(@as(u32, 0xc), cpu.state.pc);
}
