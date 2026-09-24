const std = @import("std");
const core = @import("core");
const Timer = @import("timer_device.zig").Timer;

const firmware = @embedFile("timer.elf");

const Cpu = core.arm.Processor(.{ .cores = &.{.m0plus}, .Bus = core.memory.Regions });

const board =
    \\.{
    \\    .core = .m0plus,
    \\    .regions = .{
    \\        .{ .base = 0x00000000, .size = 0x10000, .writable = false },
    \\        .{ .base = 0x20000000, .size = 0x2000, .writable = true },
    \\    },
    \\    .devices = .{
    \\        .{ .model = "timer", .base = 0x40010000, .size = 0x10 },
    \\    },
    \\}
;

fn makeTimer(arena: std.mem.Allocator) std.mem.Allocator.Error!core.memory.Device {
    const timer = try arena.create(Timer);
    timer.* = .{ .line = 0 };
    return timer.device();
}

const registry: core.memory.map.Registry = .{ .models = &.{
    .{ .name = "timer", .make = makeTimer },
} };

const NoImages = struct {
    pub fn load(_: *NoImages, _: []const u8, _: []u8) core.memory.map.Image!usize {
        return error.Missing;
    }
};

test "a board described in .zon builds the same bus, with the timer looked up by model name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const map = try std.zon.parse.fromSliceAlloc(core.memory.map.Map, arena.allocator(), board, null, .{});

    var images: NoImages = .{};
    var blame: core.memory.map.Blame = .{};
    var memory = core.memory.map.build(arena.allocator(), registry, map, &images, &blame) catch |fault| {
        std.debug.print("{s} at {x}: {s}\n", .{ blame.name, blame.base, core.memory.map.message(fault) });
        return fault;
    };
    try core.memory.elf.load(firmware, &memory);
    var cpu = Cpu.init(&memory, .m0plus, .{});

    const ran = cpu.run(.{ .instructions = 100_000 });

    try std.testing.expectEqual(@as(?core.arm.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(@as(u32, 5), cpu.state.r[0]);
}
