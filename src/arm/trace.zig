//! The Arm trace record and the text it becomes. The record holds the pc, the first fetched
//! halfword, the named registers the instruction changed, the address it touched, the cycle
//! it began at and the note. explain is the family's sentence for each of isa's seventeen
//! stops, naming the fault, the address or code that caused it and the manual's reason, which
//! is what the diagnosis cases check.
const std = @import("std");
const text = @import("../trace/text.zig");
const State = @import("isa").arm.State;
const Stop = @import("isa").arm.Stop;
const decode = @import("isa").arm.decode;
const disasm = @import("isa").generated.arm_disasm;

/// What a record was besides an instruction, shared with the RISC-V half.
pub const Note = text.Note;

/// r0 to r12, the selected stack pointer, lr and xpsr, which a record is indexed by.
pub const register_names = [_][]const u8{ "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11", "r12", "sp", "lr", "xpsr" };

fn namedAt(s: *const State, comptime i: usize) u32 {
    return switch (i) {
        13 => s.sp(),
        14 => s.lr,
        15 => s.xpsr,
        else => s.r[i],
    };
}

fn writeCode(w: *std.Io.Writer, code: ?u32) !void {
    if (code) |one| try w.print("{x:0>4}", .{one}) else try w.writeAll("----");
}

const family = @import("../trace/family.zig").Trace(.{
    .State = State,
    .names = register_names,
    .namedAt = namedAt,
    .writeCode = writeCode,
    .disasm = disasm,
    .Changed = u16,
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

/// Says why the core stopped, in the words of the manual, then the last records that led there.
pub fn explain(w: *std.Io.Writer, stop: Stop, ring: *const Ring, recap: u64, groups: decode.Groups) !void {
    const r = ring.last() orelse return;
    const code = r.codeOf() orelse 0;
    switch (stop) {
        .breakpoint => try w.print("The core stopped at BKPT #{d} at pc={x:0>8}.\n", .{ code & 0xff, r.pc }),
        .exception_return => try w.print("The exception return at pc={x:0>8} does not match the active exceptions or the mode of its frame. The core locked up.\n", .{r.pc}),
        .unrecoverable_exception => try w.print("The code {x:0>4} at pc={x:0>8} raised an exception the core could not take at HardFault priority. The core locked up.\n", .{ code, r.pc }),
        .undefined_instruction => try w.print("The code {x:0>4} at pc={x:0>8} is not an instruction of this architecture. The core locked up.\n", .{ code, r.pc }),
        .unimplemented => {
            try w.print("The code {x:0>4} at pc={x:0>8} is ", .{ code, r.pc });
            try disasm.write(w, code, r.pc, groups);
            try w.writeAll(", which this emulator does not implement yet.\n");
        },
        .not_t32_state => try w.print("The core reached pc={x:0>8} outside T32 state, because the address loaded into pc was even. The core locked up.\n", .{r.pc}),
        .fetch_fault => if (r.access) |vector| try w.print("No memory answered the vector fetch from {x:0>8}. The core locked up.\n", .{vector}) else try w.print("No memory answered the instruction fetch from pc={x:0>8}. The core locked up.\n", .{r.pc}),
        .data_fault => if (r.codeOf() == null) try w.print("No memory answered the stacking access to {x:0>8} for the exception at pc={x:0>8}. The core locked up.\n", .{ r.access orelse 0, r.pc }) else try w.print("No memory answered the data access to {x:0>8} by the code {x:0>4} at pc={x:0>8}. The core locked up.\n", .{ r.access orelse 0, code, r.pc }),
        .unaligned_access => try w.print("The code {x:0>4} at pc={x:0>8} accessed {x:0>8}, which is not aligned to the size of the access. The core locked up.\n", .{ code, r.pc, r.access orelse 0 }),
        .divide_by_zero => try w.print("The code {x:0>4} at pc={x:0>8} divided by zero with CCR.DIV_0_TRP set. The core locked up.\n", .{ code, r.pc }),
        .no_coprocessor => try w.print("The code {x:0>4} at pc={x:0>8} is a floating-point instruction, but CPACR leaves the FPU disabled. The core locked up.\n", .{ code, r.pc }),
        .authentication_failure => try w.print("The code {x:0>4} at pc={x:0>8} authenticated a pointer whose code did not match the one the key produces. The core locked up.\n", .{ code, r.pc }),
        .not_branch_target => try w.print("The code {x:0>4} at pc={x:0>8} is where a branch to a register landed, but it is not one of the instructions that may be. The core locked up.\n", .{ code, r.pc }),
        .secure_fault => try w.print("Non-secure code at pc={x:0>8} reached {x:0>8}, which the Security Attribution Unit marks Secure. The core locked up.\n", .{ r.pc, r.access orelse 0 }),
        .tail_predication => try w.print("The code {x:0>4} at pc={x:0>8} ends a loop without tail predication while FPSCR.LTPSIZE says a tail-predicated one is running. The core locked up.\n", .{ code, r.pc }),
        .fetch_violation => try w.print("The instruction fetch from pc={x:0>8} reached memory the Memory Protection Unit does not let this code execute. The core locked up.\n", .{r.pc}),
        .data_violation => try w.print("The code {x:0>4} at pc={x:0>8} accessed {x:0>8}, which the Memory Protection Unit does not let it. The core locked up.\n", .{ code, r.pc, r.access orelse 0 }),
    }
    try family.recap(w, ring, recap, groups);
}
