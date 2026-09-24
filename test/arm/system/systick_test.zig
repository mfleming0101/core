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
    try std.testing.expect(!timer.advance(100));
    try std.testing.expectEqual(@as(u32, 5), timer.cvr);
}

test "an enabled timer with a zero counter loads the reload value on the next cycle and then counts down" {
    var timer: SysTick = .{ .csr = SysTick.enable, .rvr = 10 };
    try std.testing.expect(!timer.advance(1));
    try std.testing.expectEqual(@as(u32, 10), timer.cvr);
    try std.testing.expect(!timer.advance(3));
    try std.testing.expectEqual(@as(u32, 7), timer.cvr);
}

test "the count from 1 to 0 sets COUNTFLAG and pends only with TICKINT set, B3.3.1" {
    var quiet: SysTick = .{ .csr = SysTick.enable, .rvr = 10, .cvr = 3 };
    try std.testing.expect(!quiet.advance(3));
    try std.testing.expectEqual(@as(u32, 0), quiet.cvr);
    try std.testing.expectEqual(SysTick.enable | SysTick.countflag, quiet.csr);
    var loud: SysTick = .{ .csr = SysTick.enable | SysTick.tickint, .rvr = 10, .cvr = 3 };
    try std.testing.expect(loud.advance(3));
}

test "many cycles at once wrap the counter as many times as the period fits" {
    var timer: SysTick = .{ .csr = SysTick.enable | SysTick.tickint, .rvr = 9, .cvr = 4 };
    try std.testing.expect(timer.advance(4 + 10 + 10 + 3));
    try std.testing.expectEqual(@as(u32, 9 - 2), timer.cvr);
    var exact: SysTick = .{ .csr = SysTick.enable, .rvr = 9, .cvr = 4 };
    try std.testing.expect(!exact.advance(4 + 10));
    try std.testing.expectEqual(@as(u32, 0), exact.cvr);
}

test "a zero reload value stops the counter at zero after it wraps, B3.3.4" {
    var timer: SysTick = .{ .csr = SysTick.enable | SysTick.tickint, .rvr = 0, .cvr = 2 };
    try std.testing.expect(timer.advance(50));
    try std.testing.expectEqual(@as(u32, 0), timer.cvr);
    try std.testing.expect(!timer.advance(50));
    try std.testing.expectEqual(@as(u32, 0), timer.cvr);
}
