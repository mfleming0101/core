const std = @import("std");
const core = @import("core");

const Cpu = core.arm.Processor(.{ .cores = &.{.m0plus}, .Bus = core.memory.Regions });

const movs_r0_100: u16 = 0x2064;
const subs_r0_1: u16 = 0x3801;
const bne_back_to_subs: u16 = 0xd1fd;
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

fn countdown() !core.memory.Regions {
    word(0x0, 0x1000);
    word(0x4, 0x8 | 1);
    code(0x8, &.{
        movs_r0_100,
        subs_r0_1,
        bne_back_to_subs,
        bkpt_0,
    });
    return core.memory.Regions.adopt(&entries);
}

test "a run ends at its instruction budget, and the next run carries on where it left off" {
    var memory = try countdown();
    var cpu = Cpu.init(&memory, .m0plus, .{});

    const first = cpu.run(.{ .instructions = 50 });
    try std.testing.expectEqual(@as(core.arm.Ended, .budget), first.ended);
    try std.testing.expectEqual(@as(?core.arm.Stop, null), first.stop);
    try std.testing.expectEqual(@as(u64, 50), first.instructions);

    const rest = cpu.run(.{ .instructions = 1_000 });
    try std.testing.expectEqual(@as(core.arm.Ended, .stopped), rest.ended);
    try std.testing.expectEqual(@as(?core.arm.Stop, .breakpoint), rest.stop);
    try std.testing.expectEqual(@as(u64, 201), first.instructions + rest.instructions);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.r[0]);
}

test "a run ends at its cycle deadline, which is what a caller pacing the core against real time uses" {
    var memory = try countdown();
    var cpu = Cpu.init(&memory, .m0plus, .{});

    const paced = cpu.run(.{ .instructions = 1_000, .cycles = 60 });
    try std.testing.expectEqual(@as(core.arm.Ended, .deadline), paced.ended);
    try std.testing.expect(paced.cycles >= 60);
    try std.testing.expect(cpu.state.r[0] > 0);

    const rest = cpu.run(.{ .instructions = 1_000 });
    try std.testing.expectEqual(@as(?core.arm.Stop, .breakpoint), rest.stop);
    try std.testing.expectEqual(@as(u64, 201), cpu.instructions);
}

test "a breakpoint stops the run, and the next run continues past it" {
    var memory = try countdown();
    var cpu = Cpu.init(&memory, .m0plus, .{});
    code(0x8, &.{ 0xbe00, 0x2001, 0xbe00 });

    try std.testing.expectEqual(@as(?core.arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 0x8), cpu.state.pc);
    try std.testing.expectEqual(@as(?core.arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 0xc), cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 1), cpu.state.r[0]);
}
