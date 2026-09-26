//! ACTLR and CPPWR, the two registers of the Implementation Control Block a program writes.
//! Which of their bits a core keeps is its TRM's; a core with the Security Extension keeps one
//! ACTLR per Security state and one CPPWR for both, and the Non-secure view hides the bits the
//! Secure state keeps to itself.
const core = @import("core.zig");

/// ACTLR, at an offset from the control base.
pub const actlr: u32 = 0x08;
/// CPPWR, at an offset from the control base.
pub const cppwr: u32 = 0x0c;
/// The CPPWR bit that lets the floating-point state become UNKNOWN, which leaves the unit unusable, v8-M D1.2.15.
pub const su10: u32 = 1 << 20;
/// The CPPWR bit that keeps SU10 and SU11 from the Non-secure state and sends a NOCP UsageFault they raise to the Secure state.
pub const sus10: u32 = 1 << 21;
const su11: u32 = 1 << 22;
const sus11: u32 = 1 << 23;
const eventbusen: u32 = 1 << 14;
const eventbusen_s: u32 = 1 << 13;

/// The ACTLR bits a core keeps: the M3 and M4, M3 and M4 TRM 4.2; the M7, M7 TRM 3.3.1, but DISITMATBFLUSH, which Table 3-3 makes RAO/WI and Table 3-1 resets to zero; the M23, M23 TRM 5.2.1; the M33, M33 TRM 3.4; and the M55 and M85, M55 and M85 TRM 5.9. The M0 and M0+ read zero, M0+ TRM Table 4-1, and the M1's ITCM alias bits would move memory, which the library leaves to the bus.
fn actlrMask(c: core.Core) u32 {
    return switch (c) {
        .m0, .m0plus, .m1 => 0,
        .m3, .m4 => 0x0000_0207,
        .m7 => 0x1fff_ec04,
        .m23 => 0x2000_0000,
        .m33 => 0x2000_3605,
        .m55 => 0x0803_fcfc,
        .m85 => 0x0800_fc00,
    };
}

/// The ACTLR bits the M55 and M85 keep once for both Security states, EVENTBUSEN and the Secure-only EVENTBUSEN_S, M55 and M85 TRM 5.9.
fn unbanked(c: core.Core) u32 {
    return if (c == .m55 or c == .m85) eventbusen | eventbusen_s else 0;
}

/// The CPPWR bits a core keeps: SU10, SU11 and their Secure-only locks where the Main Extension brings a floating-point unit, v8-M D1.2.15, and none for the coprocessors the library does not fit.
fn cppwrMask(c: core.Core) u32 {
    return switch (c) {
        .m33, .m55, .m85 => su10 | sus10 | su11 | sus11,
        else => 0,
    };
}

/// The two registers, ACTLR once per Security state.
pub const Icb = struct {
    const Self = @This();

    actlr: [2]u32 = @splat(0),
    cppwr: u32 = 0,

    /// ACTLR or CPPWR as a Security state sees it, the Non-secure view without the Secure-only bits, v8-M D1.2.1 D1.2.15, M55 TRM Table 5-13.
    pub fn readRegister(self: *const Self, c: core.Core, offset: u32, ns: bool) u32 {
        if (offset == cppwr) return self.cppwr & (if (ns) self.reachable() else 0xffff_ffff);
        if (!ns) return self.actlr[0];
        return (self.actlr[1] & ~unbanked(c)) | (self.actlr[0] & self.open(c));
    }

    /// Takes a write of ACTLR or CPPWR, keeping the bits the core keeps and the Security state may reach.
    pub fn writeRegister(self: *Self, c: core.Core, offset: u32, ns: bool, value: u32) void {
        if (offset == cppwr) {
            const reach = cppwrMask(c) & (if (ns) self.reachable() else 0xffff_ffff);
            self.cppwr = (self.cppwr & ~reach) | (value & reach);
        } else if (!ns) {
            self.actlr[0] = value & actlrMask(c);
        } else {
            self.actlr[1] = value & actlrMask(c) & ~unbanked(c);
            self.actlr[0] = (self.actlr[0] & ~self.open(c)) | (value & self.open(c));
        }
    }

    fn open(self: *const Self, c: core.Core) u32 {
        return if (self.actlr[0] & eventbusen_s != 0) 0 else unbanked(c) & eventbusen;
    }

    fn reachable(self: *const Self) u32 {
        return if (self.cppwr & sus10 != 0) 0 else su10 | su11;
    }
};
