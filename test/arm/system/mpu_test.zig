const std = @import("std");
const mpu = @import("../../../src/arm/system/mpu.zig");
const Unit = mpu.Mpu(8);

fn v8() Unit {
    return .init(8, true, false);
}

fn v81() Unit {
    return .init(8, true, true);
}

fn v7() Unit {
    return .init(8, false, false);
}

test "MPU_TYPE names the regions the core has, and a core without one reads zero and ignores writes, D1.2.176" {
    var block = v8();
    try std.testing.expectEqual(@as(u32, 8 << 8), block.readRegister(mpu.mpu_type).?);
    try std.testing.expect(block.writeRegister(mpu.mpu_type, 0xffff_ffff));
    try std.testing.expectEqual(@as(u32, 8 << 8), block.readRegister(mpu.mpu_type).?);
    var absent: Unit = .init(0, true, false);
    var offset = mpu.mpu_type;
    while (offset <= mpu.last) : (offset += 4) {
        try std.testing.expectEqual(@as(u32, 0), absent.readRegister(offset).?);
        try std.testing.expect(absent.writeRegister(offset, 0xffff_ffff));
    }
    try std.testing.expectEqual(@as(?u32, null), absent.readRegister(mpu.last + 4));
    try std.testing.expectEqual(@as(?u32, null), block.readRegister(mpu.ctrl + 2));
}

test "a part with fewer regions than the unit holds names its own count in MPU_TYPE, and the regions beyond it never match, D1.2.176 B10.1" {
    var block: mpu.Mpu(16) = .init(12, true, false);
    try std.testing.expectEqual(@as(u32, 12 << 8), block.readRegister(mpu.mpu_type).?);
    try std.testing.expect(block.writeRegister(mpu.rnr, 0xff));
    try std.testing.expectEqual(@as(u32, 15), block.readRegister(mpu.rnr).?);
    try std.testing.expect(block.writeRegister(mpu.rnr, 12));
    try std.testing.expect(block.writeRegister(mpu.rbar, 0x2000_0000));
    try std.testing.expect(block.writeRegister(mpu.rlar, 0x2000_ffe1));
    try std.testing.expect(!block.permits(0x2000_0000, true, .read));
    try std.testing.expect(block.writeRegister(mpu.rnr, 11));
    try std.testing.expect(block.writeRegister(mpu.rbar, 0x2000_0000));
    try std.testing.expect(block.writeRegister(mpu.rlar, 0x2000_ffe1));
    try std.testing.expect(block.permits(0x2000_0000, true, .read));
}

test "MPU_CTRL keeps only the three bits it defines, D1.2.168" {
    var block = v8();
    try std.testing.expect(block.writeRegister(mpu.ctrl, 0xffff_ffff));
    try std.testing.expectEqual(mpu.enable | mpu.hfnmiena | mpu.privdefena, block.readRegister(mpu.ctrl).?);
    try std.testing.expect(block.enabled());
    try std.testing.expect(block.writeRegister(mpu.ctrl, 0));
    try std.testing.expect(!block.enabled());
}

test "the region number selects which base and limit the registers reach, D1.2.175" {
    var block = v8();
    try std.testing.expect(block.writeRegister(mpu.rnr, 5));
    try std.testing.expectEqual(@as(u32, 5), block.readRegister(mpu.rnr).?);
    try std.testing.expect(block.writeRegister(mpu.rbar, 0x2000_0001));
    try std.testing.expect(block.writeRegister(mpu.rlar, 0x2000_ffe1));
    try std.testing.expectEqual(@as(u32, 0x2000_0001), block.base[5]);
    try std.testing.expectEqual(@as(u32, 0x2000_ffe1), block.limit[5]);
    try std.testing.expect(block.writeRegister(mpu.rnr, 2));
    try std.testing.expectEqual(@as(u32, 0), block.readRegister(mpu.rbar).?);
    try std.testing.expect(block.writeRegister(mpu.rnr, 5));
    try std.testing.expectEqual(@as(u32, 0x2000_0001), block.readRegister(mpu.rbar).?);
}

test "the PMSAv8 alias registers reach the three regions beside the selected one, D1.2.172 D1.2.174" {
    var block = v8();
    try std.testing.expect(block.writeRegister(mpu.rnr, 5));
    try std.testing.expect(block.writeRegister(mpu.alias_first, 0x1111_1100));
    try std.testing.expect(block.writeRegister(mpu.alias_first + 8, 0x2222_2200));
    try std.testing.expect(block.writeRegister(mpu.alias_last, 0x3333_3300));
    try std.testing.expectEqual(@as(u32, 0x1111_1100), block.base[5]);
    try std.testing.expectEqual(@as(u32, 0x2222_2200), block.base[6]);
    try std.testing.expectEqual(@as(u32, 0x3333_3300), block.limit[7]);
    try std.testing.expectEqual(@as(u32, 0x2222_2200), block.readRegister(mpu.alias_first + 8).?);
}

test "a PMSAv7 base register write can name the region it means, B3.5.8" {
    var block = v7();
    try std.testing.expect(block.writeRegister(mpu.rbar, 0x2000_0000 | 0x10 | 6));
    try std.testing.expectEqual(@as(u32, 6), block.readRegister(mpu.rnr).?);
    try std.testing.expectEqual(@as(u32, 0x2000_0000), block.base[6]);
    try std.testing.expect(block.writeRegister(mpu.rbar, 0x3000_0000));
    try std.testing.expectEqual(@as(u32, 0x3000_0000), block.base[6]);
    try std.testing.expectEqual(@as(u32, 6), block.readRegister(mpu.rnr).?);
}

test "a PMSAv7 base register read carries the selected region number, B3.5.8" {
    var block = v7();
    try std.testing.expect(block.writeRegister(mpu.rnr, 3));
    try std.testing.expect(block.writeRegister(mpu.rbar, 0x2000_0000));
    try std.testing.expectEqual(@as(u32, 0x2000_0003), block.readRegister(mpu.rbar).?);
    try std.testing.expect(block.writeRegister(mpu.rnr, 0));
    try std.testing.expectEqual(@as(u32, 0), block.readRegister(mpu.rbar).?);
    var eight = v8();
    try std.testing.expect(eight.writeRegister(mpu.rnr, 3));
    try std.testing.expect(eight.writeRegister(mpu.rbar, 0x2000_0000));
    try std.testing.expectEqual(@as(u32, 0x2000_0000), eight.readRegister(mpu.rbar).?);
}

test "the memory attribute indirection registers belong to PMSAv8 alone, D1.2.169" {
    var eight = v8();
    try std.testing.expect(eight.writeRegister(mpu.mair0, 0x4444_4444));
    try std.testing.expectEqual(@as(u32, 0x4444_4444), eight.readRegister(mpu.mair0).?);
    var seven = v7();
    try std.testing.expect(seven.writeRegister(mpu.mair0, 0x4444_4444));
    try std.testing.expectEqual(@as(u32, 0), seven.readRegister(mpu.mair0).?);
}

fn region(block: *Unit, n: u32, base: u32, limit: u32, attributes: u32) void {
    _ = block.writeRegister(mpu.rnr, n);
    _ = block.writeRegister(mpu.rbar, base | attributes);
    _ = block.writeRegister(mpu.rlar, limit | mpu.region_enable);
}

test "a PMSAv8 region runs from its base to its limit inclusive, B10.1" {
    var block = v8();
    _ = block.writeRegister(mpu.ctrl, mpu.enable);
    region(&block, 0, 0x2000_0000, 0x2000_0fe0, mpu.unprivileged);
    try std.testing.expect(!block.permits(0x1fff_ffff, true, .read));
    try std.testing.expect(block.permits(0x2000_0000, true, .read));
    try std.testing.expect(block.permits(0x2000_0fff, true, .read));
    try std.testing.expect(!block.permits(0x2000_1000, true, .read));
}

test "the base register carries the permissions the region grants, D1.2.171" {
    var block = v8();
    _ = block.writeRegister(mpu.ctrl, mpu.enable);
    region(&block, 0, 0x2000_0000, 0x2000_0fe0, 0);
    try std.testing.expect(block.permits(0x2000_0000, true, .write));
    try std.testing.expect(!block.permits(0x2000_0000, false, .read));
    region(&block, 0, 0x2000_0000, 0x2000_0fe0, mpu.unprivileged | mpu.read_only);
    try std.testing.expect(block.permits(0x2000_0000, false, .read));
    try std.testing.expect(!block.permits(0x2000_0000, false, .write));
    try std.testing.expect(!block.permits(0x2000_0000, true, .write));
    region(&block, 0, 0x2000_0000, 0x2000_0fe0, mpu.unprivileged | mpu.execute_never);
    try std.testing.expect(block.permits(0x2000_0000, true, .read));
    try std.testing.expect(!block.permits(0x2000_0000, true, .fetch));
}

test "the Armv8.1-M limit register can refuse privileged fetches alone, D1.2.173" {
    var block = v81();
    _ = block.writeRegister(mpu.ctrl, mpu.enable);
    region(&block, 0, 0x2000_0000, 0x2000_0fe0 | mpu.privileged_never, mpu.unprivileged);
    try std.testing.expect(!block.permits(0x2000_0000, true, .fetch));
    try std.testing.expect(block.permits(0x2000_0000, false, .fetch));
    try std.testing.expect(block.permits(0x2000_0000, true, .read));
    try std.testing.expect(block.permits(0x2000_0000, true, .write));
    var earlier = v8();
    _ = earlier.writeRegister(mpu.ctrl, mpu.enable);
    region(&earlier, 0, 0x2000_0000, 0x2000_0fe0 | mpu.privileged_never, mpu.unprivileged);
    try std.testing.expect(earlier.permits(0x2000_0000, true, .fetch));
}

test "an address no region covers is open to privileged code only with PRIVDEFENA, B10.1" {
    var block = v8();
    _ = block.writeRegister(mpu.ctrl, mpu.enable);
    region(&block, 0, 0x2000_0000, 0x2000_0fe0, mpu.unprivileged);
    try std.testing.expect(!block.permits(0x0800_0000, true, .read));
    try std.testing.expect(!block.permits(0x0800_0000, false, .read));
    _ = block.writeRegister(mpu.ctrl, mpu.enable | mpu.privdefena);
    try std.testing.expect(block.permits(0x0800_0000, true, .read));
    try std.testing.expect(!block.permits(0x0800_0000, false, .read));
}

test "an address two enabled regions cover is refused, B10.1" {
    var block = v8();
    _ = block.writeRegister(mpu.ctrl, mpu.enable | mpu.privdefena);
    region(&block, 0, 0x2000_0000, 0x2000_0fe0, mpu.unprivileged);
    region(&block, 1, 0x2000_0800, 0x2000_1fe0, mpu.unprivileged);
    try std.testing.expect(block.permits(0x2000_0000, true, .read));
    try std.testing.expect(block.permits(0x2000_1000, true, .read));
    try std.testing.expect(!block.permits(0x2000_0800, true, .read));
}

test "a disabled region covers nothing, D1.2.173" {
    var block = v8();
    _ = block.writeRegister(mpu.ctrl, mpu.enable);
    _ = block.writeRegister(mpu.rnr, 0);
    _ = block.writeRegister(mpu.rbar, 0x2000_0000 | mpu.unprivileged);
    _ = block.writeRegister(mpu.rlar, 0x2000_0fe0);
    try std.testing.expect(!block.permits(0x2000_0000, true, .read));
    _ = block.writeRegister(mpu.rlar, 0x2000_0fe0 | mpu.region_enable);
    try std.testing.expect(block.permits(0x2000_0000, true, .read));
}

fn sized(block: *Unit, n: u32, base: u32, power: u32, attributes: u32) void {
    _ = block.writeRegister(mpu.rnr, n);
    _ = block.writeRegister(mpu.rbar, base);
    _ = block.writeRegister(mpu.rlar, attributes | (power << mpu.size_shift) | mpu.region_enable);
}

test "a PMSAv7 region covers a power of two from a base aligned to it, B3.5.3" {
    var block = v7();
    _ = block.writeRegister(mpu.ctrl, mpu.enable);
    sized(&block, 0, 0x2000_0000, 11, 3 << mpu.ap_shift);
    try std.testing.expect(!block.permits(0x1fff_ffff, true, .read));
    try std.testing.expect(block.permits(0x2000_0000, true, .read));
    try std.testing.expect(block.permits(0x2000_0fff, true, .read));
    try std.testing.expect(!block.permits(0x2000_1000, true, .read));
}

test "the PMSAv7 access permission field says what each privilege may do, B3.5.9" {
    var block = v7();
    _ = block.writeRegister(mpu.ctrl, mpu.enable);
    for ([_]struct { ap: u32, pr: bool, pw: bool, ur: bool, uw: bool }{
        .{ .ap = 0, .pr = false, .pw = false, .ur = false, .uw = false },
        .{ .ap = 1, .pr = true, .pw = true, .ur = false, .uw = false },
        .{ .ap = 2, .pr = true, .pw = true, .ur = true, .uw = false },
        .{ .ap = 3, .pr = true, .pw = true, .ur = true, .uw = true },
        .{ .ap = 4, .pr = false, .pw = false, .ur = false, .uw = false },
        .{ .ap = 5, .pr = true, .pw = false, .ur = false, .uw = false },
        .{ .ap = 6, .pr = true, .pw = false, .ur = true, .uw = false },
        .{ .ap = 7, .pr = true, .pw = false, .ur = true, .uw = false },
    }) |case| {
        sized(&block, 0, 0x2000_0000, 11, case.ap << mpu.ap_shift);
        try std.testing.expectEqual(case.pr, block.permits(0x2000_0000, true, .read));
        try std.testing.expectEqual(case.pw, block.permits(0x2000_0000, true, .write));
        try std.testing.expectEqual(case.ur, block.permits(0x2000_0000, false, .read));
        try std.testing.expectEqual(case.uw, block.permits(0x2000_0000, false, .write));
    }
}

test "a set subregion disable bit takes its eighth out of the region, B3.5.9" {
    var block = v7();
    _ = block.writeRegister(mpu.ctrl, mpu.enable);
    sized(&block, 0, 0x2000_0000, 11, (3 << mpu.ap_shift) | (0x22 << mpu.srd_shift));
    try std.testing.expect(block.permits(0x2000_0000, true, .read));
    try std.testing.expect(!block.permits(0x2000_0200, true, .read));
    try std.testing.expect(block.permits(0x2000_0400, true, .read));
    try std.testing.expect(!block.permits(0x2000_0bff, true, .read));
    try std.testing.expect(block.permits(0x2000_0c00, true, .read));
}

test "a region below 256 bytes has no subregions to disable, B3.5.9" {
    var block = v7();
    _ = block.writeRegister(mpu.ctrl, mpu.enable);
    sized(&block, 0, 0x2000_0000, 6, (3 << mpu.ap_shift) | (0xff << mpu.srd_shift));
    try std.testing.expect(block.permits(0x2000_0000, true, .read));
    try std.testing.expect(block.permits(0x2000_007f, true, .read));
    try std.testing.expect(!block.permits(0x2000_0080, true, .read));
}

test "the highest numbered PMSAv7 region that covers an address is the one that answers, B3.5.3" {
    var block = v7();
    _ = block.writeRegister(mpu.ctrl, mpu.enable);
    sized(&block, 0, 0x2000_0000, 11, 3 << mpu.ap_shift);
    sized(&block, 4, 0x2000_0000, 9, 5 << mpu.ap_shift);
    try std.testing.expect(!block.permits(0x2000_0000, true, .write));
    try std.testing.expect(block.permits(0x2000_0400, true, .write));
}

test "the PMSAv7 execute-never bit refuses fetches and leaves loads alone, B3.5.9" {
    var block = v7();
    _ = block.writeRegister(mpu.ctrl, mpu.enable);
    sized(&block, 0, 0x2000_0000, 11, (3 << mpu.ap_shift) | (@as(u32, 1) << mpu.never_shift));
    try std.testing.expect(block.permits(0x2000_0000, true, .read));
    try std.testing.expect(!block.permits(0x2000_0000, true, .fetch));
    try std.testing.expect(block.permits(0x2000_0000, true, .vector));
}

test "MPU_RASR keeps only the fields PMSAv7 defines and MPU_RLAR keeps every bit, v7-M B3.5.9 and v8-M D1.2.173" {
    var seven = v7();
    try std.testing.expect(seven.writeRegister(mpu.rlar, 0xffff_ffff));
    try std.testing.expectEqual(@as(u32, 0x173f_ff3f), seven.readRegister(mpu.rlar).?);
    var eight = v8();
    try std.testing.expect(eight.writeRegister(mpu.rlar, 0xffff_ffff));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), eight.readRegister(mpu.rlar).?);
}
