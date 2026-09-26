//! The RAS error record of the M55 and M85 at 0xE0005000, M55 and M85 TRM 11.6. The library
//! models no ECC, so no RAS event is ever logged: where the part fits ECC the record reads as
//! empty, with ERRADDR20 marking its address invalid and its write-one-to-clear bits having
//! nothing to clear, and without ECC it reads as zero. ERRIIDR names the core, M55 and M85 TRM
//! Table 5-2, v8-M D1.2.86.
const core = @import("core.zig");

/// Where the record begins.
pub const base: u32 = 0xe000_5000;
/// Its size.
pub const size: u32 = 0x1000;
/// RFSR, at an offset from the System Control Block.
pub const rfsr: u32 = 0x204;

const erriidr: u32 = 0xe10;
const errdevid: u32 = 0xfc8;

/// The word a register read answers, or null for a word the TRMs do not list.
pub fn readRegister(c: core.Core, ecc: bool, offset: u32) ?u32 {
    if (offset & 3 != 0) return null;
    return switch (offset) {
        0x000 => if (ecc) 0x101 else 0,
        0x008, 0x010, 0x018, 0x020...0x03c, 0xe00 => 0,
        0x01c => if (ecc) 0x7000_0000 else 0,
        erriidr => if (c == .m85) 0xd230_043b else 0xd220_043b,
        errdevid => @intFromBool(ecc),
        else => null,
    };
}

/// Whether the Non-secure state reads an offset as zero while AIRCR.BFHFNMINS is zero, which is all of them but ERRIIDR and ERRDEVID, M55 TRM 11.6.
pub fn gated(offset: u32) bool {
    return offset != erriidr and offset != errdevid;
}
