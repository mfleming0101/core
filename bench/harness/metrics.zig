const std = @import("std");

pub const Class = struct {
    name: []const u8,
    arch: []const u8,
    build: []const u8,
    corpus: bool = true,
};

pub const classes = [_]Class{
    .{ .name = "m0plus", .arch = "arm", .build = "m0plus", .corpus = false },
    .{ .name = "m23", .arch = "arm", .build = "m23", .corpus = false },
    .{ .name = "m3", .arch = "arm", .build = "arm" },
    .{ .name = "m4", .arch = "arm", .build = "m4" },
    .{ .name = "m7", .arch = "arm", .build = "m7" },
    .{ .name = "m33", .arch = "arm", .build = "m33" },
    .{ .name = "m55", .arch = "arm", .build = "m55" },
    .{ .name = "c3", .arch = "riscv", .build = "riscv" },
    .{ .name = "c6", .arch = "riscv", .build = "c6" },
};

pub const Ratio = struct {
    pass: u32 = 0,
    total: u32 = 0,

    pub fn full(self: Ratio) bool {
        return self.total > 0 and self.pass == self.total;
    }
};

pub const Status = enum { pass, fail };

pub const Run = struct {
    date: []const u8,
    commit: []const u8,
    target: []const u8,
    zig: []const u8,
    optimize: []const u8,
    variant: []const u8,
    cpu_mhz: f64,
    harness_sha: []const u8,
    corpus_sha: []const u8,
    oracle_sha: []const u8,
};

pub const Correctness = struct {
    date: []const u8,
    commit: []const u8,
    status: Status = .fail,
    oracle_arm: Ratio,
    oracle_rv: Ratio,
    probe_arm: Ratio,
    probe_rv: Ratio,
    corpus: Ratio,
    diag: Ratio,
    class_checks: Ratio,
    burst_equivalent: bool,
    trace_violations: u32,
};

pub const Speed = struct {
    date: []const u8,
    commit: []const u8,
    core: []const u8,
    fw_ns_per_instr: f64,
    sys_ns_per_instr: f64,
    irq_entry_cycles: f64,
};

pub const Size = struct {
    date: []const u8,
    commit: []const u8,
    core: []const u8,
    processor_bytes: u64,
    text_bytes: u64,
    rodata_bytes: u64,
    decode_bytes: i64,
};

pub const Build = struct {
    date: []const u8,
    commit: []const u8,
    build_s_core_1: f64,
    build_s_core_12: f64,
    build_s_full_1: f64,
    build_s_full_12: f64,
    rss_mb_core_1: u64,
    rss_mb_core_12: u64,
    rss_mb_full_1: u64,
    rss_mb_full_12: u64,
    isa_required: u32,
    isa_optional: u32,
    table_bytes: u64,
    heap_peak_bytes: u64,
};

pub fn gated(row: Correctness) bool {
    return row.oracle_arm.full() and row.oracle_rv.full() and
        row.probe_arm.full() and row.probe_rv.full() and
        row.corpus.full() and row.diag.full() and row.class_checks.full() and
        row.burst_equivalent and row.trace_violations == 0;
}

pub fn header(comptime T: type, buffer: []u8) ![]u8 {
    var at: usize = 0;
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        at += (try std.fmt.bufPrint(buffer[at..], "{s}{s}", .{ if (i == 0) "" else "\t", field.name })).len;
    }
    at += (try std.fmt.bufPrint(buffer[at..], "\n", .{})).len;
    return buffer[0..at];
}

pub fn line(row: anytype, buffer: []u8) ![]u8 {
    var at: usize = 0;
    inline for (@typeInfo(@TypeOf(row)).@"struct".fields, 0..) |field, i| {
        if (i != 0) at += (try std.fmt.bufPrint(buffer[at..], "\t", .{})).len;
        at += (try cell(buffer[at..], @field(row, field.name))).len;
    }
    at += (try std.fmt.bufPrint(buffer[at..], "\n", .{})).len;
    return buffer[0..at];
}

fn cell(buffer: []u8, value: anytype) ![]u8 {
    return switch (@typeInfo(@TypeOf(value))) {
        .float => std.fmt.bufPrint(buffer, "{d:.3}", .{value}),
        .@"enum" => std.fmt.bufPrint(buffer, "{s}", .{@tagName(value)}),
        .bool => std.fmt.bufPrint(buffer, "{d}", .{@intFromBool(value)}),
        .pointer => std.fmt.bufPrint(buffer, "{s}", .{value}),
        .@"struct" => std.fmt.bufPrint(buffer, "{d}/{d}", .{ value.pass, value.total }),
        else => std.fmt.bufPrint(buffer, "{d}", .{value}),
    };
}
