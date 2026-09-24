const std = @import("std");
const core = @import("core");

const firmware = @embedFile("crc.elf");

const Cpu = core.arm.Processor(.{ .cores = &.{.m0plus}, .Bus = core.memory.Regions });

const Board = struct {
    flash: [64 * 1024]u8 = @splat(0),
    ram: [8 * 1024]u8 = @splat(0),
    entries: [2]core.memory.Regions.Entry = undefined,
    memory: core.memory.Regions = undefined,

    fn load(self: *Board) !void {
        self.entries = .{
            .{ .memory = .{ .base = 0, .bytes = &self.flash, .writable = false } },
            .{ .memory = .{ .base = 0x2000_0000, .bytes = &self.ram, .writable = true } },
        };
        self.memory = try core.memory.Regions.adopt(&self.entries);
        try core.memory.elf.load(firmware, &self.memory);
    }
};

var board: Board = .{};

test "a Cortex-M0+ runs the CRC-32 firmware to its breakpoint and leaves the checksum of \"123456789\" in r0" {
    try board.load();
    var cpu = Cpu.init(&board.memory, .m0plus, .{});

    const ran = cpu.run(.{ .instructions = 10_000 });

    try std.testing.expectEqual(@as(?core.arm.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(@as(core.arm.Ended, .stopped), ran.ended);
    try std.testing.expectEqual(@as(u64, 656), ran.instructions);
    try std.testing.expectEqual(@as(u32, 0xcbf4_3926), cpu.state.r[0]);
}

test "the same run keeps a trace, and core.arm.trace renders its last records" {
    try board.load();
    var records: [16]core.arm.trace.Record = undefined;
    var cpu = Cpu.init(&board.memory, .m0plus, try .init(&records));

    _ = cpu.run(.{ .instructions = 10_000 });

    var text: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&text);
    try core.arm.trace.writeLast(&out, &cpu.trace, 2, cpu.groups());
    try std.testing.expectEqualStrings(
        \\at    741  pc=00000036 code=43c0 mvns r0, r0 ; r0=cbf43926 xpsr=a1000000
        \\at    742  pc=00000038 code=be00 bkpt #0
        \\
    , out.buffered());
}
