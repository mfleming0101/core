const std = @import("std");
const core = @import("core");

const Cpu = core.riscv.Processor(.{ .cores = &.{.esp32c3}, .Bus = core.memory.Regions });

const reset = core.riscv.spec(.esp32c3).reset_pc;

const addi_a0_zero_1: u32 = 0x00100513;
const addi_a1_a0_2: u32 = 0x00250593;
const ebreak: u32 = 0x00100073;

var bytes: [4096]u8 = @splat(0);
var entries = [_]core.memory.Regions.Entry{
    .{ .memory = .{ .base = reset, .bytes = &bytes, .writable = true } },
};

fn code(at: u32, words: []const u32) void {
    for (words, 0..) |w, i| std.mem.writeInt(u32, bytes[at + 4 * i ..][0..4], w, .little);
}

test "three instructions at the ESP32-C3's reset address, and a hart that runs them to the ebreak" {
    code(0, &.{
        addi_a0_zero_1,
        addi_a1_a0_2,
        ebreak,
    });

    var memory = try core.memory.Regions.adopt(&entries);
    var cpu = Cpu.init(&memory, .esp32c3, .{});
    try std.testing.expectEqual(reset, cpu.state.pc);

    const ran = cpu.run(.{ .instructions = 100 });

    try std.testing.expectEqual(@as(?core.riscv.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(@as(u64, 2), ran.instructions);
    try std.testing.expectEqual(@as(u32, 1), cpu.state.x[10]);
    try std.testing.expectEqual(@as(u32, 3), cpu.state.x[11]);
    try std.testing.expectEqual(reset + 8, cpu.state.pc);
}
