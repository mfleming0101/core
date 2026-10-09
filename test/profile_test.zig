const std = @import("std");
const profile = @import("../src/profile.zig");

test "a zone's own time is its span less the zones begun inside it" {
    if (!profile.enabled) return error.SkipZigTest;
    profile.reset();
    const outer = profile.begin(.board_run);
    const inner = profile.begin(.chip_run_to);
    profile.end(inner);
    profile.end(outer);
    const board = @intFromEnum(profile.Zone.board_run);
    const chip = @intFromEnum(profile.Zone.chip_run_to);
    try std.testing.expectEqual(1, profile.calls[board]);
    try std.testing.expectEqual(1, profile.calls[chip]);
    try std.testing.expectEqual(profile.inclusive[chip], profile.own[chip]);
    try std.testing.expectEqual(profile.inclusive[board] - profile.inclusive[chip], profile.own[board]);
}

test "bursts fall in power-of-two bins by instruction count" {
    if (!profile.enabled) return error.SkipZigTest;
    profile.reset();
    profile.burst(0);
    profile.burst(1);
    profile.burst(5);
    profile.burst(7);
    try std.testing.expectEqual(1, profile.bursts[0]);
    try std.testing.expectEqual(1, profile.bursts[1]);
    try std.testing.expectEqual(2, profile.bursts[3]);
}
