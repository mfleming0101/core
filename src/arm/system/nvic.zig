//! The Nested Vectored Interrupt Controller registers the block owns: the enable bits for up
//! to two hundred and forty lines and the priority byte of each. The pending and active sets
//! are not here, because the processor keeps one set over exception numbers rather than
//! lines, and answers NVIC_ISPR, NVIC_ICPR and NVIC_IABR out of it. A line is an IRQ number,
//! sixteen below the exception number it takes.
const regions = @import("../../memory/regions.zig");

/// Where the NVIC registers begin.
pub const base: u32 = 0xe000_e100;
/// How wide the NVIC window is.
pub const size: u32 = 0x4f0;
/// How many external interrupt lines the processor carries.
pub const lines = regions.lines;
/// A set of interrupt lines, one bit each.
pub const Lines = regions.Lines;
/// One interrupt line, an IRQ number.
pub const Line = regions.Line;
/// The last offset within a bank of eight per-line words.
pub const bank: u32 = 0x1c;

/// NVIC_ISER, at an offset from the base.
pub const iser: u32 = 0x000;
/// NVIC_ICER, at an offset from the base.
pub const icer: u32 = 0x080;
/// NVIC_ISPR, at an offset from the base.
pub const ispr: u32 = 0x100;
/// NVIC_ICPR, at an offset from the base.
pub const icpr: u32 = 0x180;
/// NVIC_IABR, at an offset from the base.
pub const iabr: u32 = 0x200;
/// NVIC_ITNS, at an offset from the base.
pub const itns: u32 = 0x280;
/// NVIC_IPR, at an offset from the base.
pub const ipr: u32 = 0x300;

/// The writable bits of a priority word on a core implementing that many priority bits.
pub fn lanesOf(priority_bits: u4) u32 {
    return ((@as(u32, 0xff) << (8 - priority_bits)) & 0xff) * 0x0101_0101;
}

/// The i-th 32-line word of a set, which is what one register reads as.
pub fn wordOf(set: Lines, i: u32) u32 {
    return @truncate(set >> @intCast(i * 32));
}

/// A register word put back where a set holds it.
pub fn placed(value: u32, i: u32) Lines {
    return @as(Lines, value) << @intCast(i * 32);
}

/// The interrupt controller registers: the enable bits and the per-line priorities.
pub const Nvic = struct {
    const Self = @This();

    lanes: u32,
    enabled: Lines = 0,
    priorities: [lines / 4]u32 = @splat(0),

    /// An NVIC whose priority words keep only the bits the core implements.
    pub fn init(priority_bits: u4) Self {
        return .{ .lanes = lanesOf(priority_bits) };
    }

    /// Clears every enable and priority, keeping the core's priority width.
    pub fn reset(self: *Self) void {
        self.* = .{ .lanes = self.lanes };
    }

    /// The priority byte of one line.
    pub fn priority(self: *const Self, line: Line) u8 {
        return @truncate(self.priorities[line / 4] >> @intCast((line % 4) * 8));
    }

    /// The word a register read answers; the pending and active sets live on the processor.
    pub fn readRegister(self: *Self, offset: u32) ?u32 {
        if (offset & 3 != 0) return null;
        return switch (offset) {
            iser...iser + bank => wordOf(self.enabled, (offset - iser) / 4),
            icer...icer + bank => wordOf(self.enabled, (offset - icer) / 4),
            ipr...ipr + 0xfc => if ((offset - ipr) / 4 < self.priorities.len) self.priorities[(offset - ipr) / 4] else 0,
            else => 0,
        };
    }

    /// Takes a register write, a priority write keeping only the implemented bits.
    pub fn writeRegister(self: *Self, offset: u32, value: u32) bool {
        if (offset & 3 != 0) return false;
        switch (offset) {
            iser...iser + bank => self.enabled |= placed(value, (offset - iser) / 4),
            icer...icer + bank => self.enabled &= ~placed(value, (offset - icer) / 4),
            ipr...ipr + 0xfc => if ((offset - ipr) / 4 < self.priorities.len) {
                self.priorities[(offset - ipr) / 4] = value & self.lanes;
            },
            else => {},
        }
        return true;
    }
};
