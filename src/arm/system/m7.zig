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

const siwt: u8 = 1 << 0;
const eccdis: u8 = 1 << 1;
const forcewt: u8 = 1 << 2;

/// The registers of one M7, with the TCM and AHBP controls kept in the part's own types, and what the part wired them with.
pub const Control = struct {
    const Self = @This();

    wired: Wired,
    itcm: core.Tcm,
    dtcm: core.Tcm,
    ahbp: core.Ahbp,
    cache: u8,
    slave: u16,
    banks: [4]u32,

    const Wired = struct { itcm: core.Tcm, dtcm: core.Tcm, ahbp: core.Ahbp, ecc: bool, cacheable: u8 };

    /// The registers at the reset values the part gives, keeping its TCM, AHBP and ECC settings.
    pub fn init(part: core.Part) Self {
        const checked = part.ecc and (part.data != .none or part.instruction != .none);
        return .{
            .wired = .{
                .itcm = part.itcm,
                .dtcm = part.dtcm,
                .ahbp = part.ahbp,
                .ecc = part.ecc,
                .cacheable = (if (part.data != .none) forcewt | siwt else 0) | (if (checked) eccdis else 0),
            },
            .itcm = part.itcm,
            .dtcm = part.dtcm,
            .ahbp = part.ahbp,
            .cache = if (checked) 0 else eccdis,
            .slave = 0x0800,
            .banks = @splat(0),
        };
    }

    /// Puts the TCM, AHBP and ECC settings the part gave back into a part.
    pub fn wiring(self: *const Self, part: *core.Part) void {
        part.itcm = self.wired.itcm;
        part.dtcm = self.wired.dtcm;
        part.ahbp = self.wired.ahbp;
        part.ecc = self.wired.ecc;
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
    pub fn writeRegister(self: *Self, offset: u32, value: u32) bool {
        switch (offset) {
            itcmcr => enable(&self.itcm, value),
            dtcmcr => enable(&self.dtcm, value),
            ahbpcr => self.ahbp.enabled = value & 1 != 0,
            cacr => self.cache = (self.cache & ~self.wired.cacheable) | (@as(u8, @truncate(value)) & self.wired.cacheable),
            ahbscr => self.slave = @truncate(value),
            abfsr => {},
            iebr0, iebr0 + 4, debr0, debr0 + 4 => if (self.wired.ecc) {
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
};
