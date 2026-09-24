const std = @import("std");
const core = @import("core");
const Timer = @import("timer_device.zig").Timer;

const firmware = @embedFile("timer.elf");

const flat = core.riscv.spec(.esp32c3).flat;

const Cpu = core.riscv.Processor(.{ .cores = &.{.esp32c3}, .Bus = core.memory.Regions });

var flash: [64 * 1024]u8 = @splat(0);
var ram: [8 * 1024]u8 = @splat(0);
var timer: Timer = .{ .line = 5 };
var entries = [_]core.memory.Regions.Entry{
    .{ .memory = .{ .base = flat.flash_base, .bytes = &flash, .writable = false } },
    .{ .memory = .{ .base = flat.ram_base, .bytes = &ram, .writable = true } },
    .{ .device = .{ .base = 0x6001_0000, .size = 0x10, .device = timer.device() } },
};

test "the same timer on interrupt matrix source 5 interrupts an ESP32-C3 five times" {
    var memory = try core.memory.Regions.adopt(&entries);
    try core.memory.elf.load(firmware, &memory);
    var cpu = Cpu.init(&memory, .esp32c3, .{});

    const ran = cpu.run(.{ .instructions = 100_000 });

    try std.testing.expectEqual(@as(?core.riscv.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(@as(u32, 5), cpu.state.x[10]);
    try std.testing.expectEqual(@as(u32, 5), timer.fired);
    try std.testing.expectEqual(@as(u64, 5), cpu.irqs);
}
