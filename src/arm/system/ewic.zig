//! The External Wakeup Interrupt Controller an M55 or M85 part may fit at 0xE0047000, M55 and
//! M85 TRM Appendix A. It keeps its control, sequence and mask registers, and while enabled
//! latches each interrupt the part raises into EWIC_PENDn. No sleep state hands wakeup to it,
//! so nothing reads the latched interrupts back into the NVIC, and no special event reaches
//! EWIC_PENDA, which reads zero.
const std = @import("std");

/// Where the EWIC begins.
pub const base: u32 = 0xe004_7000;
/// Its size.
pub const size: u32 = 0x1000;
/// The EWIC_MASKn and EWIC_PENDn registers there are room for, one per 32 interrupts.
pub const banks = 15;
const fewest: u16 = 4;
const most: u16 = 483;

const special: u32 = 3;

/// One EWIC, or none where the part fits none.
pub const Ewic = struct {
    const Self = @This();

    events: u16,
    enabled: bool = false,
    sequence: u2 = 3,
    mask_special: u3 = 0,
    masks: [banks]u32 = @splat(0),
    pends: [banks]u32 = @splat(0),

    /// An EWIC supporting that many events, the part's count lowered or raised into the TRM's range, or none for zero.
    pub fn init(events: u16) Self {
        return .{ .events = if (events == 0) 0 else std.math.clamp(events, fewest, most) };
    }

    /// Latches the interrupts raised in one word of lines while the EWIC is enabled, M55 TRM A.2.6.
    pub fn latch(self: *Self, n: u32, raised: u32) void {
        if (self.enabled) self.pends[n] |= raised & self.supported(n);
    }

    /// The word a register read answers, or null where the EWIC is absent or lists nothing.
    pub fn readRegister(self: *const Self, offset: u32) ?u32 {
        if (self.events == 0 or offset & 3 != 0) return null;
        return switch (offset) {
            0x000 => @intFromBool(self.enabled),
            0x004 => self.sequence,
            0x008, 0x400 => 0,
            0x00c => self.events,
            0x200 => self.mask_special,
            0x204...0x23c => self.masks[(offset - 0x204) / 4],
            0x404...0x43c => self.pends[(offset - 0x404) / 4],
            0x600 => self.summary(),
            else => null,
        };
    }

    /// Takes a register write: clearing EN drops every latched interrupt, a write to EWIC_CLRMASK clears every mask, and a one written to EWIC_PENDn pends that interrupt, M55 TRM A.2.1 A.2.3 A.2.6.
    pub fn writeRegister(self: *Self, offset: u32, value: u32) bool {
        if (self.readRegister(offset) == null) return false;
        switch (offset) {
            0x000 => {
                self.enabled = value & 1 != 0;
                if (!self.enabled) self.pends = @splat(0);
            },
            0x004 => self.sequence = @truncate(value),
            0x008 => {
                self.mask_special = 0;
                self.masks = @splat(0);
            },
            0x200 => self.mask_special = @truncate(value),
            0x204...0x23c => self.masks[(offset - 0x204) / 4] = value & self.supported((offset - 0x204) / 4),
            0x404...0x43c => self.pends[(offset - 0x404) / 4] |= value & self.supported((offset - 0x404) / 4),
            else => {},
        }
        return true;
    }

    fn supported(self: *const Self, n: u32) u32 {
        const lines = self.events - special;
        if (lines <= n * 32) return 0;
        const left = lines - n * 32;
        return if (left >= 32) 0xffff_ffff else (@as(u32, 1) << @intCast(left)) - 1;
    }

    fn summary(self: *const Self) u32 {
        var out: u32 = 0;
        for (self.pends, 0..) |word, n| {
            if (word != 0) out |= @as(u32, 2) << @intCast(n);
        }
        return out;
    }
};
