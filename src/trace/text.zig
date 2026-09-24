//! The line one trace record renders as, shared by both families. A family brings the record,
//! the names of its registers and its disassembler; this file decides the shape of the line
//! and carries the note, the few bits a record keeps about what it was besides an instruction.
const std = @import("std");

/// What a record was besides an instruction: how it ended, and the entry number and latency.
pub const Note = packed struct(u32) {
    kind: Kind = .retired,
    refused: Refusal = .none,
    fetched: bool = false,
    number: u11 = 0,
    latency: u16 = 0,

    /// Whether the record retired an instruction, entered a handler, took an interrupt or returned.
    pub const Kind = enum(u2) { retired, entry, irq, exit };
    /// Which unit refused the access this record was stopped by, if one did.
    pub const Refusal = enum(u2) { none, no_memory, protection, secure };

    fn silent(self: Note) bool {
        return self.kind == .retired and self.refused == .none;
    }
};

/// Renders one record: the cycle, the pc, the code disassembled, the registers changed and the note.
pub fn writeLine(w: *std.Io.Writer, names: []const []const u8, r: anytype, groups: anytype, disassemble: anytype) !void {
    try w.print("at {d:>6}  pc={x:0>8} code=", .{ r.cycles, r.pc });
    try r.writeCode(w);
    if (r.codeOf()) |code| {
        try w.writeByte(' ');
        try disassemble(w, r, code, groups);
    }
    if (r.changed != 0 or r.access != null or !r.note.silent()) try w.writeAll(" ;");
    for (names, 0..) |name, i| {
        if ((r.changed >> @intCast(i)) & 1 != 0) try w.print(" {s}={x:0>8}", .{ name, r.values[i] });
    }
    if (r.access) |address| try w.print(" mem={x:0>8}", .{address});
    if (r.note.refused != .none) try w.print(" refused={s}", .{@tagName(r.note.refused)});
    switch (r.note.kind) {
        .retired => {},
        .entry => try w.print(" entry={d} latency={d}", .{ r.note.number, r.note.latency }),
        .irq => try w.print(" irq={d} latency={d}", .{ r.note.number, r.note.latency }),
        .exit => try w.print(" return latency={d}", .{r.note.latency}),
    }
    try w.writeByte('\n');
}

/// Renders the last n records the ring holds, oldest first.
pub fn writeLast(w: *std.Io.Writer, names: []const []const u8, ring: anytype, n: u64, groups: anytype, disassemble: anytype) !void {
    var back = @min(ring.written, n, ring.records.len);
    while (back > 0) {
        back -= 1;
        try writeLine(w, names, ring.at(back).?, groups, disassemble);
    }
}
