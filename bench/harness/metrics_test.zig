const std = @import("std");
const metrics = @import("metrics.zig");

const sample: metrics.Correctness = .{
    .date = "2026-09-15",
    .commit = "0000000",
    .status = .pass,
    .oracle_arm = .{ .pass = 3, .total = 3 },
    .oracle_rv = .{ .pass = 2, .total = 2 },
    .probe_arm = .{ .pass = 41, .total = 41 },
    .probe_rv = .{ .pass = 17, .total = 17 },
    .corpus = .{ .pass = 48, .total = 48 },
    .diag = .{ .pass = 9, .total = 9 },
    .class_checks = .{ .pass = 288, .total = 288 },
    .burst_equivalent = true,
    .trace_violations = 0,
};

var head: [8192]u8 = undefined;
var body: [8192]u8 = undefined;

fn valueOf(row: anytype, name: []const u8) ![]const u8 {
    var columns = std.mem.splitScalar(u8, std.mem.trimEnd(u8, try metrics.header(@TypeOf(row), &head), "\n"), '\t');
    var values = std.mem.splitScalar(u8, std.mem.trimEnd(u8, try metrics.line(row, &body), "\n"), '\t');
    while (columns.next()) |column| {
        const value = values.next() orelse return error.ShortRow;
        if (std.mem.eql(u8, column, name)) return value;
    }
    return error.NoSuchColumn;
}

test "a row reads back by column name" {
    try std.testing.expectEqualStrings("pass", try valueOf(sample, "status"));
    try std.testing.expectEqualStrings("41/41", try valueOf(sample, "probe_arm"));
    try std.testing.expectEqualStrings("1", try valueOf(sample, "burst_equivalent"));
    const speed: metrics.Speed = .{ .date = "d", .commit = "c", .core = "m7", .fw_ns_per_instr = 8.1, .sys_ns_per_instr = 9, .irq_entry_cycles = 12 };
    try std.testing.expectEqualStrings("m7", try valueOf(speed, "core"));
    try std.testing.expectEqualStrings("8.100", try valueOf(speed, "fw_ns_per_instr"));
}

test "a failing correctness gate makes the row inadmissible" {
    try std.testing.expect(metrics.gated(sample));

    var diverged = sample;
    diverged.probe_rv.pass = 16;
    try std.testing.expect(!metrics.gated(diverged));

    var violated = sample;
    violated.trace_violations = 1;
    try std.testing.expect(!metrics.gated(violated));

    var unchecked = sample;
    unchecked.oracle_arm = .{};
    try std.testing.expect(!metrics.gated(unchecked));

    var undiagnosed = sample;
    undiagnosed.diag.pass = 8;
    try std.testing.expect(!metrics.gated(undiagnosed));

    var classless = sample;
    classless.class_checks = .{};
    try std.testing.expect(!metrics.gated(classless));

    var unequal = sample;
    unequal.burst_equivalent = false;
    try std.testing.expect(!metrics.gated(unequal));
}
