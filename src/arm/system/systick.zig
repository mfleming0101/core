//! The Arm system timer. It does not tick: the processor advances it at each service point
//! by the cycles that passed, and asks it for the cycles until its next wrap so the schedule
//! can skip to that point. A wrap sets COUNTFLAG and, when SYST_CSR.TICKINT is set, asks the
//! processor to raise the SysTick exception. Cycles beyond one wrap are taken modulo the
//! reload, so a long jump lands where a cycle-by-cycle counter would.
const std = @import("std");
/// The 24-bit system timer: its control, reload and current value registers.
pub const SysTick = struct {
    csr: u32 = 0,
    rvr: u32 = 0,
    cvr: u32 = 0,

    /// The SYST_CSR bit that runs the counter.
    pub const enable: u32 = 1 << 0;
    /// The SYST_CSR bit that raises the SysTick exception on a wrap.
    pub const tickint: u32 = 1 << 1;
    /// The SYST_CSR clock source bit, which the library always reads as the processor clock.
    pub const clksource: u32 = 1 << 2;
    /// The SYST_CSR bit a wrap sets and a read clears.
    pub const countflag: u32 = 1 << 16;
    const noref: u32 = 1 << 31;

    /// Returns every register to zero.
    pub fn reset(self: *SysTick) void {
        self.* = .{};
    }

    /// The word a register read answers; reading SYST_CSR clears COUNTFLAG, v7-M B3.3.3.
    pub fn readRegister(self: *SysTick, offset: u32) ?u32 {
        switch (offset) {
            0x0 => {
                const value = self.csr | clksource;
                self.csr &= ~countflag;
                return value;
            },
            0x4 => return self.rvr,
            0x8 => return self.cvr,
            0xc => return noref,
            else => return null,
        }
    }

    /// Takes a register write; writing SYST_CVR clears the counter and COUNTFLAG.
    pub fn writeRegister(self: *SysTick, offset: u32, value: u32) bool {
        switch (offset) {
            0x0 => self.csr = (self.csr & countflag) | (value & (enable | tickint)),
            0x4 => self.rvr = value & 0x00ff_ffff,
            0x8 => {
                self.cvr = 0;
                self.csr &= ~countflag;
            },
            0xc => {},
            else => return false,
        }
        return true;
    }

    /// Cycles until the counter next reaches zero, or forever where it cannot.
    pub fn deadline(self: *const SysTick) u64 {
        if (self.csr & enable == 0) return std.math.maxInt(u64);
        if (self.cvr != 0) return self.cvr;
        if (self.rvr == 0) return std.math.maxInt(u64);
        return @as(u64, self.rvr) + 1;
    }

    /// Advances the counter by elapsed cycles and answers whether the exception should be raised.
    pub fn advance(self: *SysTick, cycles: u32) bool {
        if (self.csr & enable == 0 or cycles == 0) return false;
        var left: u64 = cycles;
        if (self.cvr == 0) {
            if (self.rvr == 0) return false;
            self.cvr = self.rvr;
            left -= 1;
        }
        if (left < self.cvr) {
            self.cvr -= @intCast(left);
            return false;
        }
        left -= self.cvr;
        self.cvr = 0;
        left %= @as(u64, self.rvr) + 1;
        if (left > 0) self.cvr = self.rvr - @as(u32, @intCast(left - 1));
        self.csr |= countflag;
        return self.csr & tickint != 0;
    }
};
