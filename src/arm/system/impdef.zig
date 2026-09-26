//! The M55 and M85 implementation defined registers at 0xE001E000, M55 and M85 TRM 5.11: MSCR,
//! the M85 PFCR, the TCM and P-AHB controls, the error banks, the power-state requests, the TCM
//! gate controls and EVENTSPR. None drives a model: each keeps the bits its TRM lets software
//! write, from reset values the part gives, and the error banks and power-state requests keep
//! theirs through a Warm reset, as only a Cold reset clears them. The bits are those of MSCR,
//! M55 and M85 TRM Table 5-27, with ICACTIVE, DCACTIVE and EVECCFAULT set at reset where fitted
//! and ECCEN from the part; the M85 PFCR, M85 TRM Table 5-29; EN of the TCM and P-AHB controls,
//! their SZ from the part, Tables 5-42 and 5-28; the error banks where their cache and ECC are
//! fitted, Tables 5-23 to 5-25, less the BANK and LOCATION of DEBR, to which Table 5-24 gives no
//! access type; and the power-state requests and gate controls, Tables 5-31, 5-32 and 5-44, at
//! their Table 5-15 reset values.
const core = @import("core.zig");

/// Where the block begins, M55 TRM Table 8-3.
pub const base: u32 = 0xe001_e000;
/// Its size.
pub const size: u32 = 0x2000;
/// EVENTSPR, at an offset from the base.
pub const eventspr: u32 = 0x400;
/// The EVENTSPR bit that behaves as an RXEV event, M55 TRM Table 5-49.
pub const event: u32 = 1 << 0;
/// The EVENTSPR bit that behaves as an NMI.
pub const nmi: u32 = 1 << 1;

const Slot = enum { mscr, pfcr, itcmcr, dtcmcr, pahbcr, iebr0, iebr1, debr0, debr1, tebr0, tebr1, cpdlpstate, dpdlpstate, itgu_ctrl, dtgu_ctrl };

const cold = [_]Slot{ .iebr0, .iebr1, .debr0, .debr1, .tebr0, .tebr1, .cpdlpstate, .dpdlpstate };
const locked: u32 = 1 << 1;

/// Whether an offset holds a register the Non-secure state always reads as zero, the TCM gate controls, M55 TRM 5.21.1.
pub fn secureOnly(offset: u32) bool {
    return offset == 0x500 or offset == 0x600;
}

/// The registers of one M55 or M85 and what the part wired them with.
pub const Block = struct {
    const Self = @This();

    wired: Wired,
    words: [@typeInfo(Slot).@"enum".fields.len]u32,

    const Wired = struct { m85: bool, data: bool, instruction: bool, ecc: bool, itcm: core.Tcm, dtcm: core.Tcm, ahbp: core.Ahbp };

    /// The registers at the reset values the part gives.
    pub fn init(c: core.Core, part: core.Part) Self {
        var out: Self = .{
            .wired = .{ .m85 = c == .m85, .data = part.data != .none, .instruction = part.instruction != .none, .ecc = part.ecc, .itcm = part.itcm, .dtcm = part.dtcm, .ahbp = part.ahbp },
            .words = undefined,
        };
        for (&out.words, 0..) |*word, i| word.* = out.resetOf(@enumFromInt(i));
        return out;
    }

    /// Puts the caches, TCMs, P-AHB and ECC the part gave back into a part.
    pub fn wiring(self: *const Self, part: *core.Part) void {
        part.itcm = self.wired.itcm;
        part.dtcm = self.wired.dtcm;
        part.ahbp = self.wired.ahbp;
        part.ecc = self.wired.ecc;
    }

    /// Carries the registers only a Cold reset clears over from the block before a Warm reset, M55 TRM 5.13 5.17.
    pub fn keep(self: *Self, before: *const Self) void {
        for (cold) |s| self.words[@intFromEnum(s)] = before.words[@intFromEnum(s)];
    }

    /// The word a register read answers, or null where the TRM lists nothing software may reach.
    pub fn readRegister(self: *const Self, offset: u32) ?u32 {
        if (offset == eventspr) return 0;
        if (!self.wired.m85 and (offset == 0x124 or offset == 0x12c)) return 0;
        const s = self.slotOf(offset) orelse return null;
        return self.words[@intFromEnum(s)];
    }

    /// Takes a register write, keeping the bits the part fixes; of a pair of error banks only one may be LOCKED.
    pub fn writeRegister(self: *Self, offset: u32, value: u32) bool {
        if (self.readRegister(offset) == null) return false;
        const s = self.slotOf(offset) orelse return true;
        var mask = self.maskOf(s);
        if (partner(s)) |other| {
            if (self.words[@intFromEnum(other)] & locked != 0) mask &= ~locked;
        }
        const word = &self.words[@intFromEnum(s)];
        word.* = (word.* & ~mask) | (value & mask);
        return true;
    }

    fn slotOf(self: *const Self, offset: u32) ?Slot {
        return switch (offset) {
            0x000 => .mscr,
            0x004 => if (self.wired.m85) .pfcr else null,
            0x010 => .itcmcr,
            0x014 => .dtcmcr,
            0x018 => .pahbcr,
            0x100 => .iebr0,
            0x104 => .iebr1,
            0x110 => .debr0,
            0x114 => .debr1,
            0x120 => .tebr0,
            0x128 => .tebr1,
            0x300 => .cpdlpstate,
            0x304 => .dpdlpstate,
            0x500 => .itgu_ctrl,
            0x600 => .dtgu_ctrl,
            else => null,
        };
    }

    fn partner(s: Slot) ?Slot {
        return switch (s) {
            .iebr0 => .iebr1,
            .iebr1 => .iebr0,
            .debr0 => .debr1,
            .debr1 => .debr0,
            .tebr0 => .tebr1,
            .tebr1 => .tebr0,
            else => null,
        };
    }

    fn maskOf(self: *const Self, s: Slot) u32 {
        const w = self.wired;
        return switch (s) {
            .mscr => (if (w.data) @as(u32, 1 << 16 | 1 << 12 | 1 << 2) else 0) |
                (if (w.instruction) @as(u32, 1 << 13) else 0) |
                (if (w.ecc and (!w.m85 or w.data)) @as(u32, 1 << 3) else 0) |
                (if (w.ecc and !w.m85) @as(u32, 1 << 4) else 0),
            .pfcr => if (w.data) 0x81 else 0,
            .itcmcr, .dtcmcr, .pahbcr => 1,
            .iebr0, .iebr1 => if (w.instruction and w.ecc) 0xc001_ffff else 0,
            .debr0, .debr1 => if (w.data and w.ecc) 0xc002_0003 else 0,
            .tebr0, .tebr1 => if (!w.ecc) 0 else if (w.m85) 0xdfff_fffb else 0xdfff_ffff,
            .cpdlpstate => 0x33 | (if (w.data or w.instruction) @as(u32, 0x300) else 0),
            .dpdlpstate, .itgu_ctrl, .dtgu_ctrl => 3,
        };
    }

    fn resetOf(self: *const Self, s: Slot) u32 {
        const w = self.wired;
        const mask = self.maskOf(s);
        return switch (s) {
            .mscr => (mask & (1 << 13 | 1 << 12 | 1 << 3)) | (if (w.ecc) @as(u32, 1 << 1) else 0),
            .pfcr => mask & 1,
            .itcmcr => @as(u32, @intFromEnum(w.itcm.size)) << 3 | @intFromBool(w.itcm.enabled),
            .dtcmcr => @as(u32, @intFromEnum(w.dtcm.size)) << 3 | @intFromBool(w.dtcm.enabled),
            .pahbcr => @as(u32, @intFromEnum(w.ahbp.size)) << 1 | @intFromBool(w.ahbp.enabled),
            .cpdlpstate, .dpdlpstate, .itgu_ctrl, .dtgu_ctrl => mask,
            else => 0,
        };
    }
};
