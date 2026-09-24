//! The RISC-V trace record and the text it becomes. The record holds the pc, the code, the
//! ABI-named registers the instruction changed, the address it touched, the cycle it began at
//! and the note. explain is the family's own sentence for each stop: a breakpoint, an
//! instruction the library does not implement, or a trap at the trap vector that the hart
//! would take for ever.
const std = @import("std");
const text = @import("../trace/text.zig");
const State = @import("isa").riscv.State;
const Stop = @import("isa").riscv.Stop;
const decode = @import("isa").riscv.decode;
const disasm = @import("isa").generated.riscv_disasm;

/// What a record was besides an instruction, shared with the Arm half.
pub const Note = text.Note;

/// The ABI names of x1 to x31, which a record's values and changed bits are indexed by.
pub const register_names = @import("isa").sem.riscv.abi[1..].*;

fn namedAt(s: *const State, comptime i: usize) u32 {
    return s.x[i + 1];
}

fn writeCode(w: *std.Io.Writer, code: ?u32) !void {
    const one = code orelse return w.writeAll("--------");
    if (decode.escapes(one)) try w.print("{x:0>8}", .{one}) else try w.print("{x:0>4}", .{one});
}

const family = @import("../trace/family.zig").Trace(.{
    .State = State,
    .names = register_names,
    .namedAt = namedAt,
    .writeCode = writeCode,
    .disasm = disasm,
    .Changed = u32,
});

/// The register values a record compares against to find what an instruction changed.
pub const Registers = family.Registers;
/// The named registers as they stand, which a fresh ring starts from.
pub const snapshot = family.snapshot;
/// One line of the ring: the pc, the code, the registers changed, the address touched and the note.
pub const Record = family.Record;
/// The ring of these records, which a caller hands the processor at init.
pub const Ring = family.Ring;
/// Renders one record as a line of disassembly with the registers it changed.
pub const writeLine = family.writeLine;
/// Renders the last n records the ring holds, oldest first.
pub const writeLast = family.writeLast;

/// Says why the hart stopped, in the words of the manual, then the last records that led there.
pub fn explain(w: *std.Io.Writer, stop: Stop, ring: *const Ring, recap: u64, groups: decode.Groups) !void {
    const r = ring.last() orelse return;
    const code = r.codeOf() orelse 0;
    switch (stop) {
        .breakpoint => try w.print("The core stopped at EBREAK at pc={x:0>8}.\n", .{r.pc}),
        .unimplemented => {
            try w.print("The code {x:0>8} at pc={x:0>8} is ", .{ code, r.pc });
            try disasm.write(w, code, r.pc, groups);
            try w.writeAll(", which this emulator does not implement yet.\n");
        },
        .unrecoverable_trap => if (r.codeOf() == null)
            try w.print("The trap handler at pc={x:0>8} could not be fetched, and mtvec has nowhere else to send a trap. The core locked up.\n", .{r.pc})
        else
            try w.print("The code {x:0>8} at pc={x:0>8} is the first instruction of the trap handler and it trapped, so the hart would take that trap for ever. The core locked up.\n", .{ code, r.pc }),
    }
    try family.recap(w, ring, recap, groups);
}
