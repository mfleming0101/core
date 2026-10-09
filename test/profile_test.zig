const std = @import("std");
const profile = @import("../src/profile.zig");

const Zone = enum { outer, inner };
const zones = profile.Zones(Zone);

test "a zone's own time is its span less the zones begun inside it" {
    if (!profile.enabled) return error.SkipZigTest;
    zones.reset();
    const outer = zones.begin(.outer);
    const inner = zones.begin(.inner);
    zones.end(inner);
    zones.end(outer);
    try std.testing.expectEqual(1, zones.calls[0]);
    try std.testing.expectEqual(1, zones.calls[1]);
    try std.testing.expectEqual(zones.inclusive[1], zones.own[1]);
    try std.testing.expectEqual(zones.inclusive[0] - zones.inclusive[1], zones.own[0]);
}

test "a count tallies per enum value" {
    if (!profile.enabled) return error.SkipZigTest;
    const counts = profile.Counts(enum { a, b });
    counts.reset();
    counts.tally(.b);
    counts.tally(.b);
    try std.testing.expectEqual(0, counts.tallies[0]);
    try std.testing.expectEqual(2, counts.tallies[1]);
}
