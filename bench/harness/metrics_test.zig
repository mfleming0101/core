const std = @import("std");
const metrics = @import("metrics.zig");

const sample: metrics.Row = .{
    .date = "2026-09-15",
    .commit = "0000000",
    .variant = "cores=12;history=ring",
    .target = "aarch64-linux",
    .optimize = "ReleaseFast",
    .zig = "0.16.0",
    .cpu_mhz = 2400,
    .status = .pass,
    .oracle_arm_match = 3,
    .oracle_arm_total = 3,
    .oracle_rv_match = 2,
    .oracle_rv_total = 2,
    .probe_arm_match = 41,
    .probe_arm_total = 41,
    .probe_rv_match = 17,
    .probe_rv_total = 17,
    .corpus_pass = 48,
    .corpus_total = 48,
    .burst_equiv_pass = true,
    .invariant_violations = 0,
    .class_checks = 288,
    .class_checks_pass = 288,
    .fw_ns_per_instr = 8.1,
    .sys_ns_per_instr = 9,
    .chip_ns_per_instr = 11,
    .debug_ns_per_instr = 20,
    .debug_chip_ns_per_instr = 24,
    .stubhost_ns = 6.6,
    .access_ns = 2,
    .ppb_ns = 3,
    .irq_entry_cycles = 12,
    .latency_cycles_per_kinstr = 700,
    .fw_ns_m3 = 8.1,
    .fw_ns_m4 = 8.2,
    .fw_ns_m33 = 8.3,
    .fw_ns_m55 = 8.4,
    .fw_ns_c3 = 12.8,
    .fw_ns_c6 = 12.9,
    .sys_ns_m3 = 9,
    .sys_ns_m4 = 9.1,
    .sys_ns_m33 = 9.2,
    .sys_ns_m55 = 9.3,
    .sys_ns_c3 = 13,
    .sys_ns_c6 = 13.1,
    .irq_entry_cycles_m3 = 12,
    .irq_entry_cycles_m4 = 12,
    .irq_entry_cycles_m33 = 1,
    .irq_entry_cycles_m55 = 1,
    .processor_bytes = 4096,
    .heap_peak_bytes = 1 << 20,
    .table_bytes = 0,
    .processor_bytes_m0plus = 1616,
    .processor_bytes_m23 = 1616,
    .processor_bytes_m3 = 1616,
    .processor_bytes_m4 = 1616,
    .processor_bytes_m33 = 1616,
    .processor_bytes_m55 = 1616,
    .processor_bytes_c3 = 800,
    .processor_bytes_c6 = 800,
    .obj_text_m0plus = 500,
    .obj_text_m23 = 600,
    .obj_text_m3 = 797,
    .obj_text_m4 = 800,
    .obj_text_m33 = 900,
    .obj_text_m55 = 1000,
    .obj_text_c3 = 400,
    .obj_text_c6 = 450,
    .obj_rodata_m0plus = 1,
    .obj_rodata_m23 = 1,
    .obj_rodata_m3 = 1,
    .obj_rodata_m4 = 1,
    .obj_rodata_m33 = 1,
    .obj_rodata_m55 = 1,
    .obj_rodata_c3 = 1,
    .obj_rodata_c6 = 1,
    .link_delta_bytes_m0plus = 100,
    .link_delta_bytes_m23 = 200,
    .link_delta_bytes_m3 = 300,
    .link_delta_bytes_m4 = 400,
    .link_delta_bytes_m33 = 500,
    .link_delta_bytes_m55 = 600,
    .link_delta_bytes_c3 = 700,
    .link_delta_bytes_c6 = 800,
    .build_s_core_1 = 40,
    .build_s_core_12 = 10,
    .build_s_full_1 = 66,
    .build_s_full_12 = 20,
    .rss_mb_core_1 = 900,
    .rss_mb_core_12 = 2000,
    .rss_mb_full_1 = 1000,
    .rss_mb_full_12 = 2048,
    .isa_decls_required = 38,
    .isa_decls_optional = 3,
    .diag_pass = 9,
    .diag_total = 9,
    .harness_sha = "0",
    .corpus_sha = "0",
    .oracle_sha = "0",
};

var head: [8192]u8 = undefined;
var body: [8192]u8 = undefined;

fn valueOf(name: []const u8) ![]const u8 {
    var columns = std.mem.splitScalar(u8, std.mem.trimEnd(u8, try metrics.header(&head), "\n"), '\t');
    var values = std.mem.splitScalar(u8, std.mem.trimEnd(u8, try metrics.line(sample, &body), "\n"), '\t');
    while (columns.next()) |column| {
        const value = values.next() orelse return error.ShortRow;
        if (std.mem.eql(u8, column, name)) return value;
    }
    return error.NoSuchColumn;
}

test "a row reads back by column name" {
    try std.testing.expectEqualStrings("pass", try valueOf("status"));
    try std.testing.expectEqualStrings("8.100", try valueOf("fw_ns_per_instr"));
    try std.testing.expectEqualStrings("8.300", try valueOf("fw_ns_m33"));
    try std.testing.expectEqualStrings("1", try valueOf("burst_equiv_pass"));
    try std.testing.expectEqualStrings("38", try valueOf("isa_decls_required"));
}

test "a failing correctness gate makes the row inadmissible" {
    try std.testing.expect(metrics.gated(sample));

    var diverged = sample;
    diverged.probe_rv_match = 16;
    try std.testing.expect(!metrics.gated(diverged));

    var violated = sample;
    violated.invariant_violations = 1;
    try std.testing.expect(!metrics.gated(violated));

    var unchecked = sample;
    unchecked.oracle_arm_match = 0;
    unchecked.oracle_arm_total = 0;
    try std.testing.expect(!metrics.gated(unchecked));

    var undiagnosed = sample;
    undiagnosed.diag_pass = 8;
    try std.testing.expect(!metrics.gated(undiagnosed));

    var undiagnosable = sample;
    undiagnosable.diag_pass = 0;
    undiagnosable.diag_total = 0;
    try std.testing.expect(!metrics.gated(undiagnosable));

    var classless = sample;
    classless.class_checks = 0;
    classless.class_checks_pass = 0;
    try std.testing.expect(!metrics.gated(classless));

    var diverged_class = sample;
    diverged_class.class_checks_pass = 287;
    try std.testing.expect(!metrics.gated(diverged_class));
}
