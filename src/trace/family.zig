//! The record and the ring one family's trace is kept in, written once for both. A family
//! brings its state type, the names of the registers a record indexes, how to read one, how
//! wide the changed word is, how a code is printed and its disassembler; this file builds the
//! record, the ring over it, the two line renderers and the recap explain ends with.
const std = @import("std");
const text = @import("text.zig");

/// The trace of one family over its state, register names, changed width and disassembler.
pub fn Trace(comptime options: anytype) type {
    const names = options.names;
    const State = options.State;
    return struct {
        /// The register values a record compares against to find what an instruction changed.
        pub const Registers = [names.len]u32;

        /// The named registers as they stand, which a fresh ring starts from.
        pub fn snapshot(s: *const State) Registers {
            var out: Registers = undefined;
            inline for (0..names.len) |i| out[i] = options.namedAt(s, i);
            return out;
        }

        /// One line of the ring: the pc, the code, the registers changed, the address touched and the note.
        pub const Record = struct {
            pc: u32,
            code: u32,
            changed: options.Changed,
            values: Registers,
            access: ?u32,
            cycles: u64,
            note: text.Note,

            /// Fills a slot, recording only the registers whose values differ from the last snapshot.
            pub fn write(self: *Record, pc: u32, code: ?u32, last: *Registers, s: *const State, access: ?u32, cycles: u64, note: text.Note) void {
                self.pc = pc;
                self.cycles = cycles;
                self.note = note;
                self.note.fetched = code != null;
                self.code = code orelse 0;
                self.access = access;
                var changed: options.Changed = 0;
                inline for (0..names.len) |i| {
                    const value = options.namedAt(s, i);
                    if (value != last[i]) {
                        changed |= 1 << i;
                        last[i] = value;
                        self.values[i] = value;
                    }
                }
                self.changed = changed;
            }

            /// The code, or null where the record fetched none.
            pub fn codeOf(self: Record) ?u32 {
                return if (self.note.fetched) self.code else null;
            }

            /// Renders the code the way the family prints one, or dashes where none was fetched.
            pub fn writeCode(self: Record, w: *std.Io.Writer) !void {
                try options.writeCode(w, self.codeOf());
            }
        };

        /// The ring of these records, which a caller hands the processor at init.
        pub const Ring = @import("ring.zig").Ring(Record);

        fn writeAsm(w: *std.Io.Writer, r: Record, code: u32, groups: anytype) !void {
            try options.disasm.write(w, code, r.pc, groups);
        }

        /// Renders one record as a line of disassembly with the registers it changed.
        pub fn writeLine(w: *std.Io.Writer, r: Record, groups: anytype) !void {
            try text.writeLine(w, &names, r, groups, writeAsm);
        }

        /// Renders the last n records the ring holds, oldest first.
        pub fn writeLast(w: *std.Io.Writer, ring: *const Ring, n: u64, groups: anytype) !void {
            try text.writeLast(w, &names, ring, n, groups, writeAsm);
        }

        /// The tail of explain: how many trace lines follow, then those lines.
        pub fn recap(w: *std.Io.Writer, ring: *const Ring, n: u64, groups: anytype) !void {
            if (n == 0) return;
            try w.print("The last {d} lines of the trace:\n", .{@min(ring.written, n, ring.records.len)});
            try writeLast(w, ring, n, groups);
        }
    };
}
