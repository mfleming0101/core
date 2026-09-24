const std = @import("std");
const core = @import("core");

const Cpu = core.arm.Processor(.{ .cores = &.{.m0plus}, .Bus = core.memory.Regions });

const movs_r0_0x20: u16 = 0x2020;
const ldr_r0_r0: u16 = 0x6800;
const b_over_next: u16 = 0xe000;
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

test "step runs one instruction at a time and reports what each one was, cost and did" {
    word(0x0, 0x1000);
    word(0x4, 0x8 | 1);
    code(0x8, &.{
        movs_r0_0x20,
        ldr_r0_r0,
        b_over_next,
        bkpt_0,
        bkpt_0,
    });
    word(0x20, 0x1234_5678);

    var memory = try core.memory.Regions.adopt(&entries);
    var cpu = Cpu.init(&memory, .m0plus, .{});

    const first = cpu.step();
    try std.testing.expectEqual(@as(u32, 0x8), first.address);
    try std.testing.expectEqual(@as(?core.arm.Class, .data_processing), first.class);
    try std.testing.expectEqual(@as(?u8, 1), first.cost);
    try std.testing.expectEqual(@as(u8, 1), first.charged);
    try std.testing.expectEqual(@as(u32, 0x20), cpu.state.r[0]);

    const second = cpu.step();
    try std.testing.expectEqual(@as(?core.arm.Class, .load), second.class);
    try std.testing.expectEqual(@as(?u8, 2), second.cost);
    try std.testing.expect(second.sequential);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), cpu.state.r[0]);

    const third = cpu.step();
    try std.testing.expectEqual(@as(?core.arm.Class, .branch), third.class);
    try std.testing.expectEqual(@as(?u8, 2), third.cost);
    try std.testing.expectEqual(@as(u32, 0x10), cpu.state.pc);

    const fourth = cpu.step();
    try std.testing.expect(!fourth.sequential);
    try std.testing.expectEqual(@as(?core.arm.Stop, .breakpoint), fourth.stop);

    try std.testing.expectEqual(@as(u64, 3), cpu.instructions);
    try std.testing.expectEqual(@as(u64, 5), cpu.cycles);
}
