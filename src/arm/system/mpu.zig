//! Arm's Memory Protection Unit, modelled once for both forms. A v7-M region is a base and a
//! power-of-two size with subregion disables and an AP field; a v8-M region is a base and a
//! limit with its permissions in the base word. permits answers both, and the processor asks
//! it twice: once per access on the slow lane, and once per fold, so a block never straddles
//! a permission change. A core with no unit reads zero across the window and refuses nothing.
const contract = @import("../../contract.zig");

/// The first MPU register offset within the System Control Block window.
pub const first: u32 = 0x90;
/// The last one.
pub const last: u32 = 0xc4;

/// MPU_TYPE, at an offset from the first.
pub const mpu_type: u32 = 0x00;
/// MPU_CTRL, at an offset from the first.
pub const ctrl: u32 = 0x04;
/// MPU_RNR, the region a further write selects.
pub const rnr: u32 = 0x08;
/// MPU_RBAR, the base of the selected region and its v8-M attributes.
pub const rbar: u32 = 0x0c;
/// MPU_RLAR on v8-M, MPU_RASR on v7-M: the limit or size and attributes.
pub const rlar: u32 = 0x10;
/// The first of the v8-M aliases that reach the regions beside the selected one.
pub const alias_first: u32 = 0x14;
/// The last of them.
pub const alias_last: u32 = 0x28;
/// MPU_MAIR0, held for reading back on v8-M.
pub const mair0: u32 = 0x30;
/// MPU_MAIR1, held for reading back on v8-M.
pub const mair1: u32 = 0x34;

/// The MPU_CTRL bit that turns the unit on.
pub const enable: u32 = 1 << 0;
/// The MPU_CTRL bit that keeps the unit on for a negative-priority handler.
pub const hfnmiena: u32 = 1 << 1;
/// The MPU_CTRL bit that leaves the default map under privileged access.
pub const privdefena: u32 = 1 << 2;

/// The bit that enables one protection region.
pub const region_enable: u32 = 1 << 0;

/// The v8.1-M MPU_RLAR bit that forbids privileged execution from the region.
pub const privileged_never: u32 = 1 << 4;

/// The v8-M MPU_RBAR bit that lets unprivileged code reach the region.
pub const unprivileged: u32 = 1 << 1;
/// The v8-M MPU_RBAR bit that forbids writes to the region.
pub const read_only: u32 = 1 << 2;
/// The v8-M MPU_RBAR bit that forbids fetches from the region.
pub const execute_never: u32 = 1 << 0;

/// Where the v7-M MPU_RASR size field begins.
pub const size_shift: u5 = 1;
/// Where the v7-M MPU_RASR subregion disable field begins.
pub const srd_shift: u5 = 8;
/// Where the v7-M MPU_RASR access permission field begins.
pub const ap_shift: u5 = 24;
/// Where the v7-M MPU_RASR execute-never bit sits.
pub const never_shift: u5 = 28;

/// What a caller may do at an address, which is what isa asks for a stack limit check.
pub const Reach = struct { read: bool, write: bool };

/// The Memory Protection Unit, in the v7-M and v8-M forms at once, with room for capacity regions, a power of two or zero.
pub fn Mpu(comptime capacity: u8) type {
    return struct {
        const Self = @This();
        const numbers: u8 = if (capacity == 0) 0 else capacity - 1;

        count: u8,
        v8: bool,
        pxn: bool,
        control: u32 = 0,
        number: u32 = 0,
        base: [capacity]u32 = @splat(0),
        limit: [capacity]u32 = @splat(0),
        mair: [2]u32 = @splat(0),

        /// An MPU of the core's form with the part's number of regions, or a unit that is never enabled where it has none.
        pub fn init(count: u8, v8: bool, pxn: bool) Self {
            return .{ .count = count, .v8 = v8, .pxn = pxn };
        }

        /// Whether the unit is fitted and MPU_CTRL.ENABLE is set.
        pub fn enabled(self: *const Self) bool {
            return self.count != 0 and self.control & enable != 0;
        }

        /// Whether an access is allowed; a vector read uses the default map, v7-M B3.5.3.
        pub fn permits(self: *const Self, address: u32, privileged: bool, access: contract.Kind) bool {
            if (access == .vector) return true;
            return if (self.v8) self.eight(address, privileged, access) else self.seven(address, privileged, access);
        }

        fn background(self: *const Self, privileged: bool) bool {
            return privileged and self.control & privdefena != 0;
        }

        fn eight(self: *const Self, address: u32, privileged: bool, access: contract.Kind) bool {
            var found: ?usize = null;
            for (0..self.count) |i| {
                if (self.limit[i] & region_enable == 0) continue;
                if (address < (self.base[i] & ~@as(u32, 0x1f)) or address > (self.limit[i] | 0x1f)) continue;
                if (found != null) return false;
                found = i;
            }
            const region_of = found orelse return self.background(privileged);
            const attributes = self.base[region_of];
            if (!privileged and attributes & unprivileged == 0) return false;
            return switch (access) {
                .fetch => attributes & execute_never == 0 and
                    !(privileged and self.pxn and self.limit[region_of] & privileged_never != 0),
                .write => attributes & read_only == 0,
                else => true,
            };
        }

        fn seven(self: *const Self, address: u32, privileged: bool, access: contract.Kind) bool {
            var found: ?u32 = null;
            for (0..self.count) |i| {
                const attributes = self.limit[i];
                if (attributes & region_enable == 0) continue;
                const power: u5 = @intCast((attributes >> size_shift) & 0x1f);
                if (power < 4) continue;
                const span = @as(u64, 1) << (power + 1);
                const offset = @as(u64, address) -% (self.base[i] & ~@as(u32, @truncate(span - 1)));
                if (offset >= span) continue;
                if (power >= 7 and attributes >> srd_shift & (@as(u32, 1) << @intCast(offset >> (power - 2))) != 0) continue;
                found = attributes;
            }
            const attributes = found orelse return self.background(privileged);
            if (access == .fetch and attributes >> never_shift & 1 != 0) return false;
            return switch ((attributes >> ap_shift) & 7) {
                1 => privileged,
                2 => privileged or access != .write,
                3 => true,
                5 => privileged and access != .write,
                6, 7 => access != .write,
                else => false,
            };
        }

        fn selected(self: *const Self, offset: u32) u8 {
            const n: u8 = @intCast(self.number & numbers);
            if (!self.v8 or offset < alias_first or offset > alias_last) return n;
            return (n & ~@as(u8, 3)) | @as(u8, @intCast((offset - alias_first) / 8 + 1)) & numbers;
        }

        fn region(self: *const Self) u32 {
            return if (self.v8) 0 else self.number & 0xf;
        }

        /// The word a register read answers; a core with no unit reads zero across the whole window.
        pub fn readRegister(self: *const Self, offset: u32) ?u32 {
            if (offset & 3 != 0) return null;
            if (self.count == 0) return if (offset <= last) 0 else null;
            const r = self.selected(offset);
            return switch (offset) {
                mpu_type => @as(u32, self.count) << 8,
                ctrl => self.control,
                rnr => self.number,
                rbar, alias_first, alias_first + 8, alias_first + 16 => self.base[r] | self.region(),
                rlar, alias_first + 4, alias_first + 12, alias_last => self.limit[r],
                mair0 => if (self.v8) self.mair[0] else 0,
                mair1 => if (self.v8) self.mair[1] else 0,
                else => if (offset <= last) 0 else null,
            };
        }

        /// Takes a register write, a v7-M MPU_RBAR with its VALID bit also selecting the region.
        pub fn writeRegister(self: *Self, offset: u32, value: u32) bool {
            if (offset & 3 != 0) return false;
            if (self.count == 0) return offset <= last;
            const r = self.selected(offset);
            switch (offset) {
                mpu_type => {},
                ctrl => self.control = value & (enable | hfnmiena | privdefena),
                rnr => self.number = value & numbers,
                rbar, alias_first, alias_first + 8, alias_first + 16 => self.setBase(r, value),
                rlar, alias_first + 4, alias_first + 12, alias_last => self.limit[r] = value & self.attributeMask(),
                mair0 => if (self.v8) {
                    self.mair[0] = value;
                },
                mair1 => if (self.v8) {
                    self.mair[1] = value;
                },
                else => return offset <= last,
            }
            return true;
        }

        fn attributeMask(self: *const Self) u32 {
            return if (self.v8) 0xffff_ffff else 0x173f_ff3f;
        }

        fn setBase(self: *Self, r: u8, value: u32) void {
            if (self.v8) {
                self.base[r] = value;
                return;
            }
            if (value & 0x10 == 0) {
                self.base[r] = value & ~@as(u32, 0x1f);
                return;
            }
            self.number = value & numbers;
            self.base[@intCast(self.number)] = value & ~@as(u32, 0x1f);
        }
    };
}
