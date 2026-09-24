const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nulled = std.mem.eql(u8, b.option([]const u8, "isa", "The instruction set this build links: real (default) or null") orelse "real", "null");
    const nullisa = b.createModule(.{ .root_source_file = b.path("bench/nullisa/root.zig"), .target = target, .optimize = optimize });
    const isa = if (nulled) nullisa else b.dependency("isa", .{ .target = target, .optimize = optimize }).module("isa");
    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "isa", .module = isa }},
    });

    const harness = b.createModule(.{
        .root_source_file = b.path("bench/harness/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "core", .module = core }, .{ .name = "isa", .module = isa } },
    });

    const bare = if (nulled) core else b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "isa", .module = nullisa }},
    });
    const bare_harness = if (nulled) harness else b.createModule(.{
        .root_source_file = b.path("bench/harness/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "core", .module = bare }, .{ .name = "isa", .module = nullisa } },
    });

    const oracles = chosen(b, .{ .name = "oracles", .arch = "arm", .core = "m3" });
    for (reps) |rep| {
        const chose = if (rep.oracle) oracles else chosen(b, rep);
        const root = b.fmt("bench/{s}/machine.zig", .{rep.arch});
        const m = machine(b, target, optimize, b.fmt("machine-{s}", .{rep.name}), root, core, harness, chose);
        b.installArtifact(m);
        const probe = b.addObject(.{
            .name = b.fmt("sizeprobe-{s}", .{rep.name}),
            .root_module = machineModule(b, target, optimize, b.fmt("bench/{s}/sizeprobe.zig", .{rep.arch}), bare, bare_harness, chose),
        });
        b.getInstallStep().dependOn(&b.addInstallFile(probe.getEmittedBin(), b.fmt("sizeprobe-{s}.o", .{rep.name})).step);
        b.installArtifact(machine(b, target, optimize, b.fmt("machine-null-{s}", .{rep.name}), root, bare, bare_harness, chose));
        if (!rep.oracle) continue;
        b.step(b.fmt("build-{s}", .{m.name}), b.fmt("Build {s} alone", .{m.name})).dependOn(&b.addInstallArtifact(m, .{}).step);
        b.installArtifact(machine(b, target, optimize, b.fmt("machine-stubhost-{s}", .{rep.name}), b.fmt("bench/{s}/stubhost.zig", .{rep.arch}), core, harness, chose));
    }

    if (b.pkg_hash.len == 0) {
        writeTestRoot(b);
        const test_step = b.step("test", "Run every test");
        test_step.dependOn(&b.addRunArtifact(tests(b, isa, target, optimize)).step);
        const examples_step = b.step("examples", "Run the examples under examples/");
        for ([_]Example{
            .{ .name = "run_arm", .query = cortex_m0plus, .script = "examples/arm.ld", .firmware = "crc" },
            .{ .name = "run_riscv", .query = rv32, .script = "examples/riscv.ld", .firmware = "crc" },
            .{ .name = "console", .query = cortex_m0plus, .script = "examples/arm.ld", .firmware = "hello" },
            .{ .name = "timer_arm", .query = cortex_m0plus, .script = "examples/arm.ld", .firmware = "timer" },
            .{ .name = "timer_riscv", .query = rv32, .script = "examples/riscv.ld", .firmware = "timer" },
            .{ .name = "profile", .query = cortex_m0plus, .script = "examples/arm.ld", .firmware = "crc" },
            .{ .name = "crash", .query = cortex_m0plus, .script = "examples/arm.ld", .firmware = "fault" },
            .{ .name = "zon_map", .query = cortex_m0plus, .script = "examples/arm.ld", .firmware = "timer" },
        }) |e| {
            const example = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{e.name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "core", .module = core },
                    .{ .name = b.fmt("{s}.elf", .{e.firmware}), .module = b.createModule(.{ .root_source_file = firmware(b, e) }) },
                },
            }) });
            examples_step.dependOn(&b.addRunArtifact(example).step);
        }
        for ([_][]const u8{ "first_program_arm", "first_program_riscv", "step_by_step", "budgets", "memory_map", "output_port", "which_core" }) |name| {
            const example = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "core", .module = core }},
            }) });
            examples_step.dependOn(&b.addRunArtifact(example).step);
        }
        test_step.dependOn(examples_step);
    }

    const machines = b.createModule(.{
        .root_source_file = machineRoot(b),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .imports = &.{ .{ .name = "core", .module = core }, .{ .name = "harness", .module = harness }, .{ .name = "rep", .module = oracles } },
    });
    harness.addImport("machine", machines);

    const harness_step = b.step("harness", "Run the measurement harness tests");
    harness_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = harness })).step);

    const bench = b.addRunArtifact(b.addExecutable(.{ .name = "bench", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/run.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "harness", .module = harness }},
    }) }));
    bench.setCwd(b.path("."));
    bench.has_side_effects = true;
    if (b.args) |args| bench.addArgs(args);
    b.step("metrics", "Append one schema-valid row to bench/summary.tsv, or release-metrics.tsv with --release").dependOn(&bench.step);
}

const Rep = struct { name: []const u8, arch: []const u8, core: []const u8, oracle: bool = false };

const reps = [_]Rep{
    .{ .name = "m0plus", .arch = "arm", .core = "m0plus" },
    .{ .name = "m23", .arch = "arm", .core = "m23" },
    .{ .name = "arm", .arch = "arm", .core = "m3", .oracle = true },
    .{ .name = "m4", .arch = "arm", .core = "m4" },
    .{ .name = "m33", .arch = "arm", .core = "m33" },
    .{ .name = "m55", .arch = "arm", .core = "m55" },
    .{ .name = "riscv", .arch = "riscv", .core = "esp32c3", .oracle = true },
    .{ .name = "c6", .arch = "riscv", .core = "esp32c6" },
};

fn chosen(b: *std.Build, rep: Rep) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([]const u8, "arm", if (std.mem.eql(u8, rep.arch, "arm")) rep.core else "m3");
    options.addOption([]const u8, "riscv", if (std.mem.eql(u8, rep.arch, "riscv")) rep.core else "esp32c3");
    return options.createModule();
}

fn machineRoot(b: *std.Build) std.Build.LazyPath {
    const files = b.addWriteFiles();
    for ([_][]const u8{ "arm", "riscv" }) |which| {
        _ = files.addCopyFile(b.path(b.fmt("bench/{s}/machine.zig", .{which})), b.fmt("{s}.zig", .{which}));
    }
    return files.add("root.zig", "pub const arm = @import(\"arm.zig\");\npub const riscv = @import(\"riscv.zig\");\n");
}

fn machineModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, root: []const u8, core: *std.Build.Module, harness: *std.Build.Module, rep: *std.Build.Module) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .imports = &.{ .{ .name = "core", .module = core }, .{ .name = "harness", .module = harness }, .{ .name = "rep", .module = rep } },
    });
}

fn machine(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, root: []const u8, core: *std.Build.Module, harness: *std.Build.Module, rep: *std.Build.Module) *std.Build.Step.Compile {
    return b.addExecutable(.{ .name = name, .root_module = machineModule(b, target, optimize, root, core, harness, rep) });
}

fn tests(b: *std.Build, isa: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    return b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "isa", .module = isa },
            },
        }),
    });
}

fn writeTestRoot(b: *std.Build) void {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, "test", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("out of memory");
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (walker.next(io) catch @panic("cannot walk test")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, "_test.zig")) continue;
        const path = b.dupe(entry.path);
        std.mem.replaceScalar(u8, path, std.fs.path.sep, '/');
        paths.append(b.allocator, path) catch @panic("out of memory");
    }
    std.mem.sort([]const u8, paths.items, {}, lessThan);
    var text: std.Io.Writer.Allocating = .init(b.allocator);
    text.writer.writeAll("comptime {\n") catch @panic("out of memory");
    for (paths.items) |path| text.writer.print("    _ = @import(\"test/{s}\");\n", .{path}) catch @panic("out of memory");
    text.writer.writeAll("}\n") catch @panic("out of memory");
    const current = b.build_root.handle.readFileAlloc(io, "tests.zig", b.allocator, .limited(1 << 20)) catch "";
    if (std.mem.eql(u8, current, text.written())) return;
    b.build_root.handle.writeFile(io, .{ .sub_path = "tests.zig", .data = text.written() }) catch @panic("cannot write tests.zig");
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const cortex_m0plus: std.Target.Query = .{ .cpu_arch = .thumb, .os_tag = .freestanding, .abi = .eabi, .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m0plus } };
const rv32: std.Target.Query = .{ .cpu_arch = .riscv32, .os_tag = .freestanding, .abi = .none, .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 } };

const Example = struct { name: []const u8, query: std.Target.Query, script: []const u8, firmware: []const u8 };

fn firmware(b: *std.Build, e: Example) std.Build.LazyPath {
    const exe = b.addExecutable(.{
        .name = e.name,
        .root_module = b.createModule(.{ .target = b.resolveTargetQuery(e.query), .optimize = .ReleaseSmall }),
    });
    exe.root_module.addCSourceFile(.{ .file = b.path(b.fmt("examples/{s}.c", .{e.firmware})), .flags = &.{"-ffreestanding"} });
    exe.setLinkerScript(b.path(e.script));
    return exe.getEmittedBin();
}
