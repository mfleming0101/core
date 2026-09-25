const std = @import("std");
const core = @import("core");

const firmware = @embedFile("fault.elf");

const Cpu = core.arm.Processor(.{ .cores = &.{.m3}, .Bus = core.memory.Regions });

var flash: [64 * 1024]u8 = @splat(0);
var ram: [8 * 1024]u8 = @splat(0);
var entries = [_]core.memory.Regions.Entry{
    .{ .memory = .{ .base = 0, .bytes = &flash, .writable = false } },
    .{ .memory = .{ .base = 0x2000_0000, .bytes = &ram, .writable = true } },
};

test "a load from an address nothing answers, with no fault handler installed, locks a Cortex-M3 up and explain says why" {
    var memory = try core.memory.Regions.adopt(&entries);
    try core.memory.elf.load(firmware, &memory);
    var records: [8]core.arm.trace.Record = undefined;
    var cpu = Cpu.init(&memory, .m3, .{}, try .init(&records));

    const ran = cpu.run(.{ .instructions = 1_000 });

    try std.testing.expectEqual(@as(core.arm.Ended, .stopped), ran.ended);
    try std.testing.expectEqual(@as(?core.arm.Stop, .data_fault), ran.stop);

    var text: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&text);
    try cpu.explain(&out, 2);
    try std.testing.expectEqualStrings(
        \\No memory answered the data access to 60000000 by the code 6800 at pc=0000000c. The core locked up.
        \\The last 2 lines of the trace:
        \\at      1  pc=0000000a code=0740 lsls r0, r0, #29 ; r0=60000000
        \\at      2  pc=0000000c code=6800 ldr r0, [r0, #0] ; mem=60000000 refused=no_memory
        \\CFSR=00008200 (PRECISERR BFARVALID) HFSR=00000000 MMFAR=00000000 BFAR=60000000
        \\
    , out.buffered());
}
