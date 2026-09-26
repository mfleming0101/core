//! The M7 control registers above the cache maintenance operations, M7 TRM Table 3-1: the TCM
//! and AHBP controls, CACR, AHBSCR, ABFSR and the ECC error banks. Their reset values come from
//! the part, and only a processor type that lists the M7 holds them.
const core = @import("core.zig");

/// The first M7 control register offset within the System Control Block window, CM7_ITCMCR.
pub const first: u32 = 0x290;
/// The last one, DEBR1.
pub const last: u32 = 0x2bc;

/// CM7_ITCMCR, at an offset from the first.
pub const itcmcr: u32 = 0x00;
/// CM7_DTCMCR.
pub const dtcmcr: u32 = 0x04;
/// CM7_AHBPCR.
pub const ahbpcr: u32 = 0x08;
/// CM7_CACR.
pub const cacr: u32 = 0x0c;
/// CM7_AHBSCR.
pub const ahbscr: u32 = 0x10;
/// CM7_ABFSR.
pub const abfsr: u32 = 0x18;
/// IEBR0; IEBR1 follows it.
pub const iebr0: u32 = 0x20;
/// DEBR0; DEBR1 follows it.
pub const debr0: u32 = 0x28;

const siwt: u32 = 1 << 0;
const eccdis: u32 = 1 << 1;
const forcewt: u32 = 1 << 2;

/// The registers of one M7, with the TCM and AHBP controls kept in the part's own types.
pub const Control = struct {
    const Self = @This();

    itcm: core.Tcm,
    dtcm: core.Tcm,
    ahbp: core.Ahbp,
    cache: u32,
    slave: u32,
    banks: [4]u32,

    /// The registers at the reset values the part gives.
    pub fn init(part: core.Part) Self {
        return .{ .itcm = part.itcm, .dtcm = part.dtcm, .ahbp = part.ahbp, .cache = if (ecc(part)) 0 else eccdis, .slave = 0x0000_0800, .banks = @splat(0) };
    }

    /// The word a register read answers, or null for a word Table 3-1 reserves.
    pub fn readRegister(self: *const Self, offset: u32) ?u32 {
        return switch (offset) {
            itcmcr => @as(u7, @bitCast(self.itcm)),
            dtcmcr => @as(u7, @bitCast(self.dtcm)),
            ahbpcr => @as(u4, @bitCast(self.ahbp)),
            cacr => self.cache,
            ahbscr => self.slave,
            abfsr => 0,
            iebr0, iebr0 + 4, debr0, debr0 + 4 => self.banks[(offset - iebr0) / 4],
            else => null,
        };
    }

    /// Takes a register write, keeping the bits the part fixes; ABFSR has nothing for a write to clear.
    pub fn writeRegister(self: *Self, part: core.Part, offset: u32, value: u32) bool {
        switch (offset) {
            itcmcr => enable(&self.itcm, value),
            dtcmcr => enable(&self.dtcm, value),
            ahbpcr => self.ahbp.enabled = value & 1 != 0,
            cacr => {
                const mask = (if (part.data != .none) forcewt | siwt else 0) | (if (ecc(part)) eccdis else 0);
                self.cache = (self.cache & ~mask) | (value & mask);
            },
            ahbscr => self.slave = value & 0x0000_ffff,
            abfsr => {},
            iebr0, iebr0 + 4, debr0, debr0 + 4 => if (part.ecc) {
                self.banks[(offset - iebr0) / 4] = value;
            },
            else => return false,
        }
        return true;
    }

    fn enable(tcm: *core.Tcm, value: u32) void {
        tcm.enabled = value & 1 != 0;
        tcm.read_modify_write = value & 2 != 0;
        tcm.retry = value & 4 != 0;
    }

    fn ecc(part: core.Part) bool {
        return part.ecc and (part.data != .none or part.instruction != .none);
    }
};
