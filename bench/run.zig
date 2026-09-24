const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const harness = @import("harness");

const metrics = harness.metrics;

const Options = struct {
    cpu: ?u16 = 0,
    release: bool = false,
};

const Image = struct {
    name: []const u8,
    arch: []const u8,
    path: []const u8,
    retired: u64,
    stop: []const u8,
    checksum: ?u32 = null,
    source: []const u8,
    map: ?[]const u8 = null,
    semihosting: bool = false,
    halts: bool = false,
};

const Case = struct {
    case: []const u8,
    arch: []const u8,
    expect: []const []const u8,
    map: ?[]const u8 = null,
};

const Digests = struct {
    harness_sha: []const u8,
    corpus_sha: []const u8,
    oracle_sha: []const u8,
};

const Ran = struct {
    retired: u64 = 0,
    cycles: u64 = 0,
    latency: u64 = 0,
    stop: []const u8 = "",
    checksum: u32 = 0,
    ns: u64 = 0,
    heap: u64 = 0,
};

const Best = struct { ran: Ran = .{}, ns: u64 = 0, steady: bool = true };

const Geo = struct {
    sum: f64 = 0,
    count: usize = 0,

    fn add(self: *Geo, value: f64) void {
        if (value <= 0) return;
        self.sum += @log(value);
        self.count += 1;
    }

    fn mean(self: Geo) f64 {
        return if (self.count == 0) 0 else @exp(self.sum / @as(f64, @floatFromInt(self.count)));
    }
};

fn across(arm: f64, riscv: f64) f64 {
    return if (arm == 0 or riscv == 0) 0 else @sqrt(arm * riscv);
}

const Counted = struct { pass: u32 = 0, total: u32 = 0 };

const Timing = struct {
    arm: f64 = 0,
    riscv: f64 = 0,
    overall: f64 = 0,
    corpus: Counted = .{},
};

const Measured = struct { timing: Timing = .{}, chip: Chip = .{}, heap: u64 = 0 };

const About = struct {
    isa_required: u32 = 0,
    isa_optional: u32 = 0,
    processor_bytes: u32 = 0,
    table_bytes: u32 = 0,
};

const Access = struct { accesses: u32 = 0, ns: u32 = 0 };

const Entered = struct { entries: u32 = 0, entry_cycles: u32 = 0 };

const Paths = struct { access: f64 = 0, ppb: f64 = 0 };

const Debug = struct { ns: f64 = 0, chip: f64 = 0, violations: u32 = 0 };

const Diagnosis = struct { pass: u32 = 0, total: u32 = 0 };

const Judged = struct { agree: u32 = 0, fixed: u32 = 0, known: u32 = 0, total: u32 = 0 };

const Probing = struct { arch: []const u8, map: []const u8, elf: []const u8 };

const arches = [_][]const u8{ "arm", "riscv" };

const probings = [_]Probing{
    .{ .arch = "arm", .map = "oracle/probe/probe.zon", .elf = "oracle/probe/out/probe_arm.elf" },
    .{ .arch = "riscv", .map = "oracle/probe/probe_riscv.zon", .elf = "oracle/probe/out/probe_riscv.elf" },
};

const Classed = struct {
    fw: f64 = 0,
    sys: f64 = 0,
    irq: f64 = 0,
    processor_bytes: u64 = 0,
    text: u64 = 0,
    rodata: u64 = 0,
    link_delta: i64 = 0,
};

const Bound = struct { arch: []const u8, name: []const u8 };

const bound = [_]Bound{
    .{ .arch = "arm", .name = "ctxswitch" },
    .{ .arch = "arm", .name = "irq_storm" },
    .{ .arch = "arm", .name = "devpoll" },
    .{ .arch = "arm", .name = "sleep" },
    .{ .arch = "riscv", .name = "ctxswitch" },
    .{ .arch = "riscv", .name = "irq_storm" },
    .{ .arch = "riscv", .name = "sleep" },
    .{ .arch = "riscv", .name = "tickless" },
    .{ .arch = "riscv", .name = "devpoll" },
    .{ .arch = "riscv", .name = "intc_matrix" },
};

fn everywhere(image: Image) bool {
    for (bound) |one| {
        if (std.mem.eql(u8, one.arch, image.arch) and std.mem.eql(u8, one.name, image.name)) return false;
    }
    return true;
}

const Cold = struct { seconds: f64 = 0, rss_mb: u64 = 0 };

const Compile = struct {
    core_1: Cold = .{},
    core_12: Cold = .{},
    full_1: Cold = .{},
    full_12: Cold = .{},
};

const Chip = struct {
    sys_arm: f64 = 0,
    sys_riscv: f64 = 0,
    chip: f64 = 0,
    equivalent: bool = true,
    latency: u64 = 0,
    retired: u64 = 0,
};

const seed: u64 = 0xcbf2_9ce4_8422_2325;
const prime: u64 = 0x100_0000_01b3;
const window: u64 = 1 << 16;
const cold_jobs: u16 = 12;
const burst_span = "37";
const class_budget = "2000000";
const history_records = "65536";
const event_records = "4096";
const alt = "folded-tree";
const optimize = "ReleaseFast";
const runs: usize = 5;
const summary_path = "bench/summary.tsv";
const release_path = "bench/release-metrics.tsv";
const detail_path = "bench/detail.tsv";
const detail_header = "alt\ttier\timage\tarch\tns_per_instr\tretired\tstop\tchecksum\tok\n";

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    _ = args.skip();

    var options: Options = .{};
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--cpu")) {
            options.cpu = try std.fmt.parseInt(u16, args.next() orelse return usage(), 10);
        } else if (std.mem.eql(u8, flag, "--release")) {
            options.release = true;
        } else return usage();
    }

    var buffer: [1 << 16]u8 = undefined;
    var file = std.Io.File.stdout().writer(init.io, &buffer);
    var runner: Runner = .{ .io = init.io, .gpa = gpa, .options = options, .out = &file.interface };
    defer runner.out.flush() catch {};
    try runner.all();
}

fn usage() void {
    std.debug.print("bench/run.zig [--cpu <id>] [--release]\n", .{});
    std.process.exit(2);
}

const Runner = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    options: Options,
    out: *std.Io.Writer,
    images: []const Image = &.{},
    detail: std.ArrayList(u8) = .empty,
    mhz: f64 = 0,

    fn all(self: *Runner) !void {
        self.images = try self.manifest();
        const digests = try self.integrity();
        try self.rebuild();

        const before = try self.binaries();
        const about = try self.interface();
        self.clock();
        const measured = try self.corpus();
        const stub = try self.stubhost();
        const path = try self.pathCosts();
        const irq = try self.entered();
        const debug = try self.debugged();
        var checks: Counted = .{};
        const classed = try self.perClass(&checks);
        self.clock();
        const diagnosis = try self.diagnose();
        const oracle = try self.lockstep();
        const probe = try self.probed();
        const compiled = try self.compiles();
        if (!std.mem.eql(u8, before, try self.binaries())) {
            return self.refuse("the measured binaries changed during the run", .{});
        }

        try appendLog(self.io, self.gpa, detail_path, detail_header, self.detail.items);

        var row: metrics.Row = .{
            .date = try today(self.io, self.gpa),
            .commit = try self.commit(),
            .alt = alt,
            .variant = if (self.options.cpu) |cpu|
                try std.fmt.allocPrint(self.gpa, "history=ring;taskset={d}", .{cpu})
            else
                "history=ring;taskset=none",
            .target = @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag),
            .optimize = optimize,
            .zig = builtin.zig_version_string,
            .cpu_mhz = self.mhz,
            .status = .fail,

            .oracle_arm_match = oracle[0].pass,
            .oracle_arm_total = oracle[0].total,
            .oracle_rv_match = oracle[1].pass,
            .oracle_rv_total = oracle[1].total,
            .probe_arm_match = probe[0].pass,
            .probe_arm_total = probe[0].total,
            .probe_rv_match = probe[1].pass,
            .probe_rv_total = probe[1].total,
            .corpus_pass = measured.timing.corpus.pass,
            .corpus_total = measured.timing.corpus.total,
            .burst_equiv_pass = measured.chip.equivalent,
            .invariant_violations = debug.violations,
            .class_checks = checks.total,
            .class_checks_pass = checks.pass,

            .fw_ns_per_instr = measured.timing.overall,
            .sys_ns_per_instr = across(measured.chip.sys_arm, measured.chip.sys_riscv),
            .chip_ns_per_instr = measured.chip.chip,
            .debug_ns_per_instr = debug.ns,
            .debug_chip_ns_per_instr = debug.chip,

            .stubhost_ns = stub,
            .access_ns = path.access,
            .ppb_ns = path.ppb,
            .irq_entry_cycles = irq,
            .latency_cycles_per_kinstr = if (measured.chip.retired == 0) 0 else 1000 * @as(f64, @floatFromInt(measured.chip.latency)) / @as(f64, @floatFromInt(measured.chip.retired)),

            .processor_bytes = about.processor_bytes,
            .heap_peak_bytes = measured.heap,
            .table_bytes = about.table_bytes,

            .build_s_core_1 = compiled.core_1.seconds,
            .build_s_core_12 = compiled.core_12.seconds,
            .build_s_full_1 = compiled.full_1.seconds,
            .build_s_full_12 = compiled.full_12.seconds,
            .rss_mb_core_1 = compiled.core_1.rss_mb,
            .rss_mb_core_12 = compiled.core_12.rss_mb,
            .rss_mb_full_1 = compiled.full_1.rss_mb,
            .rss_mb_full_12 = compiled.full_12.rss_mb,

            .isa_decls_required = about.isa_required,
            .isa_decls_optional = about.isa_optional,

            .diag_pass = diagnosis.pass,
            .diag_total = diagnosis.total,

            .harness_sha = digests.harness_sha,
            .corpus_sha = digests.corpus_sha,
            .oracle_sha = digests.oracle_sha,
        };
        inline for (metrics.classes, 0..) |class, i| {
            @field(row, "processor_bytes_" ++ class.name) = classed[i].processor_bytes;
            @field(row, "obj_text_" ++ class.name) = classed[i].text;
            @field(row, "obj_rodata_" ++ class.name) = classed[i].rodata;
            @field(row, "link_delta_bytes_" ++ class.name) = classed[i].link_delta;
            if (class.timed) {
                @field(row, "fw_ns_" ++ class.name) = classed[i].fw;
                @field(row, "sys_ns_" ++ class.name) = classed[i].sys;
            }
            if (class.entry) @field(row, "irq_entry_cycles_" ++ class.name) = classed[i].irq;
        }
        if (metrics.gated(row)) row.status = .pass;

        try self.append(row);
        try self.out.writeAll(try metrics.header(try self.gpa.alloc(u8, 4096)));
        try self.out.writeAll(try metrics.line(row, try self.gpa.alloc(u8, 4096)));
    }

    fn say(self: *Runner, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(fmt, args);
        try self.out.flush();
    }

    fn refuse(self: *Runner, comptime fmt: []const u8, args: anytype) error{Refused} {
        self.out.print("error=" ++ fmt ++ "; no row written\n", args) catch {};
        self.out.flush() catch {};
        std.process.exit(1);
    }

    fn read(self: *Runner, path: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(256 << 20));
    }

    fn present(self: *Runner, path: []const u8) bool {
        var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return false;
        file.close(self.io);
        return true;
    }

    fn zon(self: *Runner, comptime T: type, path: []const u8) !T {
        const source = try std.Io.Dir.cwd().readFileAllocOptions(self.io, path, self.gpa, .limited(1 << 20), .of(u8), 0);
        var diagnostics: std.zon.parse.Diagnostics = .{};
        return std.zon.parse.fromSliceAlloc(T, self.gpa, source, &diagnostics, .{ .ignore_unknown_fields = true }) catch
            self.refuse("{s}: {f}", .{ path, diagnostics });
    }

    fn manifest(self: *Runner) ![]const Image {
        return self.zon([]const Image, "corpus/manifest.zon");
    }

    fn machine(self: *Runner, arch: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.gpa, "zig-out/bin/machine-{s}", .{arch});
    }

    fn classMachine(self: *Runner, class: metrics.Class) ![]const u8 {
        return std.fmt.allocPrint(self.gpa, "zig-out/bin/machine-{s}", .{class.build});
    }

    fn classProbe(self: *Runner, class: metrics.Class) ![]const u8 {
        return std.fmt.allocPrint(self.gpa, "zig-out/sizeprobe-{s}.o", .{class.build});
    }

    fn classNull(self: *Runner, class: metrics.Class) ![]const u8 {
        return std.fmt.allocPrint(self.gpa, "zig-out/bin/machine-null-{s}", .{class.build});
    }

    fn stubhostOf(self: *Runner, arch: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.gpa, "zig-out/bin/machine-stubhost-{s}", .{arch});
    }

    fn mapOf(self: *Runner, given: ?[]const u8, arch: []const u8) ![]const u8 {
        const named = given orelse return std.fmt.allocPrint(self.gpa, "corpus/maps/{s}-flat.zon", .{arch});
        return std.fmt.allocPrint(self.gpa, "corpus/{s}", .{named});
    }

    fn integrity(self: *Runner) !Digests {
        const harness_files = try self.sources(&.{ "bench/harness", "bench/nullisa", "bench/arm", "bench/riscv" });
        var files: std.ArrayList([]const u8) = .empty;
        try files.appendSlice(self.gpa, try self.sources(&.{"corpus"}));
        for (self.images) |image| try self.hashable(&files, try std.fmt.allocPrint(self.gpa, "corpus/{s}", .{image.path}));
        return .{
            .harness_sha = try self.digestOf(harness_files),
            .corpus_sha = try self.digestOf(files.items),
            .oracle_sha = try self.digestOf(try self.sources(&.{"oracle"})),
        };
    }

    fn hashable(self: *Runner, into: *std.ArrayList([]const u8), path: []const u8) !void {
        if (self.present(path)) try into.append(self.gpa, path);
    }

    fn sources(self: *Runner, roots: []const []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (roots) |root| {
            var dir = std.Io.Dir.cwd().openDir(self.io, root, .{ .iterate = true }) catch {
                if (!self.present(root)) return self.refuse("{s} is missing", .{root});
                try out.append(self.gpa, root);
                continue;
            };
            defer dir.close(self.io);
            var walker = try dir.walk(self.gpa);
            defer walker.deinit();
            while (try walker.next(self.io)) |entry| {
                if (entry.kind != .file or generated(entry.path)) continue;
                try out.append(self.gpa, try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ root, entry.path }));
            }
        }
        std.mem.sort([]const u8, out.items, {}, lessThan);
        return out.items;
    }

    fn generated(path: []const u8) bool {
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (part[0] == '.' or std.mem.eql(u8, part, "out")) return true;
        }
        return std.mem.endsWith(u8, path, ".elf") or std.mem.endsWith(u8, path, ".bin");
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    fn digestOf(self: *Runner, paths: []const []const u8) ![]const u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        for (paths) |path| {
            hash.update(path);
            hash.update(try self.read(path));
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return std.fmt.allocPrint(self.gpa, "{x}", .{digest[0..8].*});
    }

    fn binaries(self: *Runner) ![]const u8 {
        var paths: std.ArrayList([]const u8) = .empty;
        for (metrics.classes) |class| {
            try paths.append(self.gpa, try self.classMachine(class));
            try paths.append(self.gpa, try self.classProbe(class));
            try paths.append(self.gpa, try self.classNull(class));
        }
        for (arches) |arch| {
            try paths.append(self.gpa, try self.stubhostOf(arch));
        }
        return self.digestOf(paths.items);
    }

    fn rebuild(self: *Runner) !void {
        var child = try std.process.spawn(self.io, .{
            .argv = &.{ "zig", "build", "-Doptimize=" ++ optimize },
            .stdout = .ignore,
        });
        const term = try child.wait(self.io);
        if (term != .exited or term.exited != 0) return self.refuse("zig build -Doptimize=" ++ optimize ++ " failed", .{});
    }

    fn onOneCore(self: *Runner, argv: []const []const u8) ![]const []const u8 {
        const cpu = self.options.cpu orelse return argv;
        const out = try self.gpa.alloc([]const u8, argv.len + 3);
        out[0] = "taskset";
        out[1] = "-c";
        out[2] = try std.fmt.allocPrint(self.gpa, "{d}", .{cpu});
        @memcpy(out[3..], argv);
        return out;
    }

    fn once(self: *Runner, argv: []const []const u8) !Ran {
        const result = try std.process.run(self.gpa, self.io, .{ .argv = try self.onOneCore(argv) });
        var out: Ran = .{};
        const at = std.mem.lastIndexOf(u8, result.stdout, "retired=") orelse return out;
        var fields = std.mem.tokenizeAny(u8, result.stdout[at..], " \n");
        while (fields.next()) |field| {
            const split = std.mem.indexOfScalar(u8, field, '=') orelse continue;
            const key = field[0..split];
            const value = field[split + 1 ..];
            if (std.mem.eql(u8, key, "retired")) out.retired = std.fmt.parseInt(u64, value, 10) catch 0;
            if (std.mem.eql(u8, key, "cycles")) out.cycles = std.fmt.parseInt(u64, value, 10) catch 0;
            if (std.mem.eql(u8, key, "latency")) out.latency = std.fmt.parseInt(u64, value, 10) catch 0;
            if (std.mem.eql(u8, key, "ns")) out.ns = std.fmt.parseInt(u64, value, 10) catch 0;
            if (std.mem.eql(u8, key, "heap")) out.heap = std.fmt.parseInt(u64, value, 10) catch 0;
            if (std.mem.eql(u8, key, "checksum")) out.checksum = std.fmt.parseInt(u32, value, 16) catch 0;
            if (std.mem.eql(u8, key, "stop")) out.stop = try self.gpa.dupe(u8, value);
        }
        return out;
    }

    fn best(self: *Runner, argv: []const []const u8) !Best {
        var out: Best = .{ .ns = std.math.maxInt(u64) };
        for (0..runs) |run| {
            const one = try self.once(argv);
            if (run != 0 and (one.retired != out.ran.retired or one.checksum != out.ran.checksum or
                !std.mem.eql(u8, one.stop, out.ran.stop))) out.steady = false;
            out.ran = one;
            out.ns = @min(out.ns, one.ns);
        }
        return out;
    }

    fn per(ran: Ran, ns: u64) f64 {
        return if (ran.retired == 0) 0 else @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(ran.retired));
    }

    fn tierOf(image: Image) u8 {
        return if (std.mem.eql(u8, image.source, "isa")) 1 else 2;
    }

    fn argvOf(self: *Runner, binary: []const u8, command: []const u8, image: Image, tail: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.gpa, &.{
            binary,
            command,
            try self.mapOf(image.map, image.arch),
            try std.fmt.allocPrint(self.gpa, "corpus/{s}", .{image.path}),
            "--budget",
            try std.fmt.allocPrint(self.gpa, "{d}", .{image.retired + 1}),
        });
        try argv.appendSlice(self.gpa, tail);
        if (image.semihosting) try argv.append(self.gpa, "--semihosting");
        return argv.items;
    }

    fn agree(a: Ran, b: Ran) bool {
        return a.retired == b.retired and a.cycles == b.cycles and
            a.checksum == b.checksum and std.mem.eql(u8, a.stop, b.stop);
    }

    fn reproduced(image: Image, seen: Best) bool {
        return seen.steady and seen.ran.retired == image.retired and
            std.mem.eql(u8, seen.ran.stop, image.stop) and
            (image.checksum == null or seen.ran.checksum == image.checksum.?);
    }

    fn corpus(self: *Runner) !Measured {
        var out: Measured = .{};
        var firmware: [2]Geo = @splat(.{});
        var system: [2]Geo = @splat(.{});
        var driven: Geo = .{};
        for (self.images) |image| {
            const binary = try self.machine(image.arch);
            if (!self.present(binary)) return self.refuse("{s} is missing", .{binary});
            const tier = tierOf(image);
            const seen = try self.best(try self.argvOf(binary, "run", image, &.{}));
            const ok = reproduced(image, seen);
            out.timing.corpus.total += 1;
            out.timing.corpus.pass += @intFromBool(ok);
            const cost = per(seen.ran, seen.ns);
            out.heap = @max(out.heap, seen.ran.heap);
            const which = @intFromBool(!std.mem.eql(u8, image.arch, "arm"));
            if (tier == 1) firmware[which].add(cost);
            if (tier == 2) {
                system[which].add(cost);
                const chip = try self.best(try self.argvOf(binary, "burst", image, &.{ "--span", burst_span }));
                const steps = try self.once(try self.argvOf(binary, "steps", image, &.{}));
                if (!agree(chip.ran, steps) or !agree(chip.ran, seen.ran)) out.chip.equivalent = false;
                out.chip.latency += chip.ran.latency;
                out.chip.retired += chip.ran.retired;
                driven.add(per(chip.ran, chip.ns));
            }
            try self.record(tier, image, cost, seen, ok);
        }
        out.timing.arm = firmware[0].mean();
        out.timing.riscv = firmware[1].mean();
        out.timing.overall = across(out.timing.arm, out.timing.riscv);
        out.chip.sys_arm = system[0].mean();
        out.chip.sys_riscv = system[1].mean();
        out.chip.chip = driven.mean();
        try self.say("corpus   fw={d:.3} sys={d:.3} chip={d:.3} ns/instr  reproduced={d}/{d} burst_equivalent={d} entry and return cycles {d} over {d} retired\n", .{
            out.timing.overall,     across(out.chip.sys_arm, out.chip.sys_riscv), out.chip.chip,
            out.timing.corpus.pass, out.timing.corpus.total,                      @intFromBool(out.chip.equivalent),
            out.chip.latency,       out.chip.retired,
        });
        return out;
    }

    fn stubhost(self: *Runner) !f64 {
        var geo: [2]Geo = @splat(.{});
        for (self.images) |image| {
            if (tierOf(image) != 1) continue;
            const binary = try self.stubhostOf(image.arch);
            if (!self.present(binary)) return self.refuse("{s} is missing", .{binary});
            const seen = try self.best(try self.argvOf(binary, "run", image, &.{}));
            geo[@intFromBool(!std.mem.eql(u8, image.arch, "arm"))].add(per(seen.ran, seen.ns));
        }
        const out = across(geo[0].mean(), geo[1].mean());
        try self.say("stubhost {d:.3} ns/instr arm={d:.3} riscv={d:.3}\n", .{ out, geo[0].mean(), geo[1].mean() });
        return out;
    }

    fn pathCosts(self: *Runner) !Paths {
        var geo: [2][2]Geo = @splat(@splat(.{}));
        for (arches) |arch| {
            const binary = try self.machine(arch);
            const image = self.firstOf(arch) orelse continue;
            const which = @intFromBool(!std.mem.eql(u8, arch, "arm"));
            for ([_][]const u8{ "access", "ppb" }, 0..) |command, lane| {
                geo[lane][which].add(try self.perAccess(binary, command, image));
            }
        }
        const out: Paths = .{
            .access = across(geo[0][0].mean(), geo[0][1].mean()),
            .ppb = across(geo[1][0].mean(), geo[1][1].mean()),
        };
        try self.say("access   {d:.3} ns per data access, {d:.3} ns per system register\n", .{ out.access, out.ppb });
        return out;
    }

    fn firstOf(self: *Runner, arch: []const u8) ?Image {
        for (self.images) |image| {
            if (tierOf(image) == 1 and std.mem.eql(u8, image.arch, arch)) return image;
        }
        return null;
    }

    fn perAccess(self: *Runner, binary: []const u8, command: []const u8, image: Image) !f64 {
        var out: f64 = 0;
        for (0..runs) |run| {
            const result = try std.process.run(self.gpa, self.io, .{ .argv = try self.onOneCore(&.{
                binary,
                command,
                try self.mapOf(image.map, image.arch),
                try std.fmt.allocPrint(self.gpa, "corpus/{s}", .{image.path}),
            }) });
            const seen = tally(Access, result.stdout);
            if (seen.accesses == 0) return 0;
            const cost = @as(f64, @floatFromInt(seen.ns)) / @as(f64, @floatFromInt(seen.accesses));
            out = if (run == 0) cost else @min(out, cost);
        }
        return out;
    }

    fn entered(self: *Runner) !f64 {
        var entries: [2]u64 = @splat(0);
        var cycles: [2]u64 = @splat(0);
        for (self.images) |image| {
            if (tierOf(image) != 2 or image.halts) continue;
            const binary = try self.machine(image.arch);
            if (!self.present(binary)) continue;
            const result = try std.process.run(self.gpa, self.io, .{ .argv = try self.onOneCore(try self.argvOf(binary, "irq", image, &.{})) });
            const seen = tally(Entered, result.stdout);
            const which = @intFromBool(!std.mem.eql(u8, image.arch, "arm"));
            entries[which] += seen.entries;
            cycles[which] += seen.entry_cycles;
        }
        const total = entries[0] + entries[1];
        const out = if (total == 0) 0 else @as(f64, @floatFromInt(cycles[0] + cycles[1])) / @as(f64, @floatFromInt(total));
        try self.say("irq      {d:.3} cycles an entry: arm {d} over {d} entries, riscv {d} over {d}\n", .{
            out, cycles[0], entries[0], cycles[1], entries[1],
        });
        return out;
    }

    fn debugged(self: *Runner) !Debug {
        var out: Debug = .{};
        var geo: [2]Geo = @splat(.{});
        var logged: Geo = .{};
        for (self.images) |image| {
            const tier = tierOf(image);
            const binary = try self.machine(image.arch);
            if (!self.present(binary)) continue;
            if (tier == 1) {
                const seen = try self.best(try self.argvOf(binary, "run", image, &.{ "--history", history_records }));
                out.violations += @intFromBool(!reproduced(image, seen));
                geo[@intFromBool(!std.mem.eql(u8, image.arch, "arm"))].add(per(seen.ran, seen.ns));
                continue;
            }
            const seen = try self.best(try self.argvOf(binary, "burst", image, &.{ "--span", burst_span, "--history", history_records, "--events", event_records }));
            out.violations += @intFromBool(!reproduced(image, seen));
            logged.add(per(seen.ran, seen.ns));
        }
        out.ns = across(geo[0].mean(), geo[1].mean());
        out.chip = logged.mean();
        try self.say("history  {d:.3} ns/instr arm={d:.3} riscv={d:.3} chip with both rings {d:.3} images that ran differently with them on={d}\n", .{
            out.ns, geo[0].mean(), geo[1].mean(), out.chip, out.violations,
        });
        return out;
    }

    fn perClass(self: *Runner, checks: *Counted) ![metrics.classes.len]Classed {
        var out: [metrics.classes.len]Classed = @splat(.{});
        for (metrics.classes, 0..) |class, i| {
            const binary = try self.classMachine(class);
            if (!self.present(binary)) return self.refuse("{s} is missing", .{binary});
            const section = try sectionsOf(try self.read(try self.classProbe(class)));
            out[i].text = section.text;
            out[i].rodata = section.rodata;
            out[i].processor_bytes = try self.machineBytes(binary);
            out[i].link_delta = @as(i64, @intCast((try self.read(binary)).len)) -
                @as(i64, @intCast((try self.read(try self.classNull(class))).len));
            if (class.timed) try self.timedClass(class, binary, &out[i], checks);
            try self.say("class    {s:<6} fw={d:.3} sys={d:.3} ns/instr  entry={d:.3} cycles  {d} bytes  text={d} rodata={d} decode={d}\n", .{
                class.name, out[i].fw, out[i].sys, out[i].irq, out[i].processor_bytes, out[i].text, out[i].rodata, out[i].link_delta,
            });
        }
        return out;
    }

    fn timedClass(self: *Runner, class: metrics.Class, binary: []const u8, into: *Classed, checks: *Counted) !void {
        var firmware: Geo = .{};
        var system: Geo = .{};
        var entries: u64 = 0;
        var cycles: u64 = 0;
        for (self.images) |image| {
            if (!std.mem.eql(u8, image.arch, class.arch)) continue;
            const tier = tierOf(image);
            if (tier == 2 and class.entry and !image.halts) {
                const result = try std.process.run(self.gpa, self.io, .{ .argv = try self.onOneCore(try self.argvOf(binary, "irq", image, &.{})) });
                const entered_ = tally(Entered, result.stdout);
                entries += entered_.entries;
                cycles += entered_.entry_cycles;
            }
            if (tier == 2 and !everywhere(image)) continue;
            const seen = try self.best(try self.argvOf(binary, "run", image, &.{}));
            checks.total += 1;
            checks.pass += @intFromBool(reproduced(image, seen));
            if (tier == 1) {
                firmware.add(per(seen.ran, seen.ns));
                try self.agreed(binary, image, checks);
                continue;
            }
            system.add(per(seen.ran, seen.ns));
        }
        into.fw = firmware.mean();
        into.sys = system.mean();
        into.irq = if (entries == 0) 0 else @as(f64, @floatFromInt(cycles)) / @as(f64, @floatFromInt(entries));
    }

    fn agreed(self: *Runner, binary: []const u8, image: Image, checks: *Counted) !void {
        const capped = [_][]const u8{ "--budget", class_budget };
        const one = try self.once(try self.argvOf(binary, "run", image, &capped));
        const stepped = try self.once(try self.argvOf(binary, "steps", image, &capped));
        const chip = try self.once(try self.argvOf(binary, "burst", image, &(capped ++ [_][]const u8{ "--span", burst_span })));
        const logged = try self.once(try self.argvOf(binary, "run", image, &(capped ++ [_][]const u8{ "--history", history_records })));
        checks.total += 3;
        checks.pass += @intFromBool(agree(one, stepped));
        checks.pass += @intFromBool(agree(one, chip));
        checks.pass += @intFromBool(agree(one, logged));
    }

    fn machineBytes(self: *Runner, binary: []const u8) !u64 {
        const result = try std.process.run(self.gpa, self.io, .{ .argv = &.{ binary, "about" } });
        return tally(About, result.stdout).processor_bytes;
    }

    fn record(self: *Runner, tier: u8, image: Image, cost: f64, seen: Best, ok: bool) !void {
        try self.detail.print(self.gpa, "{s}\t{d}\t{s}\t{s}\t{d:.4}\t{d}\t{s}\t{x:0>8}\t{d}\n", .{
            alt, tier, image.name, image.arch, cost, seen.ran.retired, seen.ran.stop, seen.ran.checksum, @intFromBool(ok),
        });
        try self.say("{s:<6} {s:<18} {d:>8.3} ns/instr  {s}\n", .{
            image.arch, image.name, cost, if (!seen.steady) "UNSTEADY" else if (ok) "ok" else "MISMATCH",
        });
    }

    fn diagnose(self: *Runner) !Diagnosis {
        var out: Diagnosis = .{};
        const cases = self.zon([]const Case, "corpus/diag/manifest.zon") catch return out;
        for (cases) |case| {
            const binary = try self.machine(case.arch);
            const path = try std.fmt.allocPrint(self.gpa, "corpus/out/diag/{s}/{s}.elf", .{ case.arch, case.case });
            if (!self.present(binary)) return self.refuse("{s} is missing", .{binary});
            if (!self.present(path)) return self.refuse("{s} is missing", .{path});
            const map = try self.mapOf(case.map, case.arch);
            const result = try std.process.run(self.gpa, self.io, .{ .argv = &.{ binary, "diag", map, path } });
            var hit = true;
            for (case.expect) |want| hit = hit and std.mem.indexOf(u8, result.stdout, want) != null;
            out.total += 1;
            out.pass += @intFromBool(hit);
        }
        try self.say("diag     {d}/{d} cases\n", .{ out.pass, out.total });
        return out;
    }

    fn interface(self: *Runner) !About {
        var out: About = .{};
        for (arches) |arch| {
            const result = try std.process.run(self.gpa, self.io, .{ .argv = &.{ try self.machine(arch), "about" } });
            var fields = std.mem.tokenizeAny(u8, result.stdout, " \n");
            while (fields.next()) |field| {
                const split = std.mem.indexOfScalar(u8, field, '=') orelse continue;
                const value = std.fmt.parseInt(u32, field[split + 1 ..], 10) catch continue;
                inline for (@typeInfo(About).@"struct".fields) |f| {
                    if (std.mem.eql(u8, field[0..split], f.name)) @field(out, f.name) = @max(@field(out, f.name), value);
                }
            }
        }
        return out;
    }

    fn lockstep(self: *Runner) ![2]Counted {
        var out: [2]Counted = @splat(.{});
        const buffer = try self.gpa.alloc(u8, 1 << 20);
        for (arches, 0..) |arch, which| {
            const binary = try self.machine(arch);
            if (!self.present(binary)) return self.refuse("{s} is missing", .{binary});
            for ([_]u8{ 1, 2 }) |tier| {
                const pins = self.read(try std.fmt.allocPrint(self.gpa, "oracle/trace_{s}{s}.txt", .{
                    arch, if (tier == 1) "" else "_sys",
                })) catch continue;
                for (self.images) |image| {
                    if (!std.mem.eql(u8, image.arch, arch) or tierOf(image) != tier) continue;
                    const pin = try self.pinOf(pins, image.name) orelse continue;
                    if (pin.windows.len == 0) continue;
                    const seen = try self.traced(binary, image, pin, tier, buffer);
                    out[which].pass += seen.pass;
                    out[which].total += seen.total;
                    try self.say("{s:<6} {s:<18} tier {d}  {d}/{d} windows\n", .{ arch, image.name, tier, seen.pass, seen.total });
                }
            }
        }
        return out;
    }

    fn traced(self: *Runner, binary: []const u8, image: Image, pin: Pin, tier: u8, buffer: []u8) !Counted {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.gpa, &.{
            binary,
            "trace",
            try self.mapOf(image.map, image.arch),
            try std.fmt.allocPrint(self.gpa, "corpus/{s}", .{image.path}),
            "--budget",
            try std.fmt.allocPrint(self.gpa, "{d}", .{pin.retired}),
        });
        if (image.semihosting) try argv.append(self.gpa, "--semihosting");
        var child = try std.process.spawn(self.io, .{ .argv = argv.items, .stdout = .pipe });
        var reader = child.stdout.?.readerStreaming(self.io, buffer);

        var out: Counted = .{};
        const riscv = std.mem.eql(u8, image.arch, "riscv");
        var digest = seed;
        var count: u64 = 0;
        var index: usize = 0;
        while (reader.interface.takeDelimiterInclusive('\n')) |line| {
            const one = recordOf(line) orelse continue;
            if (count == pin.retired) continue;
            digest = foldRecord(digest, one, riscv, tier);
            count += 1;
            if (count % window != 0) continue;
            out.pass += @intFromBool(agrees(digest, pin.windows, index));
            index += 1;
            digest = seed;
        } else |_| {}
        if (count % window != 0) {
            out.pass += @intFromBool(agrees(digest, pin.windows, index));
            index += 1;
        }
        _ = try child.wait(self.io);
        out.total = @intCast(@max(index, pin.windows.len));
        return out;
    }

    const Pin = struct { retired: u64, windows: []const []const u8 };

    fn pinOf(self: *Runner, text: []const u8, name: []const u8) !?Pin {
        var out: Pin = .{ .retired = 0, .windows = &.{} };
        var windows: std.ArrayList([]const u8) = .empty;
        var found = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            const first = fields.next() orelse continue;
            if (std.mem.eql(u8, first, "#")) {
                const named = fields.next() orelse continue;
                if (!std.mem.eql(u8, named, name)) continue;
                out.retired = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
                found = true;
                continue;
            }
            if (!std.mem.eql(u8, first, name)) continue;
            _ = fields.next() orelse continue;
            try windows.append(self.gpa, fields.next() orelse continue);
        }
        if (!found) return null;
        out.windows = windows.items;
        return out;
    }

    fn probed(self: *Runner) ![2]Counted {
        var out: [2]Counted = @splat(.{});
        for (probings, 0..) |probing, which| {
            const binary = try self.machine(probing.arch);
            if (!self.present(binary)) return self.refuse("{s} is missing", .{binary});
            const made = try std.process.run(self.gpa, self.io, .{ .argv = &.{ "sh", "oracle/mkelf.sh", probing.arch } });
            if (made.term != .exited or made.term.exited != 0) return self.refuse("oracle/mkelf.sh {s}: {s}", .{ probing.arch, made.stderr });
            const ran = try std.process.run(self.gpa, self.io, .{
                .argv = try self.onOneCore(&.{ binary, "run", probing.map, probing.elf, "--semihosting" }),
            });
            const answers = try std.fmt.allocPrint(self.gpa, "oracle/probe/out/{s}.txt", .{probing.arch});
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = answers, .data = ran.stdout });
            const judged = try std.process.run(self.gpa, self.io, .{ .argv = &.{ "sh", "oracle/probecmp.sh", probing.arch, answers } });
            const counted = tally(Judged, judged.stdout);
            out[which] = .{ .pass = counted.agree + counted.fixed + counted.known, .total = counted.total };
            try self.say("probe    {s:<6} {d} agree + {d} known + {d} fixed of {d}\n{s}", .{
                probing.arch, counted.agree, counted.known, counted.fixed, counted.total, judged.stderr,
            });
        }
        return out;
    }

    fn compiles(self: *Runner) !Compile {
        var out: Compile = .{};
        out.core_1 = try self.cold("core-1", "ReleaseFast", true, 1);
        out.core_12 = try self.cold("core-12", "ReleaseFast", true, cold_jobs);
        out.full_1 = try self.cold("full-1", "ReleaseFast", false, 1);
        out.full_12 = try self.cold("full-12", "ReleaseFast", false, cold_jobs);
        try self.say("compile  core={d:.1}/{d:.1} s full={d:.1}/{d:.1} s\n", .{
            out.core_1.seconds, out.core_12.seconds, out.full_1.seconds, out.full_12.seconds,
        });
        return out;
    }

    fn cold(self: *Runner, tag: []const u8, mode: []const u8, nulled: bool, jobs: u16) !Cold {
        const cache = try std.fmt.allocPrint(self.gpa, ".zig-cache-metrics-{s}", .{tag});
        std.Io.Dir.cwd().deleteTree(self.io, cache) catch {};
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.gpa, &.{ "zig", "build" });
        for (arches) |arch| {
            try argv.append(self.gpa, try std.fmt.allocPrint(self.gpa, "build-machine-{s}", .{arch}));
        }
        try argv.appendSlice(self.gpa, &.{
            try std.fmt.allocPrint(self.gpa, "-Doptimize={s}", .{mode}),
            try std.fmt.allocPrint(self.gpa, "-j{d}", .{jobs}),
            "--cache-dir",
            cache,
            "--global-cache-dir",
            try std.fmt.allocPrint(self.gpa, "{s}/global", .{cache}),
            "--prefix",
            try std.fmt.allocPrint(self.gpa, "{s}/out", .{cache}),
        });
        if (nulled) try argv.append(self.gpa, "-Disa=null");

        const started = std.Io.Timestamp.now(self.io, .awake);
        var child = try std.process.spawn(self.io, .{ .argv = argv.items, .stdout = .ignore, .request_resource_usage_statistics = true });
        const term = try child.wait(self.io);
        const elapsed = std.Io.Timestamp.now(self.io, .awake).nanoseconds - started.nanoseconds;
        defer std.Io.Dir.cwd().deleteTree(self.io, cache) catch {};
        if (term != .exited or term.exited != 0) return self.refuse("the cold {s} build failed", .{tag});
        return .{
            .seconds = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s,
            .rss_mb = (child.resource_usage_statistics.getMaxRss() orelse 0) >> 20,
        };
    }

    fn clock(self: *Runner) void {
        var was: linux.cpu_set_t = undefined;
        const restore = self.options.cpu != null and
            linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &was) == 0 and
            pinnedTo(self.options.cpu.?);
        const one = self.megahertz();
        if (restore) linux.sched_setaffinity(0, &was) catch {};
        self.mhz = @max(self.mhz, one);
    }

    fn megahertz(self: *Runner) f64 {
        if (self.read("/proc/cpuinfo")) |text| {
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                const at = std.mem.indexOf(u8, line, "MHz") orelse continue;
                const colon = std.mem.indexOfScalarPos(u8, line, at, ':') orelse continue;
                return std.fmt.parseFloat(f64, std.mem.trim(u8, line[colon + 1 ..], " \t\r")) catch 0;
            }
        } else |_| {}
        return calibrated(self.io);
    }

    fn commit(self: *Runner) ![]const u8 {
        const result = std.process.run(self.gpa, self.io, .{ .argv = &.{ "git", "rev-parse", "--short", "HEAD" } }) catch return "-";
        if (result.term != .exited or result.term.exited != 0) return "-";
        const text = std.mem.trim(u8, result.stdout, " \n");
        return if (text.len == 0) "-" else text;
    }

    fn append(self: *Runner, row: metrics.Row) !void {
        const path = if (self.options.release) release_path else summary_path;
        const existing = self.read(path) catch "";
        const head = try metrics.header(try self.gpa.alloc(u8, 4096));
        if (existing.len != 0 and !std.mem.startsWith(u8, existing, head)) {
            return self.refuse("{s} was written under another header: migrate it before appending", .{path});
        }
        var file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        defer file.close(self.io);
        var buffer: [1 << 16]u8 = undefined;
        var writer = file.writer(self.io, &buffer);
        try writer.interface.writeAll(if (existing.len == 0) head else existing);
        try writer.interface.writeAll(try metrics.line(row, try self.gpa.alloc(u8, 4096)));
        try writer.interface.flush();
    }
};

fn tally(comptime T: type, text: []const u8) T {
    var out: T = .{};
    var fields = std.mem.tokenizeAny(u8, text, " \n");
    while (fields.next()) |one| {
        const split = std.mem.indexOfScalar(u8, one, '=') orelse continue;
        const value = std.fmt.parseInt(u32, one[split + 1 ..], 10) catch continue;
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (std.mem.eql(u8, one[0..split], field.name)) @field(out, field.name) = value;
        }
    }
    return out;
}

const Record = struct { pc: []const u8, flags: []const u8, regs: []const u8, trap: []const u8, event: []const u8 };

const regs_length = 32 * 9 - 1;
const trap_length = 3 * 9 - 1;
const event_length = 4;
const tail_length = regs_length + 1 + trap_length + 1 + event_length;

fn recordOf(line: []const u8) ?Record {
    var fields = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line, "\r\n"), ' ');
    _ = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    const pc = fields.next() orelse return null;
    const flags = fields.next() orelse return null;
    for (0..5) |_| _ = fields.next() orelse return null;
    const tail = fields.rest();
    if (tail.len != tail_length) return null;
    return .{
        .pc = pc,
        .flags = flags,
        .regs = tail[0..regs_length],
        .trap = tail[regs_length + 1 ..][0..trap_length],
        .event = tail[tail_length - event_length ..],
    };
}

fn hashed(digest: u64, bytes: []const u8) u64 {
    var out = digest;
    for (bytes) |byte| out = (out ^ byte) *% prime;
    return out;
}

fn foldRecord(digest: u64, one: Record, riscv: bool, tier: u8) u64 {
    var out = hashed(digest, one.pc);
    out = hashed(out, " ");
    out = hashed(out, if (riscv) "00000000" else one.flags);
    out = hashed(out, " ");
    out = hashed(out, one.regs);
    if (tier == 2) {
        if (riscv) {
            out = hashed(out, " ");
            out = hashed(out, one.trap);
        }
        out = hashed(out, " ");
        out = hashed(out, one.event);
    }
    return (out ^ 0xff) *% prime;
}

fn agrees(digest: u64, expected: []const []const u8, index: usize) bool {
    if (index >= expected.len) return false;
    var hex: [16]u8 = undefined;
    const written = std.fmt.bufPrint(&hex, "{x:0>16}", .{digest}) catch return false;
    return std.mem.eql(u8, written, expected[index]);
}

const Sections = struct { text: u64 = 0, rodata: u64 = 0 };

fn sectionsOf(object: []const u8) !Sections {
    var out: Sections = .{};
    if (object.len < @sizeOf(std.elf.Elf64_Ehdr) or !std.mem.eql(u8, object[0..4], std.elf.MAGIC)) return error.NotAnObject;
    const header = std.mem.bytesToValue(std.elf.Elf64_Ehdr, object[0..@sizeOf(std.elf.Elf64_Ehdr)]);
    const names = std.mem.bytesToValue(std.elf.Elf64_Shdr, object[header.e_shoff + header.e_shstrndx * header.e_shentsize ..][0..@sizeOf(std.elf.Elf64_Shdr)]);
    for (0..header.e_shnum) |i| {
        const section = std.mem.bytesToValue(std.elf.Elf64_Shdr, object[header.e_shoff + i * header.e_shentsize ..][0..@sizeOf(std.elf.Elf64_Shdr)]);
        const at = names.sh_offset + section.sh_name;
        const name = std.mem.sliceTo(object[at..], 0);
        if (std.mem.startsWith(u8, name, ".text")) out.text += section.sh_size;
        if (std.mem.startsWith(u8, name, ".rodata")) out.rodata += section.sh_size;
    }
    return out;
}

fn pinnedTo(cpu: u16) bool {
    const bits = @bitSizeOf(usize);
    var set: linux.cpu_set_t = @splat(0);
    if (cpu / bits >= set.len) return false;
    set[cpu / bits] = @as(usize, 1) << @intCast(cpu % bits);
    linux.sched_setaffinity(0, &set) catch return false;
    return true;
}

fn calibrated(io: std.Io) f64 {
    if (builtin.cpu.arch != .aarch64) return 0;
    const iterations: u64 = 40_000_000;
    var out: f64 = 0;
    for (0..16) |_| {
        const started = std.Io.Timestamp.now(io, .awake);
        _ = asm volatile (
            \\1: subs %[out], %[out], #1
            \\   b.ne 1b
            : [out] "=r" (-> u64),
            : [count] "0" (iterations),
        );
        const elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - started.nanoseconds;
        if (elapsed == 0) continue;
        out = @max(out, @as(f64, @floatFromInt(iterations)) * 1000.0 / @as(f64, @floatFromInt(elapsed)));
    }
    return if (out < 100 or out > 10000) 0 else out;
}

fn today(io: std.Io, gpa: std.mem.Allocator) ![]const u8 {
    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    const day = std.time.epoch.EpochSeconds{ .secs = @intCast(@divTrunc(now, std.time.ns_per_s)) };
    const date = day.getEpochDay().calculateYearDay();
    const month = date.calculateMonthDay();
    return std.fmt.allocPrint(gpa, "{d}-{d:0>2}-{d:0>2}", .{ date.year, month.month.numeric(), month.day_index + 1 });
}

fn appendLog(io: std.Io, gpa: std.mem.Allocator, path: []const u8, head: []const u8, body: []const u8) !void {
    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20)) catch "";
    if (existing.len != 0 and !std.mem.startsWith(u8, existing, head)) return error.LogHeaderChanged;
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [1 << 16]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(if (existing.len == 0) head else existing);
    try writer.interface.writeAll(body);
    try writer.interface.flush();
}
