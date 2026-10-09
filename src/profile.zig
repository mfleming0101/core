const std = @import("std");

pub const enabled = @import("options").profile;

var nested: [16]u64 = @splat(0);
var depth: usize = 0;

pub fn Zones(comptime Zone: type) type {
    const fields = @typeInfo(Zone).@"enum".fields;
    return struct {
        pub var calls: [fields.len]u64 = @splat(0);
        pub var inclusive: [fields.len]u64 = @splat(0);
        pub var own: [fields.len]u64 = @splat(0);

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

        pub fn reset() void {
            calls = @splat(0);
            inclusive = @splat(0);
            own = @splat(0);
        }

        pub fn report(w: *std.Io.Writer, wall_ns: u64) !u64 {
            const wall: f64 = @floatFromInt(wall_ns);
            var accounted: u64 = 0;
            inline for (fields, 0..) |field, i| {
                accounted += own[i];
                try w.print("{s:<16} {d:>10} {d:>10.1} {d:>6.1} {d:>9.1} {d:>8.0}\n", .{ field.name, calls[i], ns(own[i]) / 1e6, 100 * ns(own[i]) / wall, ns(inclusive[i]) / 1e6, if (calls[i] == 0) 0 else ns(inclusive[i]) / @as(f64, @floatFromInt(calls[i])) });
            }
            return accounted;
        }
    };
}

pub fn Counts(comptime Count: type) type {
    const fields = @typeInfo(Count).@"enum".fields;
    return struct {
        pub var tallies: [fields.len]u64 = @splat(0);

        pub inline fn tally(count: Count) void {
            if (!enabled) return;
            tallies[@intFromEnum(count)] += 1;
        }

        pub fn reset() void {
            tallies = @splat(0);
        }

        pub fn report(w: *std.Io.Writer) !void {
            inline for (fields, 0..) |field, i| try w.print("{s} {d}\n", .{ field.name, tallies[i] });
        }
    };
}

pub fn header(w: *std.Io.Writer) !void {
    try w.writeAll("zone                  calls    self_ms self_%   incl_ms  ns/call\n");
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

pub fn ns(t: u64) f64 {
    return @as(f64, @floatFromInt(t)) * 1e9 / @as(f64, @floatFromInt(hz()));
}
