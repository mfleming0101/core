const std = @import("std");
const m7 = @import("../../../src/arm/system/m7.zig");
const Part = @import("../../../src/arm/system/core.zig").Part;

test "CM7_ITCMCR, CM7_DTCMCR and CM7_AHBPCR reset to what each part wires, keep SZ through any write and take only the enables, M7 TRM 3.3.6 3.3.7 Table 3-9 Table 3-10" {
    const part: Part = .{ .itcm = .{ .size = .kb64, .enabled = true }, .dtcm = .{ .size = .kb128, .enabled = true, .read_modify_write = true, .retry = true }, .ahbp = .{ .size = .mb64, .enabled = true } };
    var block: m7.Control = .init(part);
    try std.testing.expectEqual(@as(?u32, 0x39), block.readRegister(m7.itcmcr));
    try std.testing.expectEqual(@as(?u32, 0x47), block.readRegister(m7.dtcmcr));
    try std.testing.expectEqual(@as(?u32, 0x3), block.readRegister(m7.ahbpcr));
    try std.testing.expect(block.writeRegister(part, m7.itcmcr, 0));
    try std.testing.expect(block.writeRegister(part, m7.dtcmcr, 0));
    try std.testing.expect(block.writeRegister(part, m7.ahbpcr, 0));
    try std.testing.expectEqual(@as(?u32, 0x38), block.readRegister(m7.itcmcr));
    try std.testing.expectEqual(@as(?u32, 0x40), block.readRegister(m7.dtcmcr));
    try std.testing.expectEqual(@as(?u32, 0x2), block.readRegister(m7.ahbpcr));
    const other_part: Part = .{ .itcm = .{ .size = .mb16 }, .dtcm = .{ .size = .kb4 }, .ahbp = .{ .size = .mb512 } };
    var other: m7.Control = .init(other_part);
    try std.testing.expectEqual(@as(?u32, 0x78), other.readRegister(m7.itcmcr));
    try std.testing.expectEqual(@as(?u32, 0x18), other.readRegister(m7.dtcmcr));
    try std.testing.expectEqual(@as(?u32, 0x8), other.readRegister(m7.ahbpcr));
    try std.testing.expect(other.writeRegister(other_part, m7.itcmcr, 0xffff_ffff));
    try std.testing.expect(other.writeRegister(other_part, m7.ahbpcr, 0xffff_ffff));
    try std.testing.expectEqual(@as(?u32, 0x7f), other.readRegister(m7.itcmcr));
    try std.testing.expectEqual(@as(?u32, 0x9), other.readRegister(m7.ahbpcr));
    const bare: m7.Control = .init(.{});
    try std.testing.expectEqual(@as(?u32, 0), bare.readRegister(m7.itcmcr));
    try std.testing.expectEqual(@as(?u32, 0), bare.readRegister(m7.ahbpcr));
}

test "CM7_CACR holds FORCEWT and SIWT only with a data cache and ECCDIS only with ECC on a fitted cache, reading ECCDIS as one otherwise, M7 TRM 3.3.8 Table 3-11" {
    inline for (.{
        Part{ .data = .kb32, .instruction = .kb32, .ecc = true },
        Part{ .data = .kb32, .instruction = .kb32 },
        Part{ .instruction = .kb16, .ecc = true },
        Part{ .ecc = true },
    }, .{ 0, 0x2, 0, 0x2 }, .{ 0x7, 0x7, 0x2, 0x2 }, .{ 0, 0x2, 0, 0x2 }) |part, at_reset, all, none| {
        var block: m7.Control = .init(part);
        try std.testing.expectEqual(@as(?u32, at_reset), block.readRegister(m7.cacr));
        try std.testing.expect(block.writeRegister(part, m7.cacr, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, all), block.readRegister(m7.cacr));
        try std.testing.expect(block.writeRegister(part, m7.cacr, 0));
        try std.testing.expectEqual(@as(?u32, none), block.readRegister(m7.cacr));
    }
}

test "CM7_AHBSCR resets INITCOUNT to one and keeps its low sixteen bits, and CM7_ABFSR, with no asynchronous bus fault to record, reads zero, M7 TRM 3.3.9 3.3.12 Table 3-15" {
    var block: m7.Control = .init(.{});
    try std.testing.expectEqual(@as(?u32, 0x0000_0800), block.readRegister(m7.ahbscr));
    try std.testing.expect(block.writeRegister(.{}, m7.ahbscr, 0xffff_ffff));
    try std.testing.expectEqual(@as(?u32, 0x0000_ffff), block.readRegister(m7.ahbscr));
    try std.testing.expectEqual(@as(?u32, 0), block.readRegister(m7.abfsr));
    try std.testing.expect(block.writeRegister(.{}, m7.abfsr, 0xffff_ffff));
    try std.testing.expectEqual(@as(?u32, 0), block.readRegister(m7.abfsr));
}

test "IEBR0-1 and DEBR0-1 hold what software writes on a part with ECC and are RAZ/WI without, M7 TRM 3.3.10 3.3.11 Table 3-1" {
    const with_part: Part = .{ .data = .kb32, .instruction = .kb32, .ecc = true };
    const without_part: Part = .{ .data = .kb32, .instruction = .kb32 };
    var with: m7.Control = .init(with_part);
    var without: m7.Control = .init(without_part);
    inline for (.{ m7.iebr0, m7.iebr0 + 4, m7.debr0, m7.debr0 + 4 }) |offset| {
        try std.testing.expectEqual(@as(?u32, 0), with.readRegister(offset));
        try std.testing.expect(with.writeRegister(with_part, offset, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, 0xffff_ffff), with.readRegister(offset));
        try std.testing.expect(without.writeRegister(without_part, offset, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, 0), without.readRegister(offset));
    }
}

test "the words Table 3-1 reserves among the M7 control registers are refused, M7 TRM Table 3-1" {
    var block: m7.Control = .init(.{});
    inline for (.{ 0x14, 0x1c }) |offset| {
        try std.testing.expectEqual(@as(?u32, null), block.readRegister(offset));
        try std.testing.expect(!block.writeRegister(.{}, offset, 0));
    }
}
