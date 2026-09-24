const std = @import("std");
const core = @import("core");

const firmware = @embedFile("crc.elf");

const Cpu = core.arm.Processor(.{ .cores = &.{.m0plus}, .Bus = core.memory.Regions });

var flash: [64 * 1024]u8 = @splat(0);
var ram: [8 * 1024]u8 = @splat(0);
var entries = [_]core.memory.Regions.Entry{
    .{ .memory = .{ .base = 0, .bytes = &flash, .writable = false } },
    .{ .memory = .{ .base = 0x2000_0000, .bytes = &ram, .writable = true } },
};

const Profile = struct {
    cycles: std.EnumArray(core.arm.Class, u64) = .initFill(0),
    instructions: std.EnumArray(core.arm.Class, u64) = .initFill(0),
    visits: [flash.len / 2]u32 = @splat(0),

    fn note(self: *Profile, one: core.arm.Step) void {
        const class = one.class orelse return;
        self.cycles.getPtr(class).* += one.charged;
        self.instructions.getPtr(class).* += 1;
        self.visits[one.address / 2] += 1;
    }

    fn hottest(self: *const Profile) u32 {
        return @intCast(2 * std.mem.indexOfMax(u32, &self.visits));
    }
};

test "stepping the CRC-32 firmware attributes every cycle to an instruction class and finds the address that ran most" {
    var memory = try core.memory.Regions.adopt(&entries);
    try core.memory.elf.load(firmware, &memory);
    var cpu = Cpu.init(&memory, .m0plus, .{});

    var profile: Profile = .{};
    while (true) {
        const one = cpu.step();
        profile.note(one);
        if (one.stop != null) break;
    }

    var total: u64 = 0;
    for (profile.cycles.values) |c| total += c;
    try std.testing.expectEqual(cpu.cycles, total);
    try std.testing.expectEqual(@as(u64, 656), cpu.instructions);
    try std.testing.expectEqual(@as(u64, 563), profile.instructions.get(.data_processing));
    try std.testing.expectEqual(@as(u64, 81), profile.instructions.get(.branch));
    try std.testing.expectEqual(@as(u64, 11), profile.instructions.get(.load));

    const address = profile.hottest();
    try std.testing.expectEqual(@as(u32, 72), profile.visits[address / 2]);
    try std.testing.expectEqual(@as(?u16, 0x2601), cpu.parcel(address));
}
