//! The Nested Vectored Interrupt Controller registers the block owns: the enable bits for up
//! to four hundred and eighty lines and the priority byte of each. The pending and active sets
//! are not here, because the processor keeps one set over exception numbers rather than
//! lines, and answers NVIC_ISPR, NVIC_ICPR and NVIC_IABR out of it. A line is an IRQ number,
//! sixteen below the exception number it takes.
const std = @import("std");
const regions = @import("../../memory/regions.zig");

/// Where the NVIC registers begin.
pub const base: u32 = 0xe000_e100;
/// How wide the NVIC window is.
pub const size: u32 = 0x4f0;
/// How many external interrupt lines a processor carries unless one of its cores allows more, which the bus carries too.
pub const lines = regions.lines;
/// One interrupt line, an IRQ number.
pub const Line = u9;
/// The last offset within a bank of sixteen per-line words, v8-M D1.2.186.
pub const bank: u32 = 0x3c;
/// The last NVIC_IPR word, v8-M D1.2.185.
pub const last_ipr: u32 = size - 4;

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

/// The i-th 32-line word of a set, which is what one register reads as, zero past the set.
pub fn wordOf(set: anytype, i: u32) u32 {
    return @truncate(std.math.shr(@TypeOf(set), set, i * 32));
}

/// A register word put back where a set of that type holds it, dropped past the set.
pub fn placed(comptime T: type, value: u32, i: u32) T {
    return std.math.shl(T, value, i * 32);
}

/// The interrupt controller registers over that many lines: the enable bits and the per-line priorities.
pub fn Nvic(comptime width: u16) type {
    return struct {
        const Self = @This();
        /// A set of the lines, one bit each.
        pub const Lines = std.meta.Int(.unsigned, width);

        lanes: u32,
        count: u16,
        enabled: Lines = 0,
        priorities: [width / 4]u32 = @splat(0),

        /// An NVIC whose priority words keep only the bits the part implements, over the lines below count.
        pub fn init(priority_bits: u4, count: u16) Self {
            return .{ .lanes = lanesOf(priority_bits), .count = count };
        }

        /// Clears every enable and priority, keeping the part's priority width and lines.
        pub fn reset(self: *Self) void {
            self.* = .{ .lanes = self.lanes, .count = self.count };
        }

        /// The lines the part implements.
        pub fn present(self: *const Self) Lines {
            return std.math.shr(Lines, ~@as(Lines, 0), width - self.count);
        }

        /// The bits of the register at an offset that belong to implemented lines, the rest reserved, v7-M B3.4.2, v8-M B12.2 RSGCR.
        pub fn implemented(self: *const Self, offset: u32) u32 {
            return switch (offset) {
                iser...ipr - 1 => if (offset % 0x80 <= bank) wordOf(self.present(), (offset % 0x80) / 4) else 0,
                ipr...last_ipr => {
                    const kept: u32 = @min(@as(u32, self.count) -| (offset - ipr), 4);
                    return std.math.shr(u32, 0xffff_ffff, 8 * (4 - kept));
                },
                else => 0xffff_ffff,
            };
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
                ipr...last_ipr => if ((offset - ipr) / 4 < self.priorities.len) self.priorities[(offset - ipr) / 4] else 0,
                else => 0,
            };
        }

        /// Takes a register write, a priority write keeping only the implemented bits.
        pub fn writeRegister(self: *Self, offset: u32, value: u32) bool {
            if (offset & 3 != 0) return false;
            switch (offset) {
                iser...iser + bank => self.enabled |= placed(Lines, value, (offset - iser) / 4),
                icer...icer + bank => self.enabled &= ~placed(Lines, value, (offset - icer) / 4),
                ipr...last_ipr => if ((offset - ipr) / 4 < self.priorities.len) {
                    self.priorities[(offset - ipr) / 4] = value & self.lanes;
                },
                else => {},
            }
            return true;
        }
    };
}
