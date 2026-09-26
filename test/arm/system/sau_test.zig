const std = @import("std");
const sau = @import("../../../src/arm/system/sau.zig");

fn region(unit: *sau.Sau, n: u32, base: u32, limit: u32, flags: u32) void {
    _ = unit.writeRegister(sau.rnr, n);
    _ = unit.writeRegister(sau.rbar, base);
    _ = unit.writeRegister(sau.rlar, limit | flags);
}

test "SAU_TYPE reports the number of regions and does not take a write, D1.2.229" {
    var unit = sau.Sau.init(true, true, 8);
    try std.testing.expectEqual(@as(u32, sau.regions), unit.readRegister(sau.rtype).?);
    try std.testing.expect(unit.writeRegister(sau.rtype, 0));
    try std.testing.expectEqual(@as(u32, sau.regions), unit.readRegister(sau.rtype).?);
}

test "SAU_RNR selects which region SAU_RBAR and SAU_RLAR read, D1.2.228" {
    var unit = sau.Sau.init(true, true, 8);
    region(&unit, 0, 0x2000_0000, 0x2000_ffe0, sau.region_enable);
    region(&unit, 3, 0x3000_0000, 0x3000_ffe0, sau.region_enable);
    _ = unit.writeRegister(sau.rnr, 0);
    try std.testing.expectEqual(@as(u32, 0x2000_0000), unit.readRegister(sau.rbar).?);
    _ = unit.writeRegister(sau.rnr, 3);
    try std.testing.expectEqual(@as(u32, 0x3000_0000), unit.readRegister(sau.rbar).?);
    _ = unit.writeRegister(sau.rnr, 0x99);
    try std.testing.expectEqual(@as(u32, 1), unit.readRegister(sau.rnr).?);
}

test "a region is aligned to 32 bytes at both ends, D1.2.226 D1.2.227" {
    var unit = sau.Sau.init(true, true, 8);
    region(&unit, 0, 0x2000_001f, 0x2000_ff1c, sau.region_enable);
    try std.testing.expectEqual(@as(u32, 0x2000_0000), unit.readRegister(sau.rbar).?);
    try std.testing.expectEqual(@as(u32, 0x2000_ff01), unit.readRegister(sau.rlar).?);
    _ = unit.writeRegister(sau.ctrl, sau.enable);
    try std.testing.expect(unit.check(0x2000_0000, false, true).ns);
    try std.testing.expect(unit.check(0x2000_ff1f, false, true).ns);
    try std.testing.expect(!unit.check(0x2000_ff20, false, true).ns);
}

test "every address is Secure while the SAU is disabled, and Non-secure if ALLNS is set, E2.1.366" {
    var unit = sau.Sau.init(true, true, 8);
    try std.testing.expect(!unit.check(0x2000_0000, false, true).ns);
    _ = unit.writeRegister(sau.ctrl, sau.allns);
    try std.testing.expect(unit.check(0x2000_0000, false, true).ns);
    _ = unit.writeRegister(sau.ctrl, sau.allns | sau.enable);
    try std.testing.expect(!unit.check(0x2000_0000, false, true).ns);
}

test "an enabled region makes its addresses Non-secure and everything else stays Secure, E2.1.366" {
    var unit = sau.Sau.init(true, true, 8);
    region(&unit, 0, 0x2000_0000, 0x2000_ffe0, sau.region_enable);
    _ = unit.writeRegister(sau.ctrl, sau.enable);
    const inside = unit.check(0x2000_0004, false, true);
    try std.testing.expect(inside.ns);
    try std.testing.expect(!inside.nsc);
    try std.testing.expectEqual(@as(?u8, 0), inside.region);
    try std.testing.expect(!unit.check(0x2001_0000, false, true).ns);
    try std.testing.expectEqual(@as(?u8, null), unit.check(0x2001_0000, false, true).region);
    try std.testing.expect(unit.check(0x2000_ffff, false, true).ns);
    try std.testing.expect(!unit.check(0x2001_0000, false, true).ns);
}

test "a region marked NSC is Non-secure callable rather than Non-secure, E2.1.366" {
    var unit = sau.Sau.init(true, true, 8);
    region(&unit, 2, 0x1000_0000, 0x1000_0fe0, sau.region_enable | sau.region_nsc);
    _ = unit.writeRegister(sau.ctrl, sau.enable);
    const found = unit.check(0x1000_0000, false, true);
    try std.testing.expect(!found.ns);
    try std.testing.expect(found.nsc);
    try std.testing.expectEqual(@as(?u8, 2), found.region);
}

test "an address in two regions is Secure and reports no region, E2.1.366" {
    var unit = sau.Sau.init(true, true, 8);
    region(&unit, 0, 0x2000_0000, 0x2000_ffe0, sau.region_enable);
    region(&unit, 1, 0x2000_8000, 0x2001_ffe0, sau.region_enable);
    _ = unit.writeRegister(sau.ctrl, sau.enable);
    const both = unit.check(0x2000_8004, false, true);
    try std.testing.expect(!both.ns);
    try std.testing.expect(!both.nsc);
    try std.testing.expectEqual(@as(?u8, null), both.region);
    try std.testing.expectEqual(@as(?u8, 0), unit.check(0x2000_0004, false, true).region);
}

test "a disabled region is not scanned, D1.2.227" {
    var unit = sau.Sau.init(true, true, 8);
    region(&unit, 0, 0x2000_0000, 0x2000_ffe0, 0);
    _ = unit.writeRegister(sau.ctrl, sau.enable);
    try std.testing.expect(!unit.check(0x2000_0004, false, true).ns);
}

test "the blocks exempt from attribution follow the state that asked, E2.1.366" {
    var unit = sau.Sau.init(true, true, 8);
    region(&unit, 0, 0xe000_0000, 0xe00f_ffe0, sau.region_enable);
    _ = unit.writeRegister(sau.ctrl, sau.enable);
    for ([_]u32{ 0xe000_0000, 0xe000_e000, 0xe002_e000, 0xe004_0000, 0xe00f_f000 }) |address| {
        try std.testing.expect(!unit.check(address, false, true).ns);
        try std.testing.expect(unit.check(address, false, false).ns);
        try std.testing.expectEqual(@as(?u8, null), unit.check(address, false, true).region);
    }
}

test "an instruction fetch above 0xF0000000 is always Secure, E2.1.366" {
    var unit = sau.Sau.init(true, true, 8);
    _ = unit.writeRegister(sau.ctrl, sau.allns);
    try std.testing.expect(!unit.check(0xf000_0000, true, true).ns);
    try std.testing.expect(unit.check(0xf000_0000, false, true).ns);
}

test "a core without the Security Extension has no SAU and calls every address Non-secure, E2.1.366" {
    var unit = sau.Sau.init(false, false, 0);
    try std.testing.expectEqual(@as(?u32, null), unit.readRegister(sau.ctrl));
    try std.testing.expect(!unit.writeRegister(sau.ctrl, sau.enable));
    try std.testing.expect(unit.check(0x2000_0000, false, false).ns);
}

test "a part with four regions reads four in SAU_TYPE, and one with none keeps SAU_CTRL.ENABLE, SAU_RNR, SAU_RBAR and SAU_RLAR at zero, D1.2.229 D1.2.228, M33 TRM 1.3" {
    var four = sau.Sau.init(true, true, 4);
    try std.testing.expectEqual(@as(u32, 4), four.readRegister(sau.rtype).?);
    _ = four.writeRegister(sau.rnr, 7);
    try std.testing.expectEqual(@as(u32, 3), four.readRegister(sau.rnr).?);
    var none = sau.Sau.init(true, true, 0);
    try std.testing.expectEqual(@as(u32, 0), none.readRegister(sau.rtype).?);
    region(&none, 1, 0x2000_0000, 0x2000_ffe0, sau.region_enable);
    _ = none.writeRegister(sau.ctrl, sau.enable | sau.allns);
    try std.testing.expectEqual(@as(u32, sau.allns), none.readRegister(sau.ctrl).?);
    for ([_]u32{ sau.rnr, sau.rbar, sau.rlar }) |offset| {
        try std.testing.expectEqual(@as(u32, 0), none.readRegister(offset).?);
    }
    try std.testing.expect(none.check(0x2000_0000, false, true).ns);
}
