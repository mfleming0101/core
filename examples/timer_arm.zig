const std = @import("std");
const core = @import("core");
const Timer = @import("timer_device.zig").Timer;

const firmware = @embedFile("timer.elf");

const Cpu = core.arm.Processor(.{ .cores = &.{.m0plus}, .Bus = core.memory.Regions });

var flash: [64 * 1024]u8 = @splat(0);
var ram: [8 * 1024]u8 = @splat(0);
var timer: Timer = .{ .line = 0 };
var entries = [_]core.memory.Regions.Entry{
    .{ .memory = .{ .base = 0, .bytes = &flash, .writable = false } },
    .{ .memory = .{ .base = 0x2000_0000, .bytes = &ram, .writable = true } },
    .{ .device = .{ .base = 0x4001_0000, .size = 0x10, .device = timer.device() } },
};

test "a timer device on the bus interrupts a Cortex-M0+ five times, and the program counts the interrupts" {
    var memory = try core.memory.Regions.adopt(&entries);
    try core.memory.elf.load(firmware, &memory);
    var cpu = Cpu.init(&memory, .m0plus, .{}, .{});

    const ran = cpu.run(.{ .instructions = 100_000 });

    try std.testing.expectEqual(@as(?core.arm.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(@as(u32, 5), cpu.state.r[0]);
    try std.testing.expectEqual(@as(u32, 5), timer.fired);
    try std.testing.expectEqual(@as(u64, 5), cpu.irqs);
    try std.testing.expect(cpu.cycles >= 500);
}
