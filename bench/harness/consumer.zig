const std = @import("std");
const core = @import("core");
const contract = @import("contract.zig");
const device = @import("device.zig");
const facade = @import("facade.zig");
const snapshot = @import("snapshot.zig");

pub const usage =
    \\machine run       <map.zon> [<image.elf>] [--budget N] [--semihosting] [--history N] [--events N]
    \\machine steps     <map.zon> [<image.elf>] [--budget N] [--semihosting]
    \\machine burst     <map.zon> [<image.elf>] [--span N] [--mhz N] [--budget N] [--semihosting] [--history N] [--events N]
    \\machine trace     <map.zon> [<image.elf>] [--budget N] [--semihosting]
    \\machine diag      <map.zon> [<image.elf>] [--semihosting]
    \\machine access    <map.zon> [<image.elf>] [--count N]
    \\machine ppb       <map.zon> [<image.elf>] [--count N]
    \\machine irq       <map.zon> [<image.elf>] [--budget N] [--semihosting]
    \\machine about
    \\
;

pub const Loaded = struct {
    arena: std.mem.Allocator,
    map: core.memory.map.Map,
    elf: []const u8,
    console: ?*std.Io.Writer,
    registry: core.memory.map.Registry,
    history: usize,
};

pub fn bus(loaded: Loaded) !*core.memory.Regions {
    var blame: core.memory.map.Blame = .{};
    var images: Images = .{};
    const out = try loaded.arena.create(core.memory.Regions);
    out.* = try core.memory.map.build(loaded.arena, loaded.registry, loaded.map, &images, &blame);
    try core.memory.elf.load(loaded.elf, out);
    return out;
}

pub fn entryOf(elf: []const u8) u32 {
    return std.mem.readInt(u32, elf[24..28], .little);
}

const Images = struct {
    pub fn load(_: *Images, _: []const u8, _: []u8) core.memory.map.Image!usize {
        return error.Missing;
    }
};

const Counting = struct {
    child: std.mem.Allocator = undefined,
    live: usize = 0,
    peak: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn moved(self: *Counting, was: usize, now: usize) void {
        self.live = self.live - was + now;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(context));
        const out = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.moved(0, len);
        return out;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, new_len, ra)) return false;
        self.moved(memory.len, new_len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(context));
        const out = self.child.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.moved(memory.len, new_len);
        return out;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, ra);
        self.moved(memory.len, 0);
    }
};

const accesses: usize = 1 << 22;
const access_window: u32 = 4096;

const span_instructions: u64 = 37;
const chip_mhz: u64 = 64;

const map_limit = 64 * 1024;
const elf_limit = 64 * 1024 * 1024;
const explain_limit = 64 * 1024;

pub fn Consumer(comptime M: type) type {
    comptime facade.assertMachine(M);

    return struct {
        pub fn main(init: std.process.Init) !u8 {
            var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator());
            _ = args.skip();

            var buffer: [1 << 16]u8 = undefined;
            var file = std.Io.File.stdout().writer(init.io, &buffer);
            const out = &file.interface;

            const code = dispatch(init, out, &args) catch |err| switch (err) {
                error.Usage => blk: {
                    try out.writeAll(usage);
                    break :blk @as(u8, 2);
                },
                error.Reported => 2,
                else => return err,
            };
            try out.flush();
            return code;
        }

        fn dispatch(init: std.process.Init, out: *std.Io.Writer, args: *std.process.Args.Iterator) !u8 {
            const command = args.next() orelse return error.Usage;
            if (std.mem.eql(u8, command, "about")) return about(out);
            const job = try jobOf(args);
            if (std.mem.eql(u8, command, "run")) return run(init, out, job);
            if (std.mem.eql(u8, command, "steps")) return steps(init, out, job);
            if (std.mem.eql(u8, command, "burst")) return burst(init, out, job);
            if (std.mem.eql(u8, command, "trace")) return trace(init, out, job);
            if (std.mem.eql(u8, command, "diag")) return diag(init, out, job);
            if (std.mem.eql(u8, command, "access")) return access(init, out, job, .memory);
            if (std.mem.eql(u8, command, "ppb")) return access(init, out, job, .ppb);
            if (std.mem.eql(u8, command, "irq")) return irq(init, out, job);
            return error.Usage;
        }

        const Job = struct {
            map: []const u8,
            elf: ?[]const u8 = null,
            budget: u64 = std.math.maxInt(u64),
            history: usize = 0,
            events: usize = 0,
            span: u64 = span_instructions,
            mhz: u64 = chip_mhz,
            count: usize = accesses,
            semihosting: bool = false,
        };

        fn jobOf(args: *std.process.Args.Iterator) !Job {
            var job: Job = .{ .map = args.next() orelse return error.Usage };
            while (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "--budget")) {
                    job.budget = try number(args);
                } else if (std.mem.eql(u8, arg, "--history")) {
                    job.history = std.math.cast(usize, try number(args)) orelse return error.Usage;
                } else if (std.mem.eql(u8, arg, "--events")) {
                    job.events = std.math.cast(usize, try number(args)) orelse return error.Usage;
                } else if (std.mem.eql(u8, arg, "--span")) {
                    job.span = try number(args);
                } else if (std.mem.eql(u8, arg, "--mhz")) {
                    job.mhz = try number(args);
                } else if (std.mem.eql(u8, arg, "--count")) {
                    job.count = std.math.cast(usize, try number(args)) orelse return error.Usage;
                } else if (std.mem.eql(u8, arg, "--semihosting")) {
                    job.semihosting = true;
                } else if (job.elf != null or std.mem.startsWith(u8, arg, "--")) {
                    return error.Usage;
                } else job.elf = arg;
            }
            return job;
        }

        fn number(args: *std.process.Args.Iterator) !u64 {
            return std.fmt.parseInt(u64, args.next() orelse return error.Usage, 0) catch error.Usage;
        }

        var opened: struct { heap: Counting = .{}, base: u32 = 0, span: u32 = 0 } = .{};

        fn open(init: std.process.Init, out: *std.Io.Writer, job: Job, history: usize) !*M {
            const arena = init.arena.allocator();
            const source = std.Io.Dir.cwd().readFileAllocOptions(init.io, job.map, arena, .limited(map_limit), .of(u8), 0) catch
                return reported(init, "cannot read {s}\n", .{job.map});
            var diagnostics: std.zon.parse.Diagnostics = .{};
            const map = std.zon.parse.fromSliceAlloc(core.memory.map.Map, arena, source, &diagnostics, .{}) catch
                return reported(init, "{s}: {f}", .{ job.map, diagnostics });
            if (archOf(map.core) != M.arch) return reported(init, "{s}: the map names {s}, which this machine is not built for\n", .{ job.map, @tagName(map.core) });

            const beside = std.Io.Dir.cwd().openDir(init.io, std.fs.path.dirname(job.map) orelse ".", .{}) catch
                return reported(init, "cannot open the directory of {s}\n", .{job.map});
            const name = job.elf orelse map.elf orelse return reported(init, "{s}: no image to run\n", .{job.map});
            const dir = if (job.elf != null) std.Io.Dir.cwd() else beside;
            const image = dir.readFileAlloc(init.io, name, arena, .limited(elf_limit)) catch
                return reported(init, "cannot read {s}\n", .{name});

            for (map.regions) |region| {
                if (!region.writable) continue;
                opened.base = region.base;
                opened.span = @min(region.size, access_window);
                break;
            }

            opened.heap.child = arena;
            if (job.events != 0) try device.events.open(try arena.alloc(device.Event, job.events));
            const machine = try arena.create(M);
            machine.* = M.init(.{
                .arena = opened.heap.allocator(),
                .map = map,
                .elf = image,
                .console = if (job.semihosting) out else null,
                .registry = if (job.events != 0) device.watching else device.registry,
                .history = history,
            }) catch |err| return reported(init, "{s}: {s}\n", .{ job.map, @errorName(err) });
            device.events.follow(machine.clock());
            return machine;
        }

        fn archOf(c: core.Core) facade.Arch {
            return switch (core.familyOf(c)) {
                .arm => .armv7m,
                .riscv => .rv32imc,
            };
        }

        fn reported(init: std.process.Init, comptime fmt: []const u8, args: anytype) error{Reported} {
            var buffer: [1024]u8 = undefined;
            var file = std.Io.File.stderr().writer(init.io, &buffer);
            file.interface.print(fmt, args) catch {};
            file.interface.flush() catch {};
            return error.Reported;
        }

        fn elapsedOf(started: std.Io.Timestamp, io: std.Io) u64 {
            return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds - started.nanoseconds);
        }

        fn checksum(machine: *M) u32 {
            return machine.snapshot().regs[M.result_register];
        }

        fn run(init: std.process.Init, out: *std.Io.Writer, job: Job) !u8 {
            const machine = try open(init, out, job, job.history);
            const started = std.Io.Timestamp.now(init.io, .awake);
            const ran = machine.run(job.budget);
            const ns = elapsedOf(started, init.io);
            try out.print("retired={d} cycles={d} latency={d} stop={s} exceptions={d} irqs={d} ns={d} checksum={x:0>8} heap={d}\n", .{
                ran.retired, ran.cycles, ran.latency, @tagName(ran.stop), ran.exceptions, ran.irqs, ns, checksum(machine), opened.heap.peak,
            });
            return 0;
        }

        fn steps(init: std.process.Init, out: *std.Io.Writer, job: Job) !u8 {
            const machine = try open(init, out, job, 0);
            var total: facade.Ran = .{};
            var count: u64 = 0;
            const started = std.Io.Timestamp.now(init.io, .awake);
            while (total.retired < job.budget) {
                const one = machine.step();
                count += 1;
                gather(&total, one);
                if (one.stop != .running) break;
            } else total.stop = .budget;
            const ns = elapsedOf(started, init.io);
            try out.print("retired={d} cycles={d} stop={s} steps={d} ns={d} checksum={x:0>8}\n", .{ total.retired, total.cycles, @tagName(total.stop), count, ns, checksum(machine) });
            return 0;
        }

        fn burst(init: std.process.Init, out: *std.Io.Writer, job: Job) !u8 {
            if (job.span == 0 or job.mhz == 0) return error.Usage;
            const machine = try open(init, out, job, job.history);
            var clock: core.memory.Clock = .at(job.mhz * 1_000_000);
            const period = blk: {
                var one = clock;
                one.charge(job.span);
                break :blk one.ps;
            };
            var total: facade.Ran = .{};
            var crossings: u64 = 0;
            var next: u64 = period;
            const started = std.Io.Timestamp.now(init.io, .awake);
            while (total.retired < job.budget) {
                const one = machine.burst(job.budget - total.retired, clock.cyclesTo(next -| clock.ps));
                clock.charge(one.cycles);
                crossings += 1;
                gather(&total, one);
                if (one.stop != .running) break;
                while (clock.ps >= next) next += period;
            } else total.stop = .budget;
            const ns = elapsedOf(started, init.io);
            try out.print("retired={d} cycles={d} latency={d} stop={s} crossings={d} ps={d} ns={d} checksum={x:0>8}\n", .{
                total.retired, total.cycles, total.latency, @tagName(total.stop), crossings, clock.ps, ns, checksum(machine),
            });
            return 0;
        }

        fn gather(total: *facade.Ran, one: facade.Ran) void {
            total.retired += one.retired;
            total.cycles += one.cycles;
            total.latency += one.latency;
            total.exceptions += one.exceptions;
            total.irqs += one.irqs;
            total.stop = one.stop;
        }

        fn trace(init: std.process.Init, out: *std.Io.Writer, job: Job) !u8 {
            var discarded: std.Io.Writer.Discarding = .init(&.{});
            const machine = try open(init, &discarded.writer, job, 0);
            var retired: u64 = 0;
            while (retired < job.budget) {
                const one = machine.step();
                retired += one.retired;
                if (one.retired != 0 or one.exceptions != 0) try line(out, retired, machine.snapshot(), machine.trap());
                if (one.stop != .running) {
                    try out.print("stop={s}\n", .{@tagName(one.stop)});
                    return 0;
                }
            }
            try out.print("stop=budget\n", .{});
            return 0;
        }

        fn line(out: *std.Io.Writer, retired: u64, state: snapshot.Snapshot, trapped: snapshot.Trap) !void {
            try out.print("{d} {x:0>8} {x:0>8} {x:0>4} {x:0>2}{x:0>2}{x:0>2}{x:0>2} {x:0>16} {x:0>16} {x:0>8}", .{
                retired,           state.pc,        state.flags,   state.exception,  state.primask,
                state.basepri,     state.faultmask, state.control, state.pending_lo, state.active_lo,
                state.systick_cvr,
            });
            for (state.regs) |r| try out.print(" {x:0>8}", .{r});
            try out.print(" {x:0>8} {x:0>8} {x:0>8} {x:0>4}\n", .{ trapped.cause, trapped.epc, trapped.tval, trapped.event });
        }

        fn diag(init: std.process.Init, out: *std.Io.Writer, job: Job) !u8 {
            const machine = try open(init, out, job, 1);
            _ = machine.run(job.budget);
            const into = try init.arena.allocator().alloc(u8, explain_limit);
            try out.writeAll(machine.explain(into));
            return 0;
        }

        const ppb_register: u32 = switch (M.arch) {
            .armv7m => 0xe000_ed00,
            .rv32imc => 0x600c_2104,
        };

        fn access(init: std.process.Init, out: *std.Io.Writer, job: Job, over: enum { memory, ppb }) !u8 {
            if (job.count == 0) return error.Usage;
            const machine = try open(init, out, job, 0);
            const base = switch (over) {
                .memory => opened.base,
                .ppb => ppb_register,
            };
            const span: u32 = switch (over) {
                .memory => opened.span,
                .ppb => 4,
            };
            if (span == 0) return reported(init, "{s}: the map names no writable memory to walk\n", .{job.map});

            var read: u32 = 0;
            var at: u32 = 0;
            const started = std.Io.Timestamp.now(init.io, .awake);
            for (0..job.count) |_| {
                read +%= machine.read32(base + at) orelse 0;
                at += 4;
                if (at >= span) at = 0;
            }
            const ns = elapsedOf(started, init.io);
            std.mem.doNotOptimizeAway(read);
            try out.print("accesses={d} ns={d} ns_per_access={d:.4}\n", .{
                job.count, ns, @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(job.count)),
            });
            return 0;
        }

        fn irq(init: std.process.Init, out: *std.Io.Writer, job: Job) !u8 {
            const machine = try open(init, out, job, 0);
            var total: facade.Ran = .{};
            var entries: u64 = 0;
            var cycles: u64 = 0;
            const started = std.Io.Timestamp.now(init.io, .awake);
            while (total.retired < job.budget) {
                const one = machine.step();
                gather(&total, one);
                if (one.exceptions != 0 and fromLine(machine)) {
                    entries += 1;
                    cycles += one.cycles;
                }
                if (one.stop != .running) break;
            } else total.stop = .budget;
            const ns = elapsedOf(started, init.io);
            try out.print("retired={d} stop={s} entries={d} entry_cycles={d} ns={d}\n", .{
                total.retired, @tagName(total.stop), entries, cycles, ns,
            });
            return 0;
        }

        fn fromLine(machine: *M) bool {
            const exception = machine.snapshot().exception;
            return switch (M.arch) {
                .armv7m => exception >= 16,
                .rv32imc => exception != 0,
            };
        }

        fn about(out: *std.Io.Writer) !u8 {
            try out.print("isa_required={d} isa_optional={d} processor_bytes={d} table_bytes={d} arch={s} result_register={d}\n", .{
                comptime contract.required(M.isa_provides),
                comptime contract.optional(M.isa_provides),
                M.processor_bytes,
                M.table_bytes,
                @tagName(M.arch),
                M.result_register,
            });
            return 0;
        }
    };
}
