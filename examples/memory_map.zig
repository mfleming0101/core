const std = @import("std");
const core = @import("core");

const Regions = core.memory.Regions;

const Cpu = core.arm.Processor(.{ .cores = &.{.m0plus}, .Bus = Regions });

const ldr_r1_literal: u16 = 0x4903;
const movs_r0_7: u16 = 0x2007;
const str_r0_r1: u16 = 0x6008;
const movs_r1_0: u16 = 0x2100;
const bkpt_0: u16 = 0xbe00;

var flash: [1024]u8 = @splat(0);
var ram: [1024]u8 = @splat(0);

test "a bus is regions of bytes at addresses: reads and writes land in them, and nothing answers between them" {
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = 0x2000_0000, .bytes = &ram, .writable = true } },
        .{ .memory = .{ .base = 0, .bytes = &flash, .writable = false } },
    };
    var memory = try Regions.adopt(&entries);

    try std.testing.expectEqual(@as(?void, {}), memory.poke(4, 0x2000_0010, 0xdead_beef));
    try std.testing.expectEqual(@as(?u32, 0xdead_beef), memory.peek(4, 0x2000_0010));
    try std.testing.expectEqual(@as(?u8, 0xef), memory.peek(1, 0x2000_0010));
    try std.testing.expectEqual(@as(u8, 0xef), ram[0x10]);

    try std.testing.expectEqual(@as(?void, null), memory.poke(4, 0x0, 1));
    try std.testing.expectEqual(@as(?u32, 0), memory.peek(4, 0x0));
    try std.testing.expectEqual(@as(?u32, null), memory.peek(4, 0x1000_0000));
    try std.testing.expectEqual(@as(?u32, null), memory.peek(4, 0x2000_0400));
}

test "adopt sorts the entries and refuses two that overlap" {
    var overlapping = [_]Regions.Entry{
        .{ .memory = .{ .base = 0, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = 0x200, .bytes = &ram, .writable = true } },
    };
    try std.testing.expectError(error.Overlaps, Regions.adopt(&overlapping));
}

test "the core's stores land in the same bytes the host reads, and a store to read-only memory is a fault" {
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = 0, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = 0x2000_0000, .bytes = &ram, .writable = true } },
    };
    std.mem.writeInt(u32, flash[0..4], 0x2000_0400, .little);
    std.mem.writeInt(u32, flash[4..8], 0x8 | 1, .little);
    for ([_]u16{
        ldr_r1_literal,
        movs_r0_7,
        str_r0_r1,
        movs_r1_0,
        str_r0_r1,
        bkpt_0,
    }, 0..) |h, i| std.mem.writeInt(u16, flash[0x8 + 2 * i ..][0..2], h, .little);
    std.mem.writeInt(u32, flash[0x18..0x1c], 0x2000_0020, .little);
    var memory = try Regions.adopt(&entries);
    var cpu = Cpu.init(&memory, .m0plus, .{}, .{});

    const ran = cpu.run(.{ .instructions = 100 });

    try std.testing.expectEqual(@as(?u32, 7), memory.peek(4, 0x2000_0020));
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, ram[0x20..0x24], .little));
    try std.testing.expectEqual(@as(?core.arm.Stop, .data_fault), ran.stop);
    try std.testing.expectEqual(@as(u32, 0x2000_0400), std.mem.readInt(u32, flash[0..4], .little));
}
