const std = @import("std");
const register = @import("../../register.zig");
const scb = @import("../../../src/arm/system/scb.zig");
const Caches = @import("../../../src/arm/system/core.zig").Caches;

fn of(comptime c: anytype) scb.Scb {
    return fitted(c, .{});
}

fn fitted(comptime c: anytype, caches: Caches) scb.Scb {
    return .init(&struct {
        const profile: scb.Profile = scb.profileOf(c);
    }.profile, caches);
}

fn registersOf(comptime c: anytype) []const register.Register {
    return struct {
        const table: []const register.Register = blk: {
            const profile = scb.profileOf(c);
            var out: [scb.layout.len]register.Register = undefined;
            var n: usize = 0;
            for (scb.layout, 0..) |slot, i| {
                if (profile.present & (@as(u32, 1) << @intCast(i)) == 0) continue;
                out[n] = .{ .name = slot.name, .offset = slot.offset, .reset = profile.reset[i], .write_mask = profile.write_mask[i] };
                n += 1;
            }
            const frozen = out[0..n].*;
            break :blk &frozen;
        };
    }.table;
}

fn find(comptime c: anytype, name: []const u8) register.Register {
    for (registersOf(c)) |r| if (std.mem.eql(u8, r.name, name)) return r;
    unreachable;
}

test "every implemented register of the System Control Block resets and masks as its manual says, v6-M and v7-M B3.2.2, v8-M D1.1.11" {
    inline for (.{ .m0plus, .m4, .m7, .m23, .m33, .m55 }) |core| {
        var block = of(core);
        try std.testing.expect(register.check(&block, registersOf(core)) == null);
    }
}

test "the priority bytes of SHPR1, SHPR2 and SHPR3 keep only the implemented high bits of the core, v6-M B3.2.9 B3.2.10, v7-M B3.2.10 B3.2.11 B3.2.12" {
    inline for (.{ .m0plus, .m4 }, .{ 0xc000_0000, 0xf000_0000 }, .{ 0xc0c0_0000, 0xf0f0_00f0 }) |core, mask2, mask3| {
        try std.testing.expectEqual(@as(u32, mask2), find(core, "SHPR2").write_mask);
        try std.testing.expectEqual(@as(u32, mask3), find(core, "SHPR3").write_mask);
    }
    try std.testing.expectEqual(@as(u32, 0x00f0_f0f0), find(.m4, "SHPR1").write_mask);
}

test "CPUID reads the part number of the core and ignores writes, v6-M and v7-M B3.2.3, v8-M D1.2.16" {
    inline for (.{ .m0, .m0plus, .m1, .m23, .m3, .m4, .m7, .m33, .m55, .m85 }, .{ 0x410c_c200, 0x410c_c601, 0x410c_c210, 0x411c_d200, 0x410f_c231, 0x410f_c240, 0x411f_c272, 0x410f_d213, 0x411f_d221, 0x411f_d230 }) |core, id| {
        var block = of(core);
        try std.testing.expect(block.writeRegister(scb.cpuid, 0));
        try std.testing.expectEqual(@as(u32, id), block.readRegister(scb.cpuid).?);
    }
}

test "VTOR moves the vector table except on the cores that have none, v6-M and v7-M B3.2.5, v8-M D1.2.272" {
    inline for (.{ .m0plus, .m3, .m4, .m33 }) |core| {
        var block = of(core);
        try std.testing.expect(block.writeRegister(scb.vtor, 0x400));
        try std.testing.expectEqual(@as(u32, 0x400), block.readRegister(scb.vtor).?);
    }
    inline for (.{ .m0, .m1 }) |core| {
        var block = of(core);
        try std.testing.expect(block.writeRegister(scb.vtor, 0x400));
        try std.testing.expectEqual(@as(u32, 0), block.readRegister(scb.vtor).?);
    }
}

test "AIRCR reads back the key stat and takes PRIGROUP only from a write carrying the key, B3.2.6" {
    var block = of(.m4);
    try std.testing.expectEqual(scb.vectkeystat, block.readRegister(scb.aircr).?);
    try std.testing.expect(block.writeRegister(scb.aircr, 0x0000_0500));
    try std.testing.expectEqual(scb.vectkeystat, block.readRegister(scb.aircr).?);
    try std.testing.expect(block.writeRegister(scb.aircr, scb.vectkey << 16 | 0x0000_0504));
    try std.testing.expectEqual(scb.vectkeystat | 0x0000_0500, block.readRegister(scb.aircr).?);
}

test "CCR resets to the value of the core and keeps its reserved-as-one bits, the M7 STKALIGN among them, v6-M and v7-M B3.2.8, v8-M D1.2.9, M7 TRM 3.2" {
    inline for (.{ .m0plus, .m4, .m7, .m23, .m33 }, .{ 0x208, 0x200, 0x0004_0200, 0x209, 0x201 }) |core, at_reset| {
        var block = of(core);
        try std.testing.expectEqual(@as(u32, at_reset), block.readRegister(scb.ccr).?);
        try std.testing.expect(block.writeRegister(scb.ccr, 0));
        try std.testing.expectEqual(@as(u32, at_reset & ~@as(u32, if (core == .m4) 0x200 else 0)), block.readRegister(scb.ccr).?);
    }
}

test "the M7 resets CCR with BP set, which no write clears, and lets software set IC and DC only for the caches the part has, v7-M B3.2.8, M7 TRM 3.2 4.1" {
    var block = fitted(.m7, .{ .data = .kb32, .instruction = .kb32 });
    try std.testing.expectEqual(@as(u32, 0x0004_0200), block.readRegister(scb.ccr).?);
    try std.testing.expect(block.writeRegister(scb.ccr, 0x0003_0200));
    try std.testing.expectEqual(@as(u32, 0x0007_0200), block.readRegister(scb.ccr).?);
    try std.testing.expect(block.writeRegister(scb.ccr, 0x0000_0200));
    try std.testing.expectEqual(@as(u32, 0x0004_0200), block.readRegister(scb.ccr).?);
    var data_only = fitted(.m7, .{ .data = .kb4 });
    try std.testing.expect(data_only.writeRegister(scb.ccr, 0x0003_0200));
    try std.testing.expectEqual(@as(u32, 0x0005_0200), data_only.readRegister(scb.ccr).?);
    var none = of(.m7);
    try std.testing.expect(none.writeRegister(scb.ccr, 0x0003_0200));
    try std.testing.expectEqual(@as(u32, 0x0004_0200), none.readRegister(scb.ccr).?);
    var four = fitted(.m4, .{ .data = .kb32, .instruction = .kb32 });
    try std.testing.expect(four.writeRegister(scb.ccr, 0x0007_0200));
    try std.testing.expectEqual(@as(u32, 0x0000_0200), four.readRegister(scb.ccr).?);
}

test "CLIDR, CTR and CCSIDR describe the M7 caches and CSSELR.InD picks the data or the instruction CCSIDR, v7-M B4.8, M7 TRM 3.3.3 3.3.4 3.3.5" {
    var block = fitted(.m7, .{ .data = .kb32, .instruction = .kb32 });
    try std.testing.expectEqual(@as(u32, 0x0900_0003), block.readRegister(scb.clidr).?);
    try std.testing.expectEqual(@as(u32, 0x8303_c003), block.readRegister(scb.ctr).?);
    try std.testing.expectEqual(@as(u32, 0), block.readRegister(scb.csselr).?);
    try std.testing.expectEqual(@as(u32, 0xf01f_e019), block.readRegister(scb.ccsidr).?);
    try std.testing.expect(block.writeRegister(scb.csselr, 0xffff_ffff));
    try std.testing.expectEqual(@as(u32, 1), block.readRegister(scb.csselr).?);
    try std.testing.expectEqual(@as(u32, 0xf03f_e009), block.readRegister(scb.ccsidr).?);
    try std.testing.expect(block.writeRegister(scb.ccsidr, 0));
    try std.testing.expectEqual(@as(u32, 0xf03f_e009), block.readRegister(scb.ccsidr).?);
    try std.testing.expect(block.writeRegister(scb.csselr, 0));
    try std.testing.expectEqual(@as(u32, 0xf01f_e019), block.readRegister(scb.ccsidr).?);
    try std.testing.expect(block.writeRegister(scb.csselr, 1));
    try std.testing.expect(block.writeRegister(scb.clidr, 0));
    block.reset();
    try std.testing.expectEqual(@as(u32, 0xf01f_e019), block.readRegister(scb.ccsidr).?);
    try std.testing.expectEqual(@as(u32, 0x0900_0003), block.readRegister(scb.clidr).?);
}

test "every CCSIDR the M7 TRM lists is the one its size selects, M7 TRM Table 3-7" {
    inline for (.{ .kb4, .kb8, .kb16, .kb32, .kb64 }, .{ 0xf003_e019, 0xf007_e019, 0xf00f_e019, 0xf01f_e019, 0xf03f_e019 }, .{ 0xf007_e009, 0xf00f_e009, 0xf01f_e009, 0xf03f_e009, 0xf07f_e009 }) |size, data, instruction| {
        var block = fitted(.m7, .{ .data = size, .instruction = size });
        try std.testing.expectEqual(@as(u32, data), block.readRegister(scb.ccsidr).?);
        try std.testing.expect(block.writeRegister(scb.csselr, 1));
        try std.testing.expectEqual(@as(u32, instruction), block.readRegister(scb.ccsidr).?);
    }
}

test "an M7 built without caches keeps the identification registers, with CLIDR and each CCSIDR reading zero, M7 TRM 3.2 3.3.3 3.3.4 3.3.5" {
    var block = of(.m7);
    try std.testing.expectEqual(@as(u32, 0), block.readRegister(scb.clidr).?);
    try std.testing.expectEqual(@as(u32, 0x8303_c003), block.readRegister(scb.ctr).?);
    try std.testing.expectEqual(@as(u32, 0), block.readRegister(scb.ccsidr).?);
    try std.testing.expect(block.writeRegister(scb.csselr, 1));
    try std.testing.expectEqual(@as(u32, 1), block.readRegister(scb.csselr).?);
    try std.testing.expectEqual(@as(u32, 0), block.readRegister(scb.ccsidr).?);
    var instruction_only = fitted(.m7, .{ .instruction = .kb16 });
    try std.testing.expectEqual(@as(u32, 0x0900_0001), instruction_only.readRegister(scb.clidr).?);
    try std.testing.expectEqual(@as(u32, 0), instruction_only.readRegister(scb.ccsidr).?);
}

test "the M7 takes every cache and branch predictor maintenance write and reads each as zero, and the reserved word between faults, with or without caches, v7-M B2.2.7, M7 TRM 3.2" {
    var block = of(.m7);
    var cached = fitted(.m7, .{ .data = .kb32, .instruction = .kb32 });
    var offset = scb.iciallu;
    while (offset <= scb.bpiall) : (offset += 4) {
        if (offset == scb.iciallu + 4) continue;
        try std.testing.expect(block.writeRegister(offset, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, 0), block.readRegister(offset));
        try std.testing.expect(cached.writeRegister(offset, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, 0), cached.readRegister(offset));
    }
    try std.testing.expectEqual(@as(?u32, null), block.readRegister(scb.iciallu + 4));
    try std.testing.expect(!block.writeRegister(scb.iciallu + 4, 0));
    try std.testing.expectEqual(@as(?u32, null), block.readRegister(scb.bpiall + 1));
}

test "a core without caches still refuses the cache identification and maintenance addresses, but for CTR on the M3 and M4, M4 TRM 4.1" {
    inline for (.{ .m0, .m0plus, .m1, .m23, .m3, .m4, .m33, .m55, .m85 }) |core| {
        var block = fitted(core, .{ .data = .kb32, .instruction = .kb32 });
        var offset = scb.clidr;
        while (offset <= scb.csselr) : (offset += 4) {
            if (offset == scb.ctr and (core == .m3 or core == .m4)) continue;
            try std.testing.expectEqual(@as(?u32, null), block.readRegister(offset));
            try std.testing.expect(!block.writeRegister(offset, 0));
        }
        offset = scb.iciallu;
        while (offset <= scb.bpiall) : (offset += 4) {
            try std.testing.expectEqual(@as(?u32, null), block.readRegister(offset));
            try std.testing.expect(!block.writeRegister(offset, 0));
        }
    }
}

test "the M3 and M4 implement CTR in the format with no caches, reading zero and ignoring writes, v7-M B4.8.4" {
    inline for (.{ .m3, .m4 }) |core| {
        var block = fitted(core, .{ .data = .kb32, .instruction = .kb32 });
        try std.testing.expectEqual(@as(?u32, 0), block.readRegister(scb.ctr));
        try std.testing.expect(block.writeRegister(scb.ctr, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, 0), block.readRegister(scb.ctr));
    }
}

test "CPACR holds the CP10 and CP11 access bits and reads zero for every other coprocessor, D1.2.14" {
    var block = of(.m33);
    try std.testing.expect(block.writeRegister(scb.cpacr, 0xffff_ffff));
    try std.testing.expectEqual(@as(u32, 0x00f0_0000), block.readRegister(scb.cpacr).?);
    var narrow = of(.m0plus);
    try std.testing.expect(!narrow.writeRegister(scb.cpacr, 0x00f0_0000));
    try std.testing.expectEqual(@as(?u32, null), narrow.readRegister(scb.cpacr));
}

test "CFSR and HFSR accumulate fault bits and a write of one clears them, B3.2.15 B3.2.16" {
    var block = of(.m4);
    block.fault(.undefined_instruction, 0);
    block.fault(.data_fault, 0x9000_0000);
    block.hardFault(scb.forced);
    try std.testing.expectEqual(@as(u32, 1 << 16 | 1 << 15 | 1 << 9), block.readRegister(scb.cfsr).?);
    try std.testing.expectEqual(scb.forced, block.readRegister(scb.hfsr).?);
    try std.testing.expect(block.writeRegister(scb.cfsr, 1 << 16));
    try std.testing.expectEqual(@as(u32, 1 << 15 | 1 << 9), block.readRegister(scb.cfsr).?);
    try std.testing.expect(block.writeRegister(scb.hfsr, scb.forced));
    try std.testing.expectEqual(@as(u32, 0), block.readRegister(scb.hfsr).?);
}

test "the registers ARMv6-M reserves are absent and their addresses still fault, D3.6.1" {
    var block = of(.m0plus);
    inline for (.{ scb.scr, scb.shpr1, scb.cfsr, scb.hfsr, scb.mmfar, scb.bfar, scb.afsr, scb.cpacr, scb.stir, scb.fpccr, scb.fpcar, scb.fpdscr }) |offset| {
        try std.testing.expect(block.readRegister(offset) == null);
        try std.testing.expect(!block.writeRegister(offset, 1));
    }
    block.fault(.undefined_instruction, 0);
    try std.testing.expect(block.readRegister(scb.cfsr) == null);
}

test "ICSR belongs to the processor and unallocated words of the block fault" {
    var block = of(.m4);
    inline for (.{ scb.icsr, 0x40, 0x84, 0x8c, 0x22 }) |offset| {
        try std.testing.expect(block.readRegister(offset) == null);
        try std.testing.expect(!block.writeRegister(offset, 1));
    }
}

test "a data abort is precise and leaves the faulting address in BFAR, B3.2.15" {
    var block = of(.m4);
    block.fault(.data_fault, 0x9000_0000);
    try std.testing.expectEqual(@as(u32, 1 << 15 | 1 << 9), block.readRegister(scb.cfsr).?);
    try std.testing.expectEqual(@as(u32, 0x9000_0000), block.readRegister(scb.bfar).?);
    block.fault(.fetch_fault, 0x9000_0004);
    try std.testing.expectEqual(@as(u32, 1 << 15 | 1 << 9 | 1 << 8), block.readRegister(scb.cfsr).?);
    try std.testing.expectEqual(@as(u32, 0x9000_0000), block.readRegister(scb.bfar).?);
}

test "the floating-point control registers hold what software writes to them, v7-M B3.2.21 B3.2.22 B3.2.23, v8-M D1.2.100 D1.2.99 D1.2.102" {
    var block = of(.m4);
    try std.testing.expectEqual(@as(u32, 0xc000_0000), block.readRegister(scb.fpccr).?);
    try std.testing.expect(block.writeRegister(scb.fpccr, 0xffff_ffff));
    try std.testing.expectEqual(@as(u32, 0xc000_017b), block.readRegister(scb.fpccr).?);
    try std.testing.expect(block.writeRegister(scb.fpcar, 0x2000_1007));
    try std.testing.expectEqual(@as(u32, 0x2000_1000), block.readRegister(scb.fpcar).?);
    try std.testing.expect(block.writeRegister(scb.fpdscr, 0xffff_ffff));
    try std.testing.expectEqual(@as(u32, 0x07c0_0000), block.readRegister(scb.fpdscr).?);
    var secure = of(.m55);
    try std.testing.expectEqual(@as(u32, 0xc000_0004), secure.readRegister(scb.fpccr).?);
    try std.testing.expect(secure.writeRegister(scb.fpccr, 0xffff_ffff));
    try std.testing.expectEqual(@as(u32, 0xfc00_07ff), secure.readRegister(scb.fpccr).?);
    try std.testing.expectEqual(@as(u32, 0x0004_0000), secure.readRegister(scb.fpdscr).?);
    try std.testing.expect(secure.writeRegister(scb.fpdscr, 0));
    try std.testing.expectEqual(@as(u32, 0x0004_0000), secure.readRegister(scb.fpdscr).?);
}

test "MVFR names the floating-point unit the core carries and a core without one reads the whole block as zero, B4.7.2 B4.7.3 B4.7.4" {
    var seven = of(.m7);
    try std.testing.expectEqual(@as(u32, 0x1011_0221), seven.readRegister(scb.mvfr0).?);
    try std.testing.expectEqual(@as(u32, 0x1200_0011), seven.readRegister(scb.mvfr1).?);
    try std.testing.expectEqual(@as(u32, 0x0000_0040), seven.readRegister(scb.mvfr2).?);
    try std.testing.expect(seven.writeRegister(scb.mvfr0, 0xffff_ffff));
    try std.testing.expectEqual(@as(u32, 0x1011_0221), seven.readRegister(scb.mvfr0).?);
    var four = of(.m4);
    try std.testing.expectEqual(@as(u32, 0x1011_0021), four.readRegister(scb.mvfr0).?);
    try std.testing.expectEqual(@as(u32, 0), four.readRegister(scb.mvfr2).?);
    var three = of(.m3);
    try std.testing.expectEqual(@as(?u32, 0), three.readRegister(scb.mvfr0));
    try std.testing.expectEqual(@as(?u32, 0), three.readRegister(scb.fpccr));
    try std.testing.expect(three.writeRegister(scb.fpccr, 0xffff_ffff));
    try std.testing.expectEqual(@as(?u32, 0), three.readRegister(scb.fpccr));
}

test "STIR reads zero, B3.2.26" {
    var block = of(.m4);
    try std.testing.expectEqual(@as(u32, 0), block.readRegister(scb.stir).?);
}

test "the System Control Block owns none of the MPU words, which have a block of their own, v6-M B3.5.2, v7-M B3.5.4, v8-M D1.1.12" {
    inline for (.{ .m0plus, .m4, .m33 }) |c| {
        var block = of(c);
        var offset = scb.mpu_type;
        while (offset < scb.mpu_end) : (offset += 4) try std.testing.expectEqual(@as(?u32, null), block.readRegister(offset));
    }
}

test "the debug registers read zero and DEMCR keeps TRCENA, C1.6.2 to C1.6.5" {
    var block = of(.m4);
    for ([_]u32{ scb.dhcsr, 0xf4, 0xf8 }) |offset| {
        try std.testing.expectEqual(@as(u32, 0), block.readRegister(offset).?);
        try std.testing.expect(block.writeRegister(offset, 0xffff_ffff));
        try std.testing.expectEqual(@as(u32, 0), block.readRegister(offset).?);
    }
    try std.testing.expectEqual(@as(u32, 0), block.readRegister(scb.demcr).?);
    try std.testing.expect(block.writeRegister(scb.demcr, 0xffff_ffff));
    try std.testing.expectEqual(scb.trcena, block.readRegister(scb.demcr).?);
}
