const std = @import("std");

pub const enabled = @import("options").profile;

pub const Zone = enum { board_run, chip_next, chip_run_to, imu_next, imu_run_to, host_next, host_run_to, crsf_next, crsf_run_to, chip_run, core_burst, bus_settle, wire_drain };

pub const Count = enum { chip_now, imu_now, host_now, crsf_now, runner_switch };

const zones = @typeInfo(Zone).@"enum".fields.len;
const counts = @typeInfo(Count).@"enum".fields.len;

pub var calls: [zones]u64 = @splat(0);
pub var inclusive: [zones]u64 = @splat(0);
pub var own: [zones]u64 = @splat(0);
pub var tallies: [counts]u64 = @splat(0);
pub var bursts: [65]u64 = @splat(0);
var nested: [16]u64 = @splat(0);
var depth: usize = 0;

pub const Span = if (enabled) struct { zone: Zone, start: u64 } else void;

pub inline fn begin(zone: Zone) Span {
    if (!enabled) return {};
    depth += 1;
    nested[depth] = 0;
    return .{ .zone = zone, .start = ticks() };
}

pub inline fn end(span: Span) void {
    if (!enabled) return;
    const took = ticks() - span.start;
    const i = @intFromEnum(span.zone);
    calls[i] += 1;
    inclusive[i] += took;
    own[i] += took - nested[depth];
    depth -= 1;
    nested[depth] += took;
}

pub inline fn tally(count: Count) void {
    if (!enabled) return;
    tallies[@intFromEnum(count)] += 1;
}

pub inline fn burst(instructions: u64) void {
    if (!enabled) return;
    bursts[if (instructions == 0) 0 else std.math.log2_int(u64, instructions) + 1] += 1;
}

pub fn reset() void {
    calls = @splat(0);
    inclusive = @splat(0);
    own = @splat(0);
    tallies = @splat(0);
    bursts = @splat(0);
}

inline fn ticks() u64 {
    return asm volatile ("mrs %[t], cntvct_el0"
        : [t] "=r" (-> u64),
    );
}

fn hz() u64 {
    return asm volatile ("mrs %[f], cntfrq_el0"
        : [f] "=r" (-> u64),
    );
}

fn ns(t: u64) f64 {
    return @as(f64, @floatFromInt(t)) * 1e9 / @as(f64, @floatFromInt(hz()));
}

pub fn report(w: *std.Io.Writer, wall_ns: u64) !void {
    const wall: f64 = @floatFromInt(wall_ns);
    var accounted: u64 = 0;
    try w.writeAll("zone             calls        self_ms  self_%  incl_ms  ns/call\n");
    inline for (@typeInfo(Zone).@"enum".fields, 0..) |field, i| {
        accounted += own[i];
        try w.print("{s:<14} {d:>9} {d:>12.1} {d:>7.1} {d:>8.1} {d:>8.0}\n", .{ field.name, calls[i], ns(own[i]) / 1e6, 100 * ns(own[i]) / wall, ns(inclusive[i]) / 1e6, if (calls[i] == 0) 0 else ns(inclusive[i]) / @as(f64, @floatFromInt(calls[i])) });
    }
    try w.print("accounted {d:.1} % of {d:.3} s\n", .{ 100 * ns(accounted) / wall, wall / 1e9 });
    inline for (@typeInfo(Count).@"enum".fields, 0..) |field, i| try w.print("{s} {d}\n", .{ field.name, tallies[i] });
    try w.writeAll("instructions per burst:");
    for (bursts, 0..) |n, i| if (n != 0) try w.print(" [{d}]={d}", .{ if (i == 0) 0 else @as(u64, 1) << @intCast(i - 1), n });
    try w.writeAll("\n");
}
