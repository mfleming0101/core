const std = @import("std");
const Word = @import("../../src/contract.zig").Word;
const State = @import("isa").riscv.State;
const Stop = @import("isa").riscv.Stop;
const semihosting = @import("../../src/riscv/semihosting.zig");

const Caller = struct {
    state: State = .{},
    stop: ?Stop = .breakpoint,
    bytes: [64]u8 = @splat(0),

    fn at(self: *Caller, address: u32, comptime n: usize) ?*[n]u8 {
        if (@as(u64, address) + n > self.bytes.len) return null;
        return self.bytes[address..][0..n];
    }

    pub fn peek(self: *Caller, comptime width: u8, address: u32) ?Word(width) {
        return std.mem.readInt(Word(width), self.at(address, width) orelse return null, .little);
    }

    pub fn fetch32(self: *Caller, address: u32) ?u32 {
        return self.peek(4, address);
    }

    fn sequence(self: *Caller, pc: u32, before: u32, after: u32) void {
        self.state.pc = pc;
        std.mem.writeInt(u32, self.at(pc - 4, 4).?, before, .little);
        std.mem.writeInt(u32, self.at(pc + 4, 4).?, after, .little);
    }

    fn call(self: *Caller, op: u32, arg: u32, out: *std.Io.Writer) !?semihosting.Exit {
        self.state.x[10] = op;
        self.state.x[11] = arg;
        return semihosting.call(self, out);
    }
};

test "a semihosting call is an EBREAK between the two instructions that write x0, and an EBREAK alone is not" {
    var c: Caller = .{};
    c.sequence(8, semihosting.before, semihosting.after);
    try std.testing.expect(semihosting.trapped(&c));
    c.sequence(8, semihosting.before, 0x0000_0013);
    try std.testing.expect(!semihosting.trapped(&c));
    c.sequence(8, semihosting.before, semihosting.after);
    c.stop = .unimplemented;
    try std.testing.expect(!semihosting.trapped(&c));
}

test "the pair around the call are SLLI and SRAI on x0, which write nothing wherever they are executed" {
    try std.testing.expectEqual(@as(u32, 0x01f0_1013), semihosting.before);
    try std.testing.expectEqual(@as(u32, 0x4070_5013), semihosting.after);
}

test "the operation number is in a0 and its parameter in a1, and the answer comes back in a0" {
    var buffer: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    var c: Caller = .{};
    @memcpy(c.bytes[8..14], "hello\x00");
    try std.testing.expect(try c.call(0x04, 8, &w) == null);
    try std.testing.expectEqualStrings("hello", w.buffered());
    try std.testing.expectEqual(@as(u32, 0), c.state.x[10]);
    try std.testing.expectEqual(@as(u32, 8), c.state.x[11]);
}

test "SYS_EXIT carries the status of the run out of the call" {
    var buffer: [1]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    var c: Caller = .{};
    try std.testing.expectEqual(@as(u8, 0), (try c.call(0x18, 0x0002_0026, &w)).?.status);
    try std.testing.expectEqual(@as(u8, 1), (try c.call(0x18, 0x0002_0023, &w)).?.status);
}
