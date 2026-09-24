const std = @import("std");
const Clock = @import("../../src/memory/clock.zig").Clock;

test "a span charged in pieces costs what it costs in one" {
    for ([_]u64{ 64_000_000, 160_000_000, 3_000_000, 77_000_000 }) |hz| {
        var whole: Clock = .at(hz);
        var pieces: Clock = .at(hz);
        whole.charge(37 * 512);
        for (0..512) |_| pieces.charge(37);
        try std.testing.expectEqual(whole.ps, pieces.ps);
        try std.testing.expectEqual(whole.owed, pieces.owed);
    }
}

test "the cycles a span is worth cover it and are never none" {
    const clock: Clock = .at(77_000_000);
    try std.testing.expectEqual(1, clock.cyclesTo(0));
    try std.testing.expectEqual(1, clock.cyclesTo(1));
    var charged: Clock = .at(77_000_000);
    charged.charge(clock.cyclesTo(578_125));
    try std.testing.expect(charged.ps >= 578_125);
}

test "banking a rate keeps the picoseconds spent at the old one" {
    var clock: Clock = .at(8_000_000);
    clock.charge(200);
    const spent = clock.ps;
    clock.bank(0);
    try std.testing.expectEqual(8_000_000, clock.hz);
    clock.bank(160_000_000);
    try std.testing.expectEqual(spent, clock.ps);
    clock.charge(160);
    try std.testing.expectEqual(spent + 1_000_000, clock.ps);
}
