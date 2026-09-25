const std = @import("std");
const core = @import("core");

const Lines = core.memory.Lines;
const Width = core.memory.Width;

const Cpu = core.arm.Processor(.{ .cores = &.{.m0plus}, .Bus = core.memory.Regions });

const Port = struct {
    text: [32]u8 = undefined,
    len: usize = 0,

    fn device(self: *Port) core.memory.Device {
        return .{ .context = self, .read = read, .write = write };
    }

    fn read(context: *anyopaque, _: u32, _: Width, _: *Lines) ?u32 {
        const self: *Port = @ptrCast(@alignCast(context));
        return @intCast(self.len);
    }

    fn write(context: *anyopaque, _: u32, _: Width, value: u32, _: *Lines) ?void {
        const self: *Port = @ptrCast(@alignCast(context));
        if (self.len == self.text.len) return null;
        self.text[self.len] = @truncate(value);
        self.len += 1;
    }
};

const ldr_r1_literal: u16 = 0x4904;
const movs_r0_h: u16 = 0x2048;
const str_r0_r1: u16 = 0x6008;
const movs_r0_i: u16 = 0x2069;
const ldr_r1_r1: u16 = 0x6809;
const bkpt_0: u16 = 0xbe00;

var bytes: [4096]u8 = @splat(0);
var port: Port = .{};
var entries = [_]core.memory.Regions.Entry{
    .{ .memory = .{ .base = 0, .bytes = &bytes, .writable = true } },
    .{ .device = .{ .base = 0x4000_0000, .size = 4, .device = port.device() } },
};

fn word(at: u32, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}

fn code(at: u32, halfwords: []const u16) void {
    for (halfwords, 0..) |h, i| std.mem.writeInt(u16, bytes[at + 2 * i ..][0..2], h, .little);
}

test "the smallest device: one register, and every byte the program stores to it comes out on the host side" {
    word(0x0, 0x1000);
    word(0x4, 0x8 | 1);
    code(0x8, &.{
        ldr_r1_literal,
        movs_r0_h,
        str_r0_r1,
        movs_r0_i,
        str_r0_r1,
        ldr_r1_r1,
        bkpt_0,
    });
    word(0x1c, 0x4000_0000);

    var memory = try core.memory.Regions.adopt(&entries);
    var cpu = Cpu.init(&memory, .m0plus, .{}, .{});

    const ran = cpu.run(.{ .instructions = 100 });

    try std.testing.expectEqual(@as(?core.arm.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqualStrings("Hi", port.text[0..port.len]);
    try std.testing.expectEqual(@as(u32, 2), cpu.state.r[1]);
}
