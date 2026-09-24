const std = @import("std");
const core = @import("core");

const firmware = @embedFile("crc.elf");

const flat = core.riscv.spec(.esp32c3).flat;

const Cpu = core.riscv.Processor(.{ .cores = &.{.esp32c3}, .Bus = core.memory.Regions });

const Board = struct {
    flash: [64 * 1024]u8 = @splat(0),
    ram: [8 * 1024]u8 = @splat(0),
    entries: [2]core.memory.Regions.Entry = undefined,
    memory: core.memory.Regions = undefined,

    fn load(self: *Board) !void {
        self.entries = .{
            .{ .memory = .{ .base = flat.flash_base, .bytes = &self.flash, .writable = false } },
            .{ .memory = .{ .base = flat.ram_base, .bytes = &self.ram, .writable = true } },
        };
        self.memory = try core.memory.Regions.adopt(&self.entries);
        try core.memory.elf.load(firmware, &self.memory);
    }
};

var board: Board = .{};

test "an ESP32-C3 runs the same CRC-32 firmware to its EBREAK and leaves the checksum of \"123456789\" in a0" {
    try board.load();
    var cpu = Cpu.init(&board.memory, .esp32c3, .{});

    const ran = cpu.run(.{ .instructions = 10_000 });

    try std.testing.expectEqual(@as(?core.riscv.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(@as(core.riscv.Ended, .stopped), ran.ended);
    try std.testing.expectEqual(@as(u32, 0xcbf4_3926), cpu.state.x[10]);
}
