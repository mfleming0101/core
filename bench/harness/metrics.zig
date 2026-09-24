const std = @import("std");

pub const Class = struct {
    name: []const u8,
    arch: []const u8,
    build: []const u8,
    timed: bool,
    entry: bool = false,
};

pub const classes = [_]Class{
    .{ .name = "m0plus", .arch = "arm", .build = "m0plus", .timed = false },
    .{ .name = "m23", .arch = "arm", .build = "m23", .timed = false },
    .{ .name = "m3", .arch = "arm", .build = "arm", .timed = true, .entry = true },
    .{ .name = "m4", .arch = "arm", .build = "m4", .timed = true, .entry = true },
    .{ .name = "m33", .arch = "arm", .build = "m33", .timed = true, .entry = true },
    .{ .name = "m55", .arch = "arm", .build = "m55", .timed = true, .entry = true },
    .{ .name = "c3", .arch = "riscv", .build = "riscv", .timed = true },
    .{ .name = "c6", .arch = "riscv", .build = "c6", .timed = true },
};

pub const Row = struct {
    date: []const u8,
    commit: []const u8,
    alt: []const u8,
    variant: []const u8,
    target: []const u8,
    optimize: []const u8,
    zig: []const u8,
    cpu_mhz: f64,
    status: Status,

    oracle_arm_match: u32,
    oracle_arm_total: u32,
    oracle_rv_match: u32,
    oracle_rv_total: u32,
    probe_arm_match: u32,
    probe_arm_total: u32,
    probe_rv_match: u32,
    probe_rv_total: u32,
    corpus_pass: u32,
    corpus_total: u32,
    burst_equiv_pass: bool,
    invariant_violations: u32,
    class_checks: u32,
    class_checks_pass: u32,

    fw_ns_per_instr: f64,
    sys_ns_per_instr: f64,
    chip_ns_per_instr: f64,
    debug_ns_per_instr: f64,
    debug_chip_ns_per_instr: f64,

    stubhost_ns: f64,
    access_ns: f64,
    ppb_ns: f64,
    irq_entry_cycles: f64,
    latency_cycles_per_kinstr: f64,

    fw_ns_m3: f64 = 0,
    fw_ns_m4: f64 = 0,
    fw_ns_m33: f64 = 0,
    fw_ns_m55: f64 = 0,
    fw_ns_c3: f64 = 0,
    fw_ns_c6: f64 = 0,

    sys_ns_m3: f64 = 0,
    sys_ns_m4: f64 = 0,
    sys_ns_m33: f64 = 0,
    sys_ns_m55: f64 = 0,
    sys_ns_c3: f64 = 0,
    sys_ns_c6: f64 = 0,

    irq_entry_cycles_m3: f64 = 0,
    irq_entry_cycles_m4: f64 = 0,
    irq_entry_cycles_m33: f64 = 0,
    irq_entry_cycles_m55: f64 = 0,

    processor_bytes: u64,
    heap_peak_bytes: u64,
    table_bytes: u64,

    processor_bytes_m0plus: u64 = 0,
    processor_bytes_m23: u64 = 0,
    processor_bytes_m3: u64 = 0,
    processor_bytes_m4: u64 = 0,
    processor_bytes_m33: u64 = 0,
    processor_bytes_m55: u64 = 0,
    processor_bytes_c3: u64 = 0,
    processor_bytes_c6: u64 = 0,

    obj_text_m0plus: u64 = 0,
    obj_text_m23: u64 = 0,
    obj_text_m3: u64 = 0,
    obj_text_m4: u64 = 0,
    obj_text_m33: u64 = 0,
    obj_text_m55: u64 = 0,
    obj_text_c3: u64 = 0,
    obj_text_c6: u64 = 0,

    obj_rodata_m0plus: u64 = 0,
    obj_rodata_m23: u64 = 0,
    obj_rodata_m3: u64 = 0,
    obj_rodata_m4: u64 = 0,
    obj_rodata_m33: u64 = 0,
    obj_rodata_m55: u64 = 0,
    obj_rodata_c3: u64 = 0,
    obj_rodata_c6: u64 = 0,

    link_delta_bytes_m0plus: i64 = 0,
    link_delta_bytes_m23: i64 = 0,
    link_delta_bytes_m3: i64 = 0,
    link_delta_bytes_m4: i64 = 0,
    link_delta_bytes_m33: i64 = 0,
    link_delta_bytes_m55: i64 = 0,
    link_delta_bytes_c3: i64 = 0,
    link_delta_bytes_c6: i64 = 0,

    build_s_core_1: f64,
    build_s_core_12: f64,
    build_s_full_1: f64,
    build_s_full_12: f64,
    rss_mb_core_1: u64,
    rss_mb_core_12: u64,
    rss_mb_full_1: u64,
    rss_mb_full_12: u64,

    isa_decls_required: u32,
    isa_decls_optional: u32,

    diag_pass: u32,
    diag_total: u32,

    harness_sha: []const u8,
    corpus_sha: []const u8,
    oracle_sha: []const u8,
};

pub const Status = enum { pass, fail };

pub fn gated(row: Row) bool {
    return row.oracle_arm_total > 0 and row.oracle_arm_match == row.oracle_arm_total and
        row.oracle_rv_total > 0 and row.oracle_rv_match == row.oracle_rv_total and
        row.probe_arm_total > 0 and row.probe_arm_match == row.probe_arm_total and
        row.probe_rv_total > 0 and row.probe_rv_match == row.probe_rv_total and
        row.corpus_total > 0 and row.corpus_pass == row.corpus_total and
        row.diag_total > 0 and row.diag_pass == row.diag_total and
        row.burst_equiv_pass and
        row.invariant_violations == 0 and
        row.class_checks > 0 and row.class_checks_pass == row.class_checks;
}

pub fn header(buffer: []u8) ![]u8 {
    var at: usize = 0;
    inline for (@typeInfo(Row).@"struct".fields, 0..) |field, i| {
        at += (try std.fmt.bufPrint(buffer[at..], "{s}{s}", .{ if (i == 0) "" else "\t", field.name })).len;
    }
    at += (try std.fmt.bufPrint(buffer[at..], "\n", .{})).len;
    return buffer[0..at];
}

pub fn line(row: Row, buffer: []u8) ![]u8 {
    var at: usize = 0;
    inline for (@typeInfo(Row).@"struct".fields, 0..) |field, i| {
        if (i != 0) at += (try std.fmt.bufPrint(buffer[at..], "\t", .{})).len;
        const value = @field(row, field.name);
        at += switch (@typeInfo(field.type)) {
            .float => (try std.fmt.bufPrint(buffer[at..], "{d:.3}", .{value})).len,
            .@"enum" => (try std.fmt.bufPrint(buffer[at..], "{s}", .{@tagName(value)})).len,
            .bool => (try std.fmt.bufPrint(buffer[at..], "{d}", .{@intFromBool(value)})).len,
            .pointer => (try std.fmt.bufPrint(buffer[at..], "{s}", .{value})).len,
            else => (try std.fmt.bufPrint(buffer[at..], "{d}", .{value})).len,
        };
    }
    at += (try std.fmt.bufPrint(buffer[at..], "\n", .{})).len;
    return buffer[0..at];
}
