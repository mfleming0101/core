//! Where each system block sits in the private peripheral bus, the megabyte at 0xe0000000
//! the processor answers for itself. region routes an address to the block that owns it, and
//! is asked both on the slow lane and when folding, since no part of this range may be
//! answered from a cached block. The Non-secure alias of a banked block sits a fixed offset
//! above the Secure one.
/// Where the private peripheral bus begins, v7-M B3.1.1.
pub const ppb_start: u32 = 0xe000_0000;
/// Where it ends, one megabyte later.
pub const ppb_end: u32 = 0xe010_0000;
/// Where the system timer registers sit.
pub const systick_base: u32 = 0xe000_e010;
const systick_size: u32 = 0x10;
/// Where ICTR, ACTLR and CPPWR sit, below the system timer.
pub const control_base: u32 = 0xe000_e000;
const control_size: u32 = 0x10;
/// The Interrupt Controller Type Register, at an offset from the control base.
pub const ictr: u32 = 0x04;
const scb = @import("scb.zig");
const nvic = @import("nvic.zig");
const dwt = @import("dwt.zig");
const impdef = @import("impdef.zig");
const ras = @import("ras.zig");
const ewic = @import("ewic.zig");
/// Where the System Control Block begins.
pub const scb_base = scb.base;
/// REVIDR, the word below the System Control Block, v8-M D1.2.222.
pub const revidr: u32 = 0xe000_ecfc;
/// Where the NVIC registers begin.
pub const nvic_base = nvic.base;
/// Where the DWT registers begin.
pub const dwt_base = dwt.base;
/// Where the instrumentation trace macrocell sits, which the library only swallows writes to.
pub const itm_base: u32 = 0xe000_0000;
const itm_size: u32 = 0x1000;

/// The offset at which a banked block answers for the Non-secure state.
pub const alias: u32 = 0x2_0000;

/// Which block answers an address, or memory where the address is outside the peripheral bus.
pub const Region = enum { memory, systick, systick_ns, control, control_ns, scb, scb_ns, revidr, revidr_ns, nvic, nvic_ns, itm, dwt, ras, impdef, ewic, ppb_unmapped };

/// Routes an address to the block that answers it; nothing in the peripheral bus is ever folded.
pub fn region(address: u32) Region {
    if (address < ppb_start or address >= ppb_end) return .memory;
    if (address -% systick_base < systick_size) return .systick;
    if (address -% control_base < control_size) return .control;
    if (address -% scb.base < scb.size) return .scb;
    if (address -% (scb.base + alias) < scb.size) return .scb_ns;
    if (address -% revidr < 4) return .revidr;
    if (address -% (revidr + alias) < 4) return .revidr_ns;
    if (address -% nvic.base < nvic.size) return .nvic;
    if (address -% (systick_base + alias) < systick_size) return .systick_ns;
    if (address -% (control_base + alias) < control_size) return .control_ns;
    if (address -% (nvic.base + alias) < nvic.size) return .nvic_ns;
    if (address -% itm_base < itm_size) return .itm;
    if (address -% dwt.base < dwt.size) return .dwt;
    if (address -% ras.base < ras.size) return .ras;
    if (address -% impdef.base < impdef.size) return .impdef;
    if (address -% ewic.base < ewic.size) return .ewic;
    return .ppb_unmapped;
}
