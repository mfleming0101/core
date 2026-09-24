const std = @import("std");
const core = @import("core");

const firmware = @embedFile("hello.elf");

const Cpu = core.arm.Processor(.{ .cores = &.{.m0plus}, .Bus = core.memory.Regions });

var flash: [64 * 1024]u8 = @splat(0);
var ram: [8 * 1024]u8 = @splat(0);
var entries = [_]core.memory.Regions.Entry{
    .{ .memory = .{ .base = 0, .bytes = &flash, .writable = false } },
    .{ .memory = .{ .base = 0x2000_0000, .bytes = &ram, .writable = true } },
};

fn runToExit(cpu: *Cpu, console: *std.Io.Writer) !u8 {
    while (true) {
        const ran = cpu.run(.{ .instructions = 1_000_000 });
        if (ran.ended != .stopped) return error.NoExit;
        if (!Cpu.semihosting.trapped(cpu)) return error.NoExit;
        if (try Cpu.semihosting.call(cpu, console)) |exit| return exit.status;
    }
}

test "a program prints over semihosting and exits with a status the host reads" {
    var memory = try core.memory.Regions.adopt(&entries);
    try core.memory.elf.load(firmware, &memory);
    var cpu = Cpu.init(&memory, .m0plus, .{});

    var text: [64]u8 = undefined;
    var console: std.Io.Writer = .fixed(&text);
    const status = try runToExit(&cpu, &console);

    try std.testing.expectEqualStrings("hello from the core\n", console.buffered());
    try std.testing.expectEqual(@as(u8, 0), status);
}
