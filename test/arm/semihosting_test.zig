const std = @import("std");
const Word = @import("../../src/contract.zig").Word;
const State = @import("isa").arm.State;
const semihosting = @import("../../src/arm/semihosting.zig");

const Caller = struct {
    state: State = .{},
    bytes: [64]u8 = @splat(0),

    fn at(self: *Caller, address: u32, comptime n: usize) ?*[n]u8 {
        if (@as(u64, address) + n > self.bytes.len) return null;
        return self.bytes[address..][0..n];
    }

    pub fn peek(self: *Caller, comptime width: u8, address: u32) ?Word(width) {
        return std.mem.readInt(Word(width), self.at(address, width) orelse return null, .little);
    }

    fn block(self: *Caller, address: u32, words: []const u32) void {
        for (words, 0..) |w, i| std.mem.writeInt(u32, self.at(address + @as(u32, @intCast(i)) * 4, 4).?, w, .little);
    }

    fn call(self: *Caller, op: u32, arg: u32, out: *std.Io.Writer) !?semihosting.Exit {
        self.state.r[0] = op;
        self.state.r[1] = arg;
        return semihosting.call(self, out);
    }
};

fn writer(buffer: []u8) std.Io.Writer {
    return .fixed(buffer);
}

test "SYS_WRITE0 writes the string up to its terminator and SYS_WRITEC writes one byte, semihosting 6.5 6.4" {
    var buffer: [16]u8 = undefined;
    var w = writer(&buffer);
    var c: Caller = .{};
    @memcpy(c.bytes[8..14], "hello\x00");
    try std.testing.expect(try c.call(0x04, 8, &w) == null);
    try std.testing.expect(try c.call(0x03, 10, &w) == null);
    try std.testing.expectEqualStrings("hellol", w.buffered());
}

test "SYS_WRITE writes the block and answers with the bytes it could not write, semihosting 6.6" {
    var buffer: [16]u8 = undefined;
    var w = writer(&buffer);
    var c: Caller = .{};
    @memcpy(c.bytes[16..19], "abc");
    c.block(0, &.{ 1, 16, 3 });
    try std.testing.expect(try c.call(0x05, 0, &w) == null);
    try std.testing.expectEqual(@as(u32, 0), c.state.r[0]);
    try std.testing.expectEqualStrings("abc", w.buffered());
    c.block(0, &.{ 1, 60, 8 });
    try std.testing.expect(try c.call(0x05, 0, &w) == null);
    try std.testing.expectEqual(@as(u32, 4), c.state.r[0]);
}

test "SYS_OPEN answers a handle for the console and refuses any other file, semihosting 6.1" {
    var buffer: [1]u8 = undefined;
    var w = writer(&buffer);
    var c: Caller = .{};
    @memcpy(c.bytes[16..19], ":tt");
    c.block(0, &.{ 16, 4, 3 });
    try std.testing.expect(try c.call(0x01, 0, &w) == null);
    try std.testing.expectEqual(@as(u32, 1), c.state.r[0]);
    @memcpy(c.bytes[16..19], "a.c");
    try std.testing.expect(try c.call(0x01, 0, &w) == null);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), c.state.r[0]);
    c.block(0, &.{ 16, 4, 8 });
    try std.testing.expect(try c.call(0x01, 0, &w) == null);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), c.state.r[0]);
}

test "the operations a C library asks about the console during startup answer without a file system, semihosting 6.2 6.9 6.12" {
    var buffer: [1]u8 = undefined;
    var w = writer(&buffer);
    var c: Caller = .{};
    c.block(0, &.{1});
    inline for (.{ 0x02, 0x09, 0x0c, 0x99 }, .{ 0, 1, 0xffff_ffff, 0xffff_ffff }) |op, answer| {
        try std.testing.expect(try c.call(op, 0, &w) == null);
        try std.testing.expectEqual(@as(u32, answer), c.state.r[0]);
    }
}

test "a handle SYS_OPEN never returned is refused by the calls that take one, semihosting 6.2 6.6 6.9" {
    var buffer: [16]u8 = undefined;
    var w = writer(&buffer);
    var c: Caller = .{};
    @memcpy(c.bytes[16..19], "abc");
    c.block(0, &.{ 0xffff_ffff, 16, 3 });
    try std.testing.expect(try c.call(0x05, 0, &w) == null);
    try std.testing.expectEqual(@as(u32, 3), c.state.r[0]);
    try std.testing.expectEqualStrings("", w.buffered());
    inline for (.{ 0x02, 0x09 }) |op| {
        try std.testing.expect(try c.call(op, 0, &w) == null);
        try std.testing.expectEqual(@as(u32, 0xffff_ffff), c.state.r[0]);
    }
}

test "SYS_EXIT reports success or failure and SYS_EXIT_EXTENDED carries the status of the run, semihosting 6.17 6.20" {
    var buffer: [1]u8 = undefined;
    var w = writer(&buffer);
    var c: Caller = .{};
    try std.testing.expectEqual(@as(u8, 0), (try c.call(0x18, 0x0002_0026, &w)).?.status);
    try std.testing.expectEqual(@as(u8, 1), (try c.call(0x18, 0x0002_0023, &w)).?.status);
    c.block(0, &.{ 0x0002_0026, 7 });
    try std.testing.expectEqual(@as(u8, 7), (try c.call(0x20, 0, &w)).?.status);
    c.block(0, &.{ 0x0002_0023, 7 });
    try std.testing.expectEqual(@as(u8, 1), (try c.call(0x20, 0, &w)).?.status);
}

test "a call whose parameter block the memory does not answer fails rather than reading anything" {
    var buffer: [1]u8 = undefined;
    var w = writer(&buffer);
    var c: Caller = .{};
    try std.testing.expect(try c.call(0x01, 0x1000, &w) == null);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), c.state.r[0]);
    try std.testing.expect(try c.call(0x05, 0x1000, &w) == null);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), c.state.r[0]);
    try std.testing.expectEqualStrings("", w.buffered());
    try std.testing.expectEqual(@as(u8, 1), (try c.call(0x20, 0x1000, &w)).?.status);
}
