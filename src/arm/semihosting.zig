//! How an Arm core asks for semihosting: BKPT 0xab, with the operation in r0 and the
//! parameter block address in r1. The call itself is in src/semihosting; this file only
//! recognises the trap and moves the registers. Handling a call does not step over the
//! breakpoint, so the next run is what continues past it.
const std = @import("std");
const calls = @import("../semihosting/calls.zig");

/// The BKPT 0xab halfword a semihosting call traps on.
pub const bkpt: u16 = 0xbeab;

/// The status a SYS_EXIT or SYS_EXIT_EXTENDED asked the run to end with.
pub const Exit = calls.Exit;

/// Whether the standing breakpoint is a semihosting call rather than an ordinary one.
pub fn trapped(cpu: anytype) bool {
    return cpu.stop == .breakpoint and cpu.parcel(cpu.state.pc) == bkpt;
}

/// Performs the call from r0 and r1, writes r0, and answers the exit status if it was SYS_EXIT.
pub fn call(cpu: anytype, out: *std.Io.Writer) !?Exit {
    switch (try calls.call(cpu, out, cpu.state.r[0], cpu.state.r[1])) {
        .value => |value| cpu.state.r[0] = value,
        .exit => |e| return e,
    }
    return null;
}
