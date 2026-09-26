//! Arm's Security Attribution Unit. Up to eight regions say which addresses are Non-secure and
//! which are Non-secure callable; everything else is Secure. check is what the processor
//! answers isa's attribute question from, and it is asked before the MPU on every guarded
//! access. The fixed system ranges of v8-M B10.2 are exempt, and a unit that is off
//! answers by SAU_CTRL.ALLNS alone. The secure fault status registers live here too, because
//! the unit is what fills them.
/// The first SAU register offset within the System Control Block window.
pub const first: u32 = 0xd0;
/// The last one.
pub const last: u32 = 0xe8;

/// SAU_CTRL, at an offset from the first.
pub const ctrl: u32 = 0x00;
/// SAU_TYPE, which reads the number of regions.
pub const rtype: u32 = 0x04;
/// SAU_RNR, the region a further write selects.
pub const rnr: u32 = 0x08;
/// SAU_RBAR, the base of the selected region.
pub const rbar: u32 = 0x0c;
/// SAU_RLAR, its limit and its enable and Non-secure callable bits.
pub const rlar: u32 = 0x10;
/// SFSR, the secure fault status register.
pub const sfsr: u32 = 0x14;
/// SFAR, the address of the access that raised one.
pub const sfar: u32 = 0x18;

/// The SAU_CTRL bit that turns the unit on.
pub const enable: u32 = 1 << 0;
/// The SAU_CTRL bit that makes everything Non-secure while the unit is off.
pub const allns: u32 = 1 << 1;
/// The SAU_RLAR bit that enables one region.
pub const region_enable: u32 = 1 << 0;
/// The SAU_RLAR bit that marks a region Non-secure callable.
pub const region_nsc: u32 = 1 << 1;

/// The most attribution regions a part may have.
pub const regions: u8 = 8;

/// The SFSR bit for an invalid integrity signature.
pub const invis: u32 = 1 << 1;
/// The SFSR bit for a branch into Secure memory that is not an entry point.
pub const invep: u32 = 1 << 0;
/// The SFSR bit for a data access the unit refused.
pub const auviol: u32 = 1 << 3;
/// The SFSR bit saying SFAR holds the address of that access.
pub const sfarvalid: u32 = 1 << 6;

/// What the unit says about an address: Non-secure, Non-secure callable, and which region said so.
pub const Attribution = struct {
    ns: bool,
    nsc: bool = false,
    region: ?u8 = null,
};

fn exempt(address: u32, fetch: bool) bool {
    if (fetch and address >= 0xe000_0000) return true;
    return address -% 0xe000_0000 < 0x4000 or
        address -% 0xe000_5000 < 0x1000 or
        address -% 0xe000_e000 < 0x1000 or
        address -% 0xe002_e000 < 0x1000 or
        address -% 0xe004_0000 < 0x2000 or
        address -% 0xe00f_f000 < 0x1000;
}

/// The Security Attribution Unit: the part's regions and the secure fault status registers.
pub const Sau = struct {
    const Self = @This();

    present: bool,
    faults: bool,
    count: u8,
    control: u32 = 0,
    number: u32 = 0,
    status: u32 = 0,
    address: u32 = 0,
    base: [regions]u32 = @splat(0),
    limit: [regions]u32 = @splat(0),

    /// An SAU with the part's number of regions for a core with the Security Extension, or a unit that marks everything Non-secure.
    pub fn init(present: bool, faults: bool, count: u8) Self {
        return .{ .present = present, .faults = faults, .count = count };
    }

    /// Attributes an address; the fixed ranges are exempt and two overlapping regions mean Secure.
    pub fn check(self: *const Self, address: u32, fetch: bool, secure: bool) Attribution {
        if (!self.present) return .{ .ns = true };
        if (fetch and address >= 0xf000_0000) return .{ .ns = false };
        if (exempt(address, fetch)) return .{ .ns = !secure };
        if (self.control & enable == 0) return .{ .ns = self.control & allns != 0 };
        var found: ?Attribution = null;
        for (self.limit[0..self.count], self.base[0..self.count], 0..) |limit, base, r| {
            if (limit & region_enable == 0) continue;
            if (address < (base & ~@as(u32, 0x1f)) or address > (limit | 0x1f)) continue;
            if (found != null) return .{ .ns = false };
            found = .{ .ns = limit & region_nsc == 0, .nsc = limit & region_nsc != 0, .region = @intCast(r) };
        }
        return found orelse .{ .ns = false };
    }

    /// The word a register read answers, or null on a core without the unit.
    pub fn readRegister(self: *const Self, offset: u32) ?u32 {
        if (!self.present or offset & 3 != 0) return null;
        const r = self.selected();
        return switch (offset) {
            ctrl => self.control,
            rtype => self.count,
            rnr => self.number,
            rbar => self.base[r],
            rlar => self.limit[r],
            sfsr => if (self.faults) self.status else 0,
            sfar => if (self.faults) self.address else 0,
            else => null,
        };
    }

    /// Takes a register write; a write to SFSR clears the bits it names.
    pub fn writeRegister(self: *Self, offset: u32, value: u32) bool {
        if (!self.present or offset & 3 != 0) return false;
        const r = self.selected();
        switch (offset) {
            ctrl => self.control = value & (if (self.count == 0) allns else enable | allns),
            rtype => {},
            rnr => self.number = value & (self.count -| 1),
            rbar => if (self.count != 0) {
                self.base[r] = value & ~@as(u32, 0x1f);
            },
            rlar => if (self.count != 0) {
                self.limit[r] = value & (~@as(u32, 0x1f) | region_nsc | region_enable);
            },
            sfsr => if (self.faults) {
                self.status &= ~value;
            },
            sfar => {},
            else => return false,
        }
        return true;
    }

    /// Sets bits in SFSR, for a fault the processor rather than the unit found.
    pub fn flag(self: *Self, bits: u32) void {
        if (self.present) self.status |= bits;
    }

    /// Records a refusal: an invalid entry point for a fetch, or SFAR and AUVIOL for an access.
    pub fn violation(self: *Self, address: u32, fetch: bool) void {
        if (!self.present) return;
        if (fetch) {
            self.status |= invep;
            return;
        }
        self.status |= auviol | sfarvalid;
        self.address = address;
    }

    fn selected(self: *const Self) u8 {
        return @intCast(self.number);
    }
};
