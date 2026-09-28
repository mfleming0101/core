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
/// The CPPWR bit that hides SU10 and SU11 from Non-secure state and sends their NOCP UsageFault to
/// Secure state.
pub const sus10: u32 = 1 << 21;
const su11: u32 = 1 << 22;
const sus11: u32 = 1 << 23;
const eventbusen: u32 = 1 << 14;
const eventbusen_s: u32 = 1 << 13;

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

fn unbanked(c: core.Core) u32 {
    return if (c == .m55 or c == .m85) eventbusen | eventbusen_s else 0;
}

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

    /// ACTLR or CPPWR as a Security state sees it, Non-secure without Secure-only bits, v8-M D1.2.1
    /// D1.2.15, M55 TRM Table 5-13.
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
