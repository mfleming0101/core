//! How a RISC-V hart asks for semihosting: an EBREAK between the two marker instructions the
//! convention spells, with the operation in a0 and the parameter block address in a1. The call
//! itself is in src/semihosting; this file only recognises the sequence and moves the
//! registers. The next run is what continues past the breakpoint.
const std = @import("std");
const calls = @import("../semihosting/calls.zig");

/// The slli x0, x0, 0x1f that must sit before the EBREAK of a semihosting call.
pub const before: u32 = 0x01f0_1013;
/// The srai x0, x0, 7 that must sit after it.
pub const after: u32 = 0x4070_5013;

/// The status a SYS_EXIT or SYS_EXIT_EXTENDED asked the run to end with.
pub const Exit = calls.Exit;

/// Whether the standing breakpoint sits between the two marker instructions.
pub fn trapped(cpu: anytype) bool {
    if (cpu.stop != .breakpoint) return false;
    return cpu.fetch32(cpu.state.pc -% 4) == before and cpu.fetch32(cpu.state.pc +% 4) == after;
}

/// Performs the call from a0 and a1, writes a0, and answers the exit status if it was SYS_EXIT.
pub fn call(cpu: anytype, out: *std.Io.Writer) !?Exit {
    switch (try calls.call(cpu, out, cpu.state.x[10], cpu.state.x[11])) {
        .value => |value| cpu.state.x[10] = value,
        .exit => |e| return e,
    }
    return null;
}
