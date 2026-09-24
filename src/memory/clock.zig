//! The clock a caller runs the core against wall time or another clock with. It converts
//! cycles to picoseconds and back, keeping the leftover of a frequency that does not divide a
//! second exactly so nothing is lost over a long run. The processor counts cycles of its own
//! and never consults this; only a caller that cares about time does.
const std = @import("std");

/// Cycles and wall time in one place, counted in picoseconds so no frequency loses anything.
pub const Clock = struct {
    hz: u64,
    per: u64,
    rem: u64,
    owed: u64 = 0,
    ps: u64 = 0,

    const second = 1_000_000_000_000;

    /// A clock at a frequency, with nothing spent yet.
    pub fn at(hz: u64) Clock {
        return .{ .hz = hz, .per = second / hz, .rem = second % hz };
    }

    /// Spends cycles, carrying the remainder a frequency that does not divide a second leaves.
    pub fn charge(self: *Clock, cycles: u64) void {
        self.ps += cycles * self.per;
        if (self.rem == 0) return;
        self.owed += cycles * self.rem;
        self.ps += self.owed / self.hz;
        self.owed %= self.hz;
    }

    /// How many cycles reach a duration, rounded up and never zero.
    pub fn cyclesTo(self: *const Clock, ps: u64) u64 {
        const cycles = (@as(u128, ps) * self.hz + second - 1) / second;
        return @intCast(@max(1, @min(cycles, std.math.maxInt(u64))));
    }

    /// Changes the frequency and keeps the picoseconds already spent.
    pub fn bank(self: *Clock, hz: u64) void {
        if (hz == 0 or hz == self.hz) return;
        const spent = self.ps;
        self.* = at(hz);
        self.ps = spent;
    }
};
