const std = @import("std");
const register = @import("../../register.zig");
const scb = @import("../../../src/arm/system/scb.zig");
const Part = @import("../../../src/arm/system/core.zig").Part;

fn of(comptime c: anytype) scb.Scb {
    return fitted(c, .{});
}

fn fitted(comptime c: anytype, part: Part) scb.Scb {
    return .init(&struct {
        const profile: scb.Profile = scb.profileOf(c);
    }.profile, part);
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

test "the priority bytes of SHPR1, SHPR2 and SHPR3 keep the high bits of the widest priority the core's parts may have, which the processor narrows to the part's, v6-M B3.2.9 B3.2.10, v7-M B3.2.10 B3.2.11 B3.2.12, M4 TRM 2.2" {
    inline for (.{ .m0plus, .m4 }, .{ 0xc000_0000, 0xff00_0000 }, .{ 0xc0c0_0000, 0xffff_00ff }) |core, mask2, mask3| {
        try std.testing.expectEqual(@as(u32, mask2), find(core, "SHPR2").write_mask);
        try std.testing.expectEqual(@as(u32, mask3), find(core, "SHPR3").write_mask);
    }
    try std.testing.expectEqual(@as(u32, 0x00ff_ffff), find(.m4, "SHPR1").write_mask);
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

test "every CCSIDR the M7 TRM lists is the one its size selects, and the M55 and M85 sizes give the same sets, ways and lines, M7 TRM Table 3-7, M55 and M85 TRM Table 3-4 Table 5-10 Table 5-17 Table 5-18" {
    inline for (.{ .m7, .m55, .m85 }) |core| {
        inline for (.{ .kb4, .kb8, .kb16, .kb32, .kb64 }, .{ 0xf003_e019, 0xf007_e019, 0xf00f_e019, 0xf01f_e019, 0xf03f_e019 }, .{ 0xf007_e009, 0xf00f_e009, 0xf01f_e009, 0xf03f_e009, 0xf07f_e009 }) |size, data, instruction| {
            var block = fitted(core, .{ .data = size, .instruction = size });
            try std.testing.expectEqual(@as(u32, data), block.readRegister(scb.ccsidr).?);
            try std.testing.expect(block.writeRegister(scb.csselr, 1));
            try std.testing.expectEqual(@as(u32, instruction), block.readRegister(scb.ccsidr).?);
        }
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

test "the M7, M55 and M85 take every cache and branch predictor maintenance write and read each as zero, and the reserved word between faults, with or without caches, v7-M B2.2.7, v8-M D1.1.18, M7 TRM 3.2, M55 TRM Table 10-13, M85 TRM Table 10-10" {
    inline for (.{ .m7, .m55, .m85 }) |core| {
        var block = of(core);
        var cached = fitted(core, .{ .data = .kb32, .instruction = .kb32 });
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
}

test "the M55 and M85 with caches read CLIDR with LoUIS, CTR in the Armv7 format and the CCSIDR CSSELR.InD picks, and let software set IC and DC only for the caches the part has, M55 and M85 TRM 5.6 Table 5-8 Table 5-9 6.5, v8-M D1.2.9" {
    inline for (.{ .m55, .m85 }) |core| {
        var block = fitted(core, .{ .data = .kb32, .instruction = .kb32 });
        try std.testing.expectEqual(@as(u32, 0x0920_0003), block.readRegister(scb.clidr).?);
        try std.testing.expectEqual(@as(u32, 0x8303_c003), block.readRegister(scb.ctr).?);
        try std.testing.expectEqual(@as(u32, 0xf01f_e019), block.readRegister(scb.ccsidr).?);
        try std.testing.expect(block.writeRegister(scb.csselr, 0xffff_ffff));
        try std.testing.expectEqual(@as(u32, 1), block.readRegister(scb.csselr).?);
        try std.testing.expectEqual(@as(u32, 0xf03f_e009), block.readRegister(scb.ccsidr).?);
        try std.testing.expect(block.writeRegister(scb.ccr, 0x0003_0201));
        try std.testing.expectEqual(@as(u32, 0x0003_0201), block.readRegister(scb.ccr).?);
        var data_only = fitted(core, .{ .data = .kb4 });
        try std.testing.expectEqual(@as(u32, 0x0920_0002), data_only.readRegister(scb.clidr).?);
        try std.testing.expectEqual(@as(u32, 0x8303_c003), data_only.readRegister(scb.ctr).?);
        try std.testing.expect(data_only.writeRegister(scb.ccr, 0x0003_0201));
        try std.testing.expectEqual(@as(u32, 0x0001_0201), data_only.readRegister(scb.ccr).?);
        var instruction_only = fitted(core, .{ .instruction = .kb64 });
        try std.testing.expectEqual(@as(u32, 0x0920_0001), instruction_only.readRegister(scb.clidr).?);
        try std.testing.expectEqual(@as(u32, 0x8303_c003), instruction_only.readRegister(scb.ctr).?);
        try std.testing.expectEqual(@as(u32, 0), instruction_only.readRegister(scb.ccsidr).?);
    }
}

test "CLIDR, CTR and CCSIDR ignore writes on every core that has them, with or without caches, v7-M B4.8.1 B4.8.2 B4.8.4, v8-M D1.2.10 D1.2.12 D1.2.18" {
    inline for (.{ .m3, .m4, .m7, .m23, .m33, .m55, .m85 }) |core| {
        inline for (.{ Part{}, Part{ .data = .kb32, .instruction = .kb32 } }) |part| {
            var block = fitted(core, part);
            inline for (.{ scb.clidr, scb.ctr, scb.ccsidr }) |offset| {
                if (block.readRegister(offset)) |was| {
                    try std.testing.expect(block.writeRegister(offset, ~was));
                    try std.testing.expectEqual(was, block.readRegister(offset).?);
                }
            }
        }
    }
}

test "an M55 or M85 built without caches keeps the identification registers, with CLIDR, CTR and each CCSIDR reading zero and IC and DC held clear, M55 and M85 TRM 5.6 5.6.1 5.6.3, v8-M D1.2.9" {
    inline for (.{ .m55, .m85 }) |core| {
        var block = of(core);
        try std.testing.expectEqual(@as(u32, 0), block.readRegister(scb.clidr).?);
        try std.testing.expectEqual(@as(u32, 0), block.readRegister(scb.ctr).?);
        try std.testing.expectEqual(@as(u32, 0), block.readRegister(scb.ccsidr).?);
        try std.testing.expect(block.writeRegister(scb.csselr, 1));
        try std.testing.expectEqual(@as(u32, 1), block.readRegister(scb.csselr).?);
        try std.testing.expectEqual(@as(u32, 0), block.readRegister(scb.ccsidr).?);
        try std.testing.expect(block.writeRegister(scb.ccr, 0x0003_0201));
        try std.testing.expectEqual(@as(u32, 0x0000_0201), block.readRegister(scb.ccr).?);
    }
}

test "an Armv6-M or Armv7-M core without caches still refuses the cache identification and maintenance addresses, but for CLIDR, CTR and CSSELR on the M3 and M4, v6-M D3.6.1, v7-M B4.8.1 B4.8.2 B4.8.3 B4.8.4" {
    inline for (.{ .m0, .m0plus, .m1, .m3, .m4 }) |core| {
        var block = fitted(core, .{ .data = .kb32, .instruction = .kb32 });
        var offset = scb.clidr;
        while (offset <= scb.csselr) : (offset += 4) {
            if (offset != scb.ccsidr and (core == .m3 or core == .m4)) continue;
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

test "the M3 and M4 have CLIDR reading no cache at any level and a CSSELR that holds its selection, v7-M B4.8.1 B4.8.3" {
    inline for (.{ .m3, .m4 }) |core| {
        var block = of(core);
        try std.testing.expectEqual(@as(?u32, 0), block.readRegister(scb.clidr));
        try std.testing.expect(block.writeRegister(scb.clidr, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, 0), block.readRegister(scb.clidr));
        try std.testing.expectEqual(@as(?u32, 0), block.readRegister(scb.csselr));
        try std.testing.expect(block.writeRegister(scb.csselr, 1));
        try std.testing.expectEqual(@as(?u32, 1), block.readRegister(scb.csselr));
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

test "the M23 and M33 implement CTR in the format with no cache type information, reading zero and ignoring writes, v8-M D1.2.18, M33 TRM Table 3-1" {
    inline for (.{ .m23, .m33 }) |core| {
        var block = fitted(core, .{ .data = .kb32, .instruction = .kb32 });
        try std.testing.expectEqual(@as(?u32, 0), block.readRegister(scb.ctr));
        try std.testing.expect(block.writeRegister(scb.ctr, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, 0), block.readRegister(scb.ctr));
    }
}

test "the M23 and M33 implement CLIDR with no cache levels, reading zero whatever caches their part names and ignoring writes, v8-M D1.2.12, M33 TRM Table 3-2" {
    inline for (.{ .m23, .m33 }) |core| {
        var block = fitted(core, .{ .data = .kb32, .instruction = .kb32 });
        try std.testing.expectEqual(@as(?u32, 0), block.readRegister(scb.clidr));
        try std.testing.expect(block.writeRegister(scb.clidr, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, 0), block.readRegister(scb.clidr));
    }
}

test "the M23 and M33, with no caches, still implement CCSIDR and CSSELR, CCSIDR reading zero, and take every cache maintenance write, as v8-M always implements them, v8-M D1.2.10 D1.2.17 D1.2.124 D1.2.8" {
    inline for (.{ .m23, .m33 }) |core| {
        var block = fitted(core, .{ .data = .kb32, .instruction = .kb32 });
        try std.testing.expect(block.writeRegister(scb.csselr, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, 1), block.readRegister(scb.csselr));
        try std.testing.expectEqual(@as(?u32, 0), block.readRegister(scb.ccsidr));
        var offset = scb.iciallu;
        while (offset <= scb.bpiall) : (offset += 4) {
            if (offset == scb.iciallu + 4) continue;
            try std.testing.expect(block.writeRegister(offset, 0xffff_ffff));
            try std.testing.expectEqual(@as(?u32, 0), block.readRegister(offset));
        }
    }
}

test "without the Main Extension or a floating-point unit the M23 reads the Main and floating-point registers as zero and ignores writes, v8-M D1.2.11 D1.2.123 D1.2.166 D1.2.6 D1.2.234 D1.2.14 D1.2.239 D1.2.178 D1.2.100 D1.2.99 D1.2.102, and AFSR, which v8-M always implements, D1.2.2" {
    var block = of(.m23);
    inline for (.{ scb.cfsr, scb.hfsr, scb.mmfar, scb.bfar, scb.shpr1, scb.cpacr, scb.stir, scb.mvfr0, scb.mvfr1, scb.mvfr2, scb.fpccr, scb.fpcar, scb.fpdscr, scb.afsr }) |offset| {
        try std.testing.expect(block.writeRegister(offset, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, 0), block.readRegister(offset));
    }
    block.fault(.data_fault, 0x40);
    try std.testing.expectEqual(@as(?u32, 0), block.readRegister(scb.cfsr));
    try std.testing.expectEqual(@as(?u32, 0), block.readRegister(scb.bfar));
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
    inline for (.{ scb.shpr1, scb.cfsr, scb.hfsr, scb.mmfar, scb.bfar, scb.afsr, scb.cpacr, scb.stir, scb.fpccr, scb.fpcar, scb.fpdscr }) |offset| {
        try std.testing.expect(block.readRegister(offset) == null);
        try std.testing.expect(!block.writeRegister(offset, 1));
    }
    block.fault(.undefined_instruction, 0);
    try std.testing.expect(block.readRegister(scb.cfsr) == null);
}

test "ICSR belongs to the processor and unallocated words of the block fault" {
    var block = of(.m4);
    inline for (.{ scb.icsr, 0xd0, 0x8c, 0x22 }) |offset| {
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

fn expectFeatures(block: *scb.Scb, words: [14]?u32) !void {
    for (words, 0..) |word, i| {
        const offset = scb.id_pfr0 + 4 * @as(u32, @intCast(i));
        try std.testing.expectEqual(word, block.readRegister(offset));
        try std.testing.expectEqual(word != null, block.writeRegister(offset, 0xffff_ffff));
        try std.testing.expectEqual(word, block.readRegister(offset));
    }
}

test "ID_PFR0 to ID_ISAR5 read their TRM tables and ignore writes, M3 and M4 TRM Table 4-1, M7 TRM Table 3-1, M33 TRM Table 3-1, M55 and M85 TRM Table 5-1, v7-M Table B4-1" {
    var m3 = of(.m3);
    try expectFeatures(&m3, .{ 0x30, 0x200, 0x0010_0000, 0, 0x0010_0030, 0, 0x0100_0000, 0, 0x0110_0110, 0x0211_1000, 0x2111_2231, 0x0111_1110, 0x0131_0132, 0 });
    var m4 = of(.m4);
    try expectFeatures(&m4, .{ 0x30, 0x200, 0x0010_0000, 0, 0x0010_0030, 0, 0x0100_0000, 0, 0x0114_1110, 0x0211_2000, 0x2123_2231, 0x0111_1131, 0x0131_0132, 0 });
    var m7 = of(.m7);
    try expectFeatures(&m7, .{ 0x30, 0x200, 0x0010_0000, 0, 0x0010_0030, 0, 0x0100_0000, 0, 0x0110_1110, 0x0211_2000, 0x2023_2231, 0x0111_1131, 0x0131_0132, 0 });
    var m33 = of(.m33);
    try expectFeatures(&m33, .{ null, null, 0x0020_0000, 0, 0x0010_1f40, 0, 0x0100_0000, 0, 0x0110_1110, 0x0221_2000, 0x2023_2232, 0x0111_1131, 0x0131_0132, 0 });
    var m55 = of(.m55);
    try expectFeatures(&m55, .{ 0x2000_0030, 0x230, 0x1020_0000, 0, 0x0011_1040, 0, 0x0100_0000, 0x11, 0x0110_3110, 0x0221_2000, 0x2023_2232, 0x0111_1131, 0x0131_0132, 0 });
    var m85 = of(.m85);
    try expectFeatures(&m85, .{ 0x2000_0030, 0x230, 0x1020_0000, 0, 0x0011_1040, 0, 0x0100_0000, 0x11, 0x0110_3110, 0x0221_2000, 0x2023_2232, 0x0111_1131, 0x0131_0132, 0x0040_0000 });
}

test "the feature registers are reserved on Armv6-M and RES0 on the M23, v6-M D3.6.1, v8-M D1.2.140" {
    inline for (.{ .m0, .m0plus, .m1 }) |core| {
        var block = of(core);
        try expectFeatures(&block, @splat(null));
    }
    var m23 = of(.m23);
    try expectFeatures(&m23, @splat(0));
}

test "an M7 with a TCM reads TCM support in ID_MMFR0, M7 TRM Table 3-1 footnote h, v7-M B4.5.1" {
    var tcm = fitted(.m7, .{ .dtcm = .{ .size = .kb64 } });
    try std.testing.expectEqual(@as(?u32, 0x0011_0030), tcm.readRegister(scb.id_mmfr0));
    var bare = of(.m7);
    try std.testing.expectEqual(@as(?u32, 0x0010_0030), bare.readRegister(scb.id_mmfr0));
}

test "NSACR holds CP10 and CP11 on the M33, M55 and M85, is RES0 on the M23 and absent before Armv8-M, v8-M D1.2.181" {
    inline for (.{ .m33, .m55, .m85 }) |core| {
        var block = of(core);
        try std.testing.expectEqual(@as(?u32, 0), block.readRegister(scb.nsacr));
        try std.testing.expect(block.writeRegister(scb.nsacr, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, 0xc00), block.readRegister(scb.nsacr));
    }
    var m23 = of(.m23);
    try std.testing.expect(m23.writeRegister(scb.nsacr, 0xffff_ffff));
    try std.testing.expectEqual(@as(?u32, 0), m23.readRegister(scb.nsacr));
    var m4 = of(.m4);
    try std.testing.expectEqual(@as(?u32, null), m4.readRegister(scb.nsacr));
}
