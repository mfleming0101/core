const std = @import("std");
const register = @import("../../register.zig");
const nvic = @import("../../../src/arm/system/nvic.zig");

fn registersOf(comptime priority_bits: u4) [3]register.Register {
    const lanes = comptime nvic.lanesOf(priority_bits);
    return .{
        .{ .name = "ISER", .offset = nvic.iser, .reset = 0, .write_mask = 0xffff_ffff },
        .{ .name = "IPR0", .offset = nvic.ipr, .reset = 0, .write_mask = lanes },
        .{ .name = "IPR59", .offset = nvic.ipr + 0xec, .reset = 0, .write_mask = lanes },
    };
}

test "ISER and ICER read the same enable set, ISER sets, ICER clears, and the priority words keep the implemented bits of each byte, B3.4.4 B3.4.5 B3.4.9" {
    inline for (.{ 2, 4 }, .{ 0xc0c0_c0c0, 0xf0f0_f0f0 }) |bits, lanes| {
        var block = nvic.Nvic.init(bits, nvic.lines);
        try std.testing.expect(register.check(&block, &registersOf(bits)) == null);
        block.reset();
        try std.testing.expect(block.writeRegister(nvic.iser, 0x22));
        try std.testing.expect(block.writeRegister(nvic.iser, 0x01));
        try std.testing.expectEqual(@as(?u32, 0x23), block.readRegister(nvic.icer));
        try std.testing.expect(block.writeRegister(nvic.icer, 0x20));
        try std.testing.expectEqual(@as(?u32, 0x03), block.readRegister(nvic.iser));
        try std.testing.expect(block.writeRegister(nvic.ipr + 4, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, lanes), block.readRegister(nvic.ipr + 4));
        try std.testing.expectEqual(@as(u8, lanes & 0xff), block.priority(6));
        try std.testing.expectEqual(@as(u8, 0), block.priority(3));
        try std.testing.expect(block.readRegister(nvic.ipr + 2) == null);
        try std.testing.expect(!block.writeRegister(nvic.ipr + 2, 1));
    }
}

test "the words of a bank that no interrupt line reaches read as zero and ignore writes rather than faulting, B3.4.1" {
    var block = nvic.Nvic.init(4, nvic.lines);
    for ([_]u32{ nvic.iser + 0x20, nvic.icer + 0x20, nvic.ispr + 0x20, nvic.icpr + 0x20, nvic.iabr + 0x20, nvic.itns + 0x20, nvic.ipr + 0xf0, nvic.size - 4 }) |offset| {
        try std.testing.expectEqual(@as(?u32, 0), block.readRegister(offset));
        try std.testing.expect(block.writeRegister(offset, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, 0), block.readRegister(offset));
    }
    try std.testing.expectEqual(@as(?u32, 0), block.readRegister(nvic.iser));
    try std.testing.expect(block.writeRegister(nvic.iser + 0x1c, 0xffff_ffff));
    try std.testing.expectEqual(@as(?u32, 0x0000_ffff), block.readRegister(nvic.iser + 0x1c));
    try std.testing.expectEqual(@as(?u32, 0), block.readRegister(nvic.iser + 0x18));
}

test "the eight enable words cover two hundred and forty lines, and the priority words reach the last of them" {
    var block = nvic.Nvic.init(4, nvic.lines);
    try std.testing.expect(block.writeRegister(nvic.iser + 0x18, 1 << 20));
    try std.testing.expectEqual(@as(?u32, 1 << 20), block.readRegister(nvic.icer + 0x18));
    try std.testing.expectEqual(@as(nvic.Lines, 1) << 212, block.enabled);
    try std.testing.expect(block.writeRegister(nvic.ipr + 0xec, 0xffff_ffff));
    try std.testing.expectEqual(@as(u8, 0xf0), block.priority(239));
}

test "a part with fewer lines than the library carries marks only the bits and priority bytes of its lines implemented, v7-M B3.4.2, v8-M B12.2 RSGCR D1.2.185" {
    const block = nvic.Nvic.init(4, 34);
    try std.testing.expectEqual((@as(nvic.Lines, 1) << 34) - 1, block.present());
    for ([_]u32{ nvic.iser, nvic.icer, nvic.ispr, nvic.icpr, nvic.iabr, nvic.itns }) |bank| {
        try std.testing.expectEqual(@as(u32, 0xffff_ffff), block.implemented(bank));
        try std.testing.expectEqual(@as(u32, 0x3), block.implemented(bank + 4));
        try std.testing.expectEqual(@as(u32, 0), block.implemented(bank + 8));
    }
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), block.implemented(nvic.ipr + 28));
    try std.testing.expectEqual(@as(u32, 0x0000_ffff), block.implemented(nvic.ipr + 32));
    try std.testing.expectEqual(@as(u32, 0), block.implemented(nvic.ipr + 36));
    const full = nvic.Nvic.init(4, nvic.lines);
    try std.testing.expectEqual(~@as(nvic.Lines, 0), full.present());
    try std.testing.expectEqual(@as(u32, 0x0000_ffff), full.implemented(nvic.iser + 0x1c));
}
