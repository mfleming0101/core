const std = @import("std");
const register = @import("../../register.zig");
const systick = @import("../../../src/arm/system/systick.zig");
const SysTick = systick.SysTick;

const registers = [_]register.Register{
    .{ .name = "SYST_CSR", .offset = 0x0, .reset = 0x4, .write_mask = 0x3 },
    .{ .name = "SYST_RVR", .offset = 0x4, .reset = 0, .write_mask = 0x00ff_ffff },
    .{ .name = "SYST_CVR", .offset = 0x8, .reset = 0, .write_mask = 0 },
    .{ .name = "SYST_CALIB", .offset = 0xc, .reset = 0x8000_0000, .write_mask = 0 },
};

test "the reset values and the write masks are the ones of B3.3.3 to B3.3.6 of the ARMv6-M manual" {
    var timer: SysTick = .{};
    try std.testing.expect(register.check(&timer, &registers) == null);
}

test "a write to SYST_CVR clears the counter and COUNTFLAG, B3.3.5" {
    var timer: SysTick = .{ .csr = SysTick.countflag, .cvr = 77 };
    try std.testing.expect(timer.writeRegister(0x8, 0x1234));
    try std.testing.expectEqual(@as(u32, 0), timer.cvr);
    try std.testing.expectEqual(@as(u32, 0), timer.csr);
}

test "a read of SYST_CSR returns COUNTFLAG and clears it, B3.3.3" {
    var timer: SysTick = .{ .csr = SysTick.countflag | SysTick.enable };
    try std.testing.expectEqual(SysTick.countflag | SysTick.enable | SysTick.clksource, timer.readRegister(0x0).?);
    try std.testing.expectEqual(SysTick.enable | SysTick.clksource, timer.readRegister(0x0).?);
}

test "with no reference clock NOREF reads as one and CLKSOURCE reads as one and ignores writes, B3.3.3 and B3.3.6" {
    var timer: SysTick = .{};
    try std.testing.expectEqual(@as(u32, 0x8000_0000), timer.readRegister(0xc).?);
    try std.testing.expect(timer.writeRegister(0x0, SysTick.enable));
    try std.testing.expectEqual(SysTick.enable | SysTick.clksource, timer.readRegister(0x0).?);
    try std.testing.expect(timer.writeRegister(0x0, 0));
    try std.testing.expectEqual(SysTick.clksource, timer.readRegister(0x0).?);
}

test "a disabled timer does not count" {
    var timer: SysTick = .{ .rvr = 10, .cvr = 5 };
    try std.testing.expect(!timer.advance(0, 100));
    try std.testing.expectEqual(@as(u32, 5), timer.cvr);
}

test "an enabled timer with a zero counter loads the reload value on the next cycle and then counts down" {
    var timer: SysTick = .{ .csr = SysTick.enable, .rvr = 10 };
    try std.testing.expect(!timer.advance(0, 1));
    try std.testing.expectEqual(@as(u32, 10), timer.cvr);
    try std.testing.expect(!timer.advance(0, 3));
    try std.testing.expectEqual(@as(u32, 7), timer.cvr);
}

test "the count from 1 to 0 sets COUNTFLAG and pends only with TICKINT set, B3.3.1" {
    var quiet: SysTick = .{ .csr = SysTick.enable, .rvr = 10, .cvr = 3 };
    try std.testing.expect(!quiet.advance(0, 3));
    try std.testing.expectEqual(@as(u32, 0), quiet.cvr);
    try std.testing.expectEqual(SysTick.enable | SysTick.countflag, quiet.csr);
    var loud: SysTick = .{ .csr = SysTick.enable | SysTick.tickint, .rvr = 10, .cvr = 3 };
    try std.testing.expect(loud.advance(0, 3));
}

test "many cycles at once wrap the counter as many times as the period fits" {
    var timer: SysTick = .{ .csr = SysTick.enable | SysTick.tickint, .rvr = 9, .cvr = 4 };
    try std.testing.expect(timer.advance(0, 4 + 10 + 10 + 3));
    try std.testing.expectEqual(@as(u32, 9 - 2), timer.cvr);
    var exact: SysTick = .{ .csr = SysTick.enable, .rvr = 9, .cvr = 4 };
    try std.testing.expect(!exact.advance(0, 4 + 10));
    try std.testing.expectEqual(@as(u32, 0), exact.cvr);
}

test "a zero reload value stops the counter at zero after it wraps, B3.3.4" {
    var timer: SysTick = .{ .csr = SysTick.enable | SysTick.tickint, .rvr = 0, .cvr = 2 };
    try std.testing.expect(timer.advance(0, 50));
    try std.testing.expectEqual(@as(u32, 0), timer.cvr);
    try std.testing.expect(!timer.advance(0, 50));
    try std.testing.expectEqual(@as(u32, 0), timer.cvr);
}

test "with a reference clock NOREF reads zero, CLKSOURCE takes writes, and it resets to the part's choice, B3.3.3 and B3.3.6" {
    var timer: SysTick = .of(0x4000_0010, 8, false);
    try std.testing.expectEqual(@as(u32, 0x4000_0010), timer.readRegister(0xc).?);
    try std.testing.expectEqual(@as(u32, 0), timer.readRegister(0x0).?);
    try std.testing.expect(timer.writeRegister(0x0, SysTick.clksource | SysTick.enable));
    try std.testing.expectEqual(SysTick.clksource | SysTick.enable, timer.readRegister(0x0).?);
    timer.reset();
    try std.testing.expectEqual(@as(u32, 0), timer.readRegister(0x0).?);
    var processor: SysTick = .of(0, 8, true);
    try std.testing.expectEqual(SysTick.clksource, processor.readRegister(0x0).?);
    try std.testing.expect(processor.writeRegister(0x0, 0));
    try std.testing.expectEqual(@as(u32, 0), processor.readRegister(0x0).?);
}

test "on the reference clock the counter moves once per reference edge, and the deadline is the cycles to the wrapping edge" {
    var timer: SysTick = .of(0, 8, false);
    _ = timer.writeRegister(0x4, 99);
    _ = timer.writeRegister(0x0, SysTick.enable | SysTick.tickint);
    try std.testing.expectEqual(@as(u64, 800), timer.deadline(0));
    try std.testing.expect(!timer.advance(0, 799));
    try std.testing.expect(timer.advance(799, 1));
    var late: SysTick = .of(0, 8, false);
    _ = late.writeRegister(0x4, 99);
    _ = late.writeRegister(0x0, SysTick.enable);
    try std.testing.expectEqual(@as(u64, 795), late.deadline(5));
    try std.testing.expect(!late.advance(5, 2));
    try std.testing.expectEqual(@as(u32, 0), late.cvr);
    try std.testing.expect(!late.advance(7, 1));
    try std.testing.expectEqual(@as(u32, 99), late.cvr);
}

test "on the processor clock a timer with a reference clock counts cycles" {
    var timer: SysTick = .of(0, 8, true);
    _ = timer.writeRegister(0x4, 9);
    _ = timer.writeRegister(0x0, SysTick.clksource | SysTick.enable | SysTick.tickint);
    try std.testing.expectEqual(@as(u64, 10), timer.deadline(3));
    try std.testing.expect(timer.advance(3, 10));
}
