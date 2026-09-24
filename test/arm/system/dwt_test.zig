const std = @import("std");
const dwt = @import("../../../src/arm/system/dwt.zig");

fn enabled(block: *dwt.Dwt, cycles: u64) void {
    _ = block.writeRegister(dwt.ctrl, dwt.cyccntena, cycles);
    block.retime(cycles, true);
}

test "DWT_CTRL reports a cycle counter, no comparators, and no trace, C1.8.7" {
    var block = dwt.Dwt.init(true);
    try std.testing.expectEqual(@as(u32, 0x0d00_0000), block.readRegister(dwt.ctrl, 0).?);
    _ = block.writeRegister(dwt.ctrl, 0xffff_ffff, 0);
    try std.testing.expectEqual(@as(u32, 0x0d00_0001), block.readRegister(dwt.ctrl, 0).?);
}

test "CYCCNT counts the cycles the core charged while it was enabled, C1.8.3" {
    var block = dwt.Dwt.init(true);
    try std.testing.expectEqual(@as(u32, 0), block.readRegister(dwt.cyccnt, 100).?);
    enabled(&block, 100);
    try std.testing.expectEqual(@as(u32, 40), block.readRegister(dwt.cyccnt, 140).?);
    try std.testing.expectEqual(@as(u32, 900), block.readRegister(dwt.cyccnt, 1000).?);
}

test "CYCCNT freezes when either enable is cleared and resumes without a jump, C1.8.3" {
    var block = dwt.Dwt.init(true);
    enabled(&block, 100);
    _ = block.writeRegister(dwt.ctrl, 0, 200);
    block.retime(200, true);
    try std.testing.expectEqual(@as(u32, 100), block.readRegister(dwt.cyccnt, 5000).?);
    enabled(&block, 5000);
    try std.testing.expectEqual(@as(u32, 110), block.readRegister(dwt.cyccnt, 5010).?);
    block.retime(5010, false);
    try std.testing.expectEqual(@as(u32, 110), block.readRegister(dwt.cyccnt, 9000).?);
    block.retime(9000, true);
    try std.testing.expectEqual(@as(u32, 115), block.readRegister(dwt.cyccnt, 9005).?);
}

test "writing CYCCNT restarts the count from the value written, C1.8.3" {
    var block = dwt.Dwt.init(true);
    enabled(&block, 100);
    _ = block.writeRegister(dwt.cyccnt, 7, 150);
    try std.testing.expectEqual(@as(u32, 7), block.readRegister(dwt.cyccnt, 150).?);
    try std.testing.expectEqual(@as(u32, 17), block.readRegister(dwt.cyccnt, 160).?);
}

test "CYCCNT wraps at 32 bits rather than saturating, C1.8.3" {
    var block = dwt.Dwt.init(true);
    enabled(&block, 0);
    _ = block.writeRegister(dwt.cyccnt, 0xffff_fffe, 0);
    try std.testing.expectEqual(@as(u32, 1), block.readRegister(dwt.cyccnt, 3).?);
}

test "the block answers every word it holds and nothing beyond it" {
    var block = dwt.Dwt.init(true);
    try std.testing.expectEqual(@as(u32, 0), block.readRegister(0x1c, 0).?);
    try std.testing.expectEqual(@as(u32, 0), block.readRegister(dwt.size - 4, 0).?);
    try std.testing.expectEqual(@as(?u32, null), block.readRegister(dwt.size, 0));
    try std.testing.expectEqual(@as(?u32, null), block.readRegister(2, 0));
    try std.testing.expect(!block.writeRegister(dwt.size, 0, 0));
}

test "an ARMv6-M core has no cycle counter, so the whole block reads zero, C1.7" {
    var block = dwt.Dwt.init(false);
    try std.testing.expectEqual(@as(u32, 0), block.readRegister(dwt.ctrl, 0).?);
    _ = block.writeRegister(dwt.ctrl, dwt.cyccntena, 0);
    block.retime(0, true);
    try std.testing.expectEqual(@as(u32, 0), block.readRegister(dwt.ctrl, 0).?);
    try std.testing.expectEqual(@as(u32, 0), block.readRegister(dwt.cyccnt, 5000).?);
}
