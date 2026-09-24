//! The RISC-V half's host for the isa step loop. Processor is one comptime-configured struct
//! holding the hart state, the spec of the part it is, the PMP, the interrupt matrix, the bus
//! and the trace ring, and it answers every question the instruction set asks: span, access,
//! touch, the PMP CSRs and the notifications. Around that sit the run loop, which tests one
//! due word a turn, the clock and the service point the bus is followed through, machine-mode
//! trap entry through mtvec, and explain.
const std = @import("std");
const builtin = @import("builtin");
const State = @import("isa").riscv.State;
const arch_step = @import("isa").riscv.step;
const core = @import("core.zig");
const instruction = @import("isa").riscv.instruction;
const Class = instruction.Class;
const Cost = instruction.Cost;
const decode = @import("isa").riscv.decode;
const csr = @import("isa").riscv.csr;
const pmp_block = @import("pmp.zig");
const intc_block = @import("intc.zig");
const regions = @import("../../memory/regions.zig");
const contract = @import("../../contract.zig");
const trace = @import("../trace.zig");

const Stop = arch_step.Stop;

/// The comptime configuration of a Processor: the parts it answers for, and the bus type.
pub const Options = struct {
    cores: []const core.Core,
    Bus: type,
};

/// What one step produced: where it ran, what it was, what it cost and what it charged.
pub const Step = struct {
    address: u32,
    class: ?Class,
    cost: ?u8,
    charged: u8,
    sequential: bool,
    asleep: bool,
    stop: ?Stop,
};

/// What a run is bounded by: an instruction budget, a cycle budget counted from here, and,
/// where `asleep` asks, a WFI nothing wakes, which otherwise waits in the run.
pub const Limit = struct { instructions: u64, cycles: u64 = std.math.maxInt(u64), asleep: bool = false };

/// Which bound stopped a run, which is the one answer that always distinguishes them.
pub const Ended = enum { budget, deadline, stopped, asleep };

/// What one run produced, counted for that run rather than as a total.
pub const Run = struct { instructions: u64, cycles: u64, stop: ?Stop, ended: Ended };

/// Builds the hart type: one struct answering the host contract over the caller's bus.
pub fn Processor(comptime options: Options) type {
    const costs = blk: {
        var out: [options.cores.len]arch_step.Model.Costs = undefined;
        for (options.cores, 0..) |c, i| {
            const s = core.spec(c);
            for (std.enums.values(Class), 0..) |class, j| out[i][j] = if (s.cycles) |cycles|
                .{ .cycles = cycles.get(class), .taken = s.taken.?.get(class) }
            else
                .{ .cycles = 1, .taken = 0 };
        }
        break :blk out;
    };
    const specs = blk: {
        var out: [options.cores.len]core.Spec = undefined;
        for (options.cores, 0..) |c, i| out[i] = core.spec(c);
        break :blk out;
    };

    const atomics = blk: {
        var any = false;
        for (specs) |s| any = any or s.groups & decode.only(&.{.a}) != 0;
        break :blk any;
    };
    return struct {
        const Self = @This();

        /// The union of the decode groups the listed parts implement, which prunes the tree.
        pub const allowed: decode.Groups = blk: {
            var m: decode.Groups = 0;
            for (specs) |s| m |= s.groups;
            break :blk m;
        };

        /// This family's trace module, reachable from the processor type itself.
        pub const Trace = trace;
        /// This family's semihosting module, reachable from the processor type itself.
        pub const semihosting = @import("../semihosting.zig");

        const stopped_due: u32 = 1 << 0;
        const interrupt_due: u32 = 1 << 1;
        const asleep_due: u32 = 1 << 2;

        const bound_due: u32 = 1 << 3;

        const sleep_limit: u32 = 1 << 16;

        const Taken = struct { cause: csr.Cause, at: u32, value: u32, protected: bool };

        spec: core.Spec,
        model: arch_step.Model,
        state: State,
        memory: *options.Bus,
        pmp: pmp_block.Pmp,
        intc: intc_block.Intc,
        unguarded: bool,
        guarding: u32,
        due: u32,
        cycles: u64,
        exceptions: u64,
        irqs: u64,
        serviced: u64,
        attention: u64,
        deadline: u64,
        instructions: u64,
        stop: ?Stop,
        redirected: bool,
        trace: trace.Ring,
        last: trace.Registers,
        touched: ?u32,
        last_access: u32,
        taken: ?Taken,
        protected: bool,
        last_fetch: u32,
        returns: u64,

        fn slotOf(c: core.Core) usize {
            for (options.cores, 0..) |candidate, i| {
                if (candidate == c) return i;
            }
            unreachable;
        }

        /// A hart of that part over the bus, at its reset PC, with the caller's ring attached.
        pub fn init(memory: *options.Bus, c: core.Core, ring: trace.Ring) Self {
            const at = slotOf(c);
            const spec = specs[at];
            var made: Self = .{
                .spec = spec,
                .model = .{ .decoding = spec.groups, .costs = costs[at] },
                .state = .{ .csr = .{ .implementation = spec.model, .mtvec = @intFromBool(spec.model.tvec_modes == .vectored) } },
                .memory = memory,
                .pmp = .{ .static_priority = spec.pmp_static_priority },
                .intc = .{ .layout = spec.intc },
                .unguarded = true,
                .guarding = 0,
                .due = 0,
                .cycles = 0,
                .exceptions = 0,
                .irqs = 0,
                .serviced = 0,
                .attention = 0,
                .deadline = std.math.maxInt(u64),
                .instructions = 0,
                .stop = null,
                .redirected = true,
                .trace = ring,
                .last = @splat(0),
                .touched = null,
                .last_access = 0,
                .taken = null,
                .protected = false,
                .last_fetch = 0,
                .returns = 0,
            };
            made.reguard();
            made.atReset();
            return made;
        }

        const leaf_gate: ?decode.Groups = if (options.cores.len == 1) specs[0].groups else null;

        /// The decode groups this hart runs, which the disassembler is rendered against.
        pub fn groups(self: *const Self) decode.Groups {
            return self.model.decoding;
        }

        /// What the cycle table charges an instruction class.
        pub fn costOf(self: *const Self, class: Class) Cost {
            return self.model.costOf(class);
        }

        /// Returns a running hart to its reset state, keeping the bus, the part and the ring.
        pub fn reset(self: *Self) void {
            self.* = init(self.memory, self.spec.core, self.trace);
        }

        fn atReset(self: *Self) void {
            self.state.pc = self.spec.reset_pc;
            if (self.trace.recording()) self.last = trace.snapshot(&self.state);
        }

        /// Stands the hart still at a stop, which every later run and step then does nothing past.
        pub fn lockAt(self: *Self, stop: Stop) Stop {
            self.stop = stop;
            self.due |= stopped_due;
            return stop;
        }

        /// Writes one record, if a ring is attached.
        pub fn record(self: *Self, pc: u32, code: ?u32, why: trace.Note) void {
            if (!self.trace.recording()) return;
            self.trace.reserve().write(pc, code, &self.last, &self.state, self.touched, self.cycles, why);
        }

        fn refusalOf(self: *const Self, trap: arch_step.Trap) trace.Note.Refusal {
            return switch (trap) {
                .instruction_access_fault, .load_access_fault, .store_access_fault => if (self.protected) .protection else .no_memory,
                else => .none,
            };
        }

        /// Drops the address this instruction touched, so the next one records its own.
        pub fn forget(self: *Self) void {
            self.touched = null;
        }

        /// Runs one instruction, or takes one interrupt when one is due, and reports it.
        pub fn step(self: *Self) Step {
            self.leaveBreakpoint();
            const cycles = self.cycles;
            const address = self.state.pc;
            const sequential = !self.redirected;
            var r: arch_step.Result = .{};
            if (self.due & asleep_due == 0) {
                if (self.due != 0 and self.attend()) {
                    self.redirected = true;
                } else {
                    r = if (self.trace.recording()) self.perform(self.model, true) else self.perform(self.model, false);
                    self.redirected = r.branched or r.trap != .none;
                }
            }
            return .{
                .address = address,
                .class = if (r.executed) r.class else null,
                .cost = if (r.executed and self.spec.cycles != null) r.cycles else null,
                .charged = @intCast(self.cycles - cycles),
                .sequential = sequential,
                .asleep = self.due & asleep_due != 0,
                .stop = self.stop,
            };
        }

        fn leaveBreakpoint(self: *Self) void {
            if (self.stop != .breakpoint) return;
            self.stop = null;
            self.state.pc +%= if (decode.escapes(self.parcel(self.state.pc) orelse return)) 4 else 2;
        }

        fn perform(self: *Self, model: arch_step.Model, comptime tracing: bool) arch_step.Result {
            if (tracing) self.forget();
            const pc = self.state.pc;
            const r = @call(.always_inline, arch_step.step, .{ Self, leaf_gate, &self.state, self, model });
            if (tracing) {
                if (r.trap == .load_access_fault or r.trap == .store_access_fault) self.touched = self.last_access;
                self.record(pc, r.fetchedCode(), .{ .refused = self.refusalOf(r.trap) });
            }
            if (r.executed) {
                self.instructions += 1;
                self.charge(r.cycles);
            }
            self.stop = if (r.halted) self.settle(r) else null;
            return r;
        }

        fn advance(self: *Self, model: arch_step.Model, comptime tracing: bool) ?Stop {
            _ = @call(.always_inline, perform, .{ self, model, tracing });
            return self.stop;
        }

        noinline fn settle(self: *Self, r: arch_step.Result) ?Stop {
            if (r.trap == .none) return r.stop;
            self.remember(r);
            if (self.state.privilege == .machine and self.state.pc == self.state.csr.mtvec & self.state.csr.implementation.tvec_base_mask) return self.lockAt(.unrecoverable_trap);
            self.exceptions += 1;
            self.state.pc = self.state.csr.enter(&self.state.privilege, self.causeOf(r.trap), self.valueOf(r), self.state.pc);
            self.forget();
            self.record(self.state.pc, null, .{ .kind = .entry, .number = @intCast(@intFromEnum(self.causeOf(r.trap))) });
            self.release();
            self.reguard();
            self.rearm();
            return null;
        }

        fn remember(self: *Self, r: arch_step.Result) void {
            self.taken = .{
                .cause = self.causeOf(r.trap),
                .at = self.state.pc,
                .value = self.valueOf(r),
                .protected = self.protected,
            };
            self.protected = false;
        }

        fn causeOf(self: *const Self, trap: arch_step.Trap) csr.Cause {
            return switch (trap) {
                .none => unreachable,
                .instruction_access_fault => .instruction_access_fault,
                .illegal_instruction => .illegal_instruction,
                .load_access_fault => .load_access_fault,
                .store_access_fault => .store_access_fault,
                .environment_call => if (self.state.privilege == .user) .ecall_from_user else .ecall_from_machine,
            };
        }

        fn valueOf(self: *const Self, r: arch_step.Result) u32 {
            return switch (r.trap) {
                .instruction_access_fault => self.last_fetch,
                .illegal_instruction => r.code,
                .load_access_fault, .store_access_fault => self.last_access,
                .none, .environment_call => 0,
            };
        }

        /// Adds cycles to the hart's count, servicing the bus once the count passes the attention point.
        pub fn charge(self: *Self, cycles: u32) void {
            self.cycles += cycles;
            if (self.cycles >= self.attention) self.service();
        }

        noinline fn service(self: *Self) void {
            self.serviced = self.cycles;
            if (self.memory.interrupts()) |lines| self.pendAll(lines);
            self.schedule();
            if (self.cycles >= self.deadline) self.due |= bound_due;
        }

        fn schedule(self: *Self) void {
            self.memory.follow(&self.cycles, &self.attention);
            const next = self.serviced +| self.memory.untilDue();
            self.attention = if (self.cycles < self.deadline) @min(next, self.deadline) else next;
        }

        /// Raises one interrupt matrix source.
        pub fn pend(self: *Self, line: regions.Line) void {
            if (line >= regions.lines) return;
            self.pendAll(@as(regions.Lines, 1) << line);
        }

        /// Raises a whole set of sources, then recomputes what the hart owes attention to.
        pub fn pendAll(self: *Self, lines: regions.Lines) void {
            self.observe();
            self.intc.raise(lines);
            self.recompute();
        }

        noinline fn observe(self: *Self) void {
            self.intc.hold(self.memory.asserted());
        }

        /// Whether a source is routed, unmasked, above the threshold and not gated out by mie.
        pub fn enabled(self: *const Self, line: regions.Line) bool {
            const id = self.intc.routed(line) orelse return false;
            return self.intc.unmasked(id) and self.gate() >> id & 1 != 0;
        }

        /// Polls the lines devices hold high and recomputes what the hart owes attention to.
        pub fn rearm(self: *Self) void {
            self.observe();
            self.recompute();
        }

        fn recompute(self: *Self) void {
            if (self.spec.model.interrupt_csrs) self.state.csr.mip = self.intc.status();
            const arrived = self.intc.best(self.gate()) != null;
            const taking = self.globallyEnabled() and arrived;
            const held = bound_due | (if (arrived) stopped_due else stopped_due | asleep_due);
            self.due = (self.due & held) | (if (taking) interrupt_due else 0);
        }

        fn globallyEnabled(self: *const Self) bool {
            return self.state.csr.mstatus.mie or self.state.privilege != .machine;
        }

        fn gate(self: *const Self) u32 {
            return if (self.spec.model.interrupt_csrs) self.state.csr.mie else ~@as(u32, 0);
        }

        /// Finishes an MRET: breaks the reservation, reguards, and polls the held lines again.
        pub fn returned(self: *Self) void {
            self.returns += 1;
            self.release();
            self.reguard();
            self.rearm();
        }

        /// Takes a WFI, unless an interrupt is already asking.
        pub fn sleep(self: *Self) void {
            if (self.intc.best(self.gate()) != null) return;
            self.due |= asleep_due;
        }

        noinline fn attend(self: *Self) bool {
            if (self.due & stopped_due != 0) return true;
            if (self.due & asleep_due != 0) self.stall();
            const taking = (if (self.globallyEnabled()) self.intc.best(self.gate()) else null) orelse {
                self.rearm();
                return false;
            };
            self.exceptions += 1;
            self.irqs += 1;
            self.state.pc = self.state.csr.interrupt(&self.state.privilege, taking, self.state.pc);
            self.forget();
            self.record(self.state.pc, null, .{ .kind = .irq, .number = taking });
            self.release();
            self.reguard();
            self.rearm();
            return true;
        }

        fn stall(self: *Self) void {
            var waited: u32 = 0;
            while (self.due & asleep_due != 0 and waited < sleep_limit) {
                const ahead: u64 = self.attention -| self.cycles;
                const left: u64 = sleep_limit - waited;
                const jump: u32 = @intCast(@max(@as(u64, 1), @min(ahead, left)));
                waited += jump;
                self.charge(jump);
            }
            self.due &= ~asleep_due;
        }

        /// Executes to a budget, a deadline, a stop or a sleep; a ring attached takes a second copy of the loop.
        pub fn run(self: *Self, limit: Limit) Run {
            self.redirected = true;
            self.deadline = self.cycles +| limit.cycles;
            self.due &= ~bound_due;
            self.schedule();
            if (self.cycles >= self.deadline) self.due |= bound_due;
            if (self.trace.recording()) return @call(.never_inline, loop, .{ self, limit, true });
            return loop(self, limit, false);
        }

        fn loop(self: *Self, limit: Limit, comptime tracing: bool) align(64) Run {
            if (limit.instructions == 0) return .{ .instructions = 0, .cycles = 0, .stop = null, .ended = .budget };
            const model = self.model;
            const instructions = self.instructions;
            const cycles = self.cycles;
            var stop: ?Stop = null;
            const ends = bound_due | if (limit.asleep) asleep_due else 0;
            if (self.due & bound_due != 0) return .{ .instructions = 0, .cycles = 0, .stop = null, .ended = .deadline };
            self.leaveBreakpoint();
            outer: while (self.instructions - instructions < limit.instructions) {
                if (self.due != 0) {
                    if (self.due & ends != 0) break;
                    if (self.attend()) {
                        stop = self.stop;
                        if (stop != null) break;
                        continue;
                    }
                }
                stop = @call(.always_inline, advance, .{ self, model, tracing });
                if (stop != null) break;
                if (tracing) continue;
                while (self.instructions - instructions < limit.instructions) {
                    if (self.due != 0) continue :outer;
                    stop = @call(.always_inline, advance, .{ self, model, tracing });
                    if (stop != null) break :outer;
                }
            }
            return .{
                .instructions = self.instructions - instructions,
                .cycles = self.cycles - cycles,
                .stop = stop,
                .ended = if (stop != null) .stopped else if (self.due & ends & asleep_due != 0) .asleep else if (self.cycles >= self.deadline) .deadline else .budget,
            };
        }

        /// Prints the stop, the last records, the trap and its CSRs, and any source routed nowhere.
        pub fn explain(self: *const Self, w: *std.Io.Writer, recap: u64) !void {
            if (self.stop) |stop| try trace.explain(w, stop, &self.trace, recap, self.groups());
            if (self.taken) |t| try self.blame(w, t);
            try self.unrouted(w);
        }

        fn blame(self: *const Self, w: *std.Io.Writer, t: Taken) !void {
            try w.print("The hart took a trap at pc={x:0>8}: {s}", .{ t.at, nameOf(t.cause) });
            switch (t.cause) {
                .load_access_fault, .store_access_fault => try w.print(" reaching {x:0>8}", .{t.value}),
                .illegal_instruction => try w.print(" on the code {x:0>4}", .{t.value}),
                .instruction_access_fault => try w.print(" fetching {x:0>8}", .{t.value}),
                else => {},
            }
            if (t.protected) try w.print(", which the PMP refused: pmpcfg0={x:0>8}", .{self.pmp.read(.pmpcfg0)});
            try w.print(".\nmtvec={x:0>8} mcause={x:0>8} mepc={x:0>8} mtval={x:0>8}\n", .{
                self.state.csr.mtvec, self.state.csr.mcause, self.state.csr.mepc, self.state.csr.mtval,
            });
        }

        fn nameOf(cause: csr.Cause) []const u8 {
            return switch (cause) {
                .instruction_access_fault => "instruction access fault",
                .illegal_instruction => "illegal instruction",
                .load_access_fault => "load access fault",
                .store_access_fault => "store access fault",
                .ecall_from_user, .ecall_from_machine => "environment call",
            };
        }

        fn unrouted(self: *const Self, w: *std.Io.Writer) !void {
            var held = self.memory.asserted();
            while (held != 0) : (held &= held - 1) {
                const source: regions.Line = @intCast(@ctz(held));
                if (self.intc.routed(source) != null) continue;
                try w.print("The interrupt matrix source {d} is asserted and its MAP_REG at {x:0>8} holds zero, so it is routed nowhere and CPU_INT_ENABLE={x:0>8} cannot let it through.\n", .{
                    source, self.intc.layout.matrix_base +% 4 * @as(u32, source), self.intc.enabled,
                });
            }
        }

        inline fn permits(self: *Self, address: u32, comptime wanted: contract.Kind) bool {
            if (builtin.mode == .Debug) std.debug.assert(self.unguarded == self.guardless());
            if (self.unguarded) return true;
            return @call(.never_inline, refused, .{ self, address, wanted });
        }

        fn refused(self: *Self, address: u32, comptime wanted: contract.Kind) bool {
            if (self.pmp.permits(address, self.state.privilege, wanted)) return true;
            self.protected = true;
            return false;
        }

        /// Recomputes the guard word and unfolds the cache if anything deciding a refusal changed.
        pub fn reguard(self: *Self) void {
            const stood = self.guarding;
            self.unguarded = self.guardless();
            self.guarding = @intFromBool(self.unguarded) | @as(u32, @intFromEnum(self.state.privilege)) << 1;
            if (stood != self.guarding) self.memory.folded.unfold();
        }

        fn guardless(self: *const Self) bool {
            return self.state.privilege == .machine and !self.pmp.restrictive();
        }

        /// Answers a pmpcfg or pmpaddr CSR read from the unit.
        pub fn readPmp(self: *Self, number: csr.Protection) u32 {
            return self.pmp.read(number);
        }

        /// Takes a PMP write and unfolds everything, since one write can change every answer.
        pub fn writePmp(self: *Self, number: csr.Protection, value: u32) void {
            self.pmp.write(number, value);
            self.memory.folded.unfold();
            self.reguard();
        }

        /// The address a run of accesses began at: it feeds mtval and the record, and breaks the reservation.
        pub fn touch(self: *Self, address: u32) void {
            self.last_access = address;
            self.release();
            if (self.trace.recording() and self.touched == null) self.touched = address;
        }

        inline fn release(self: *Self) void {
            if (atomics) self.state.reservation = null;
        }

        /// The bytes an access may use directly, from the folded lane, refolding out of line if it must.
        pub fn span(self: *Self, at: u32, comptime a: contract.Access) []u8 {
            const kind = a.kind;
            const bytes = self.memory.folded.reach(at, a.bytes, kind, self, describe);
            if (builtin.mode == .Debug and bytes.len != 0) self.verify(at, kind);
            return bytes;
        }

        fn describe(self: *Self, address: u32, kind: contract.Kind) regions.Block {
            const found = self.memory.lookup(address);
            var low: u64 = found.base;
            var high: u64 = @as(u64, found.base) + found.len;
            var backed = found.host != null and (kind != .write or found.writable);
            for ([_]u32{ self.intc.layout.matrix_base, self.intc.layout.control_base }) |base| {
                regions.narrow(address, &low, &high, base);
                regions.narrow(address, &low, &high, @as(u64, base) + intc_block.size);
            }
            if (self.intc.region(address) != .memory) backed = false;
            if (backed and !self.unguarded) backed = self.guarded(address, &low, &high, kind);
            return .{
                .base = @intCast(low),
                .len = high - low,
                .host = if (backed) found.host.? + (low - found.base) else null,
            };
        }

        fn guarded(self: *Self, address: u32, low: *u64, high: *u64, kind: contract.Kind) bool {
            for (0..pmp_block.entries) |i| bound(&self.pmp, i, address, low, high);
            return self.pmp.permits(address, self.state.privilege, kind);
        }

        fn bound(unit: *const pmp_block.Pmp, i: usize, address: u32, low: *u64, high: *u64) void {
            const first: u64, const last: u64 = switch (unit.cfg[i].mode) {
                .off => return,
                .tor => .{ if (i == 0) 0 else @as(u64, unit.addr[i - 1]) << 2, @as(u64, unit.addr[i]) << 2 },
                .na4 => .{ @as(u64, unit.addr[i]) << 2, (@as(u64, unit.addr[i]) << 2) + 4 },
                .napot => napot: {
                    const ones = @ctz(~unit.addr[i]);
                    const start = (@as(u64, unit.addr[i]) & ~((@as(u64, 1) << ones) - 1)) << 2;
                    break :napot .{ start, start + (@as(u64, 1) << (@as(u6, ones) + 3)) };
                },
            };
            regions.narrow(address, low, high, first);
            regions.narrow(address, low, high, last);
        }

        fn verify(self: *Self, address: u32, comptime kind: contract.Kind) void {
            const block = self.describe(address, kind);
            const host = block.host orelse unreachable;
            const cached = self.memory.folded.span(address, 1, kind);
            std.debug.assert(host + (address - block.base) == cached.ptr);
            std.debug.assert(self.permits(address, kind));
            std.debug.assert(self.intc.region(address) == .memory);
        }

        /// The slow lane: the PMP, the interrupt matrix windows, and whatever no span could answer.
        pub fn access(self: *Self, at: u32, comptime a: contract.Access, value: u32) contract.Failure!u32 {
            if (a.kind == .fetch) {
                if (!self.permits(at, .fetch)) return self.unfetched(at);
                return self.memory.parcel(at) orelse self.unfetched(at);
            }
            if (!self.permits(at, a.kind)) return error.DataFault;
            const T = contract.Word(a.bytes);
            const peripheral = self.intc.region(at) != .memory;
            if (a.kind == .write) {
                const word: T = @truncate(value);
                if (peripheral) {
                    if (a.bytes == 4) {
                        self.intc.writeRegister(at, word);
                        self.rearm();
                    }
                    return 0;
                }
                const done = self.memory.poke(a.bytes, at, word);
                return if (done == null) error.DataFault else 0;
            }
            if (peripheral) {
                if (a.bytes == 4) {
                    self.observe();
                    return self.intc.readRegister(at);
                }
                return self.readLane(T, at);
            }
            const got: ?T = self.memory.peek(a.bytes, at);
            if (got) |word| return word;
            return error.DataFault;
        }

        noinline fn unfetched(self: *Self, address: u32) contract.Failure {
            self.last_fetch = address;
            return error.DataFault;
        }

        /// One halfword of code, without letting the lookup blame the PMP for a later trap.
        pub fn parcel(self: *Self, address: u32) ?u16 {
            const held = self.protected;
            defer self.protected = held;
            return contract.read(Self, self, address, .{ .kind = .fetch, .bytes = 2 });
        }

        /// One word straight from the bus, which the semihosting markers are recognised through.
        pub fn fetch32(self: *Self, address: u32) ?u32 {
            return self.memory.peek(4, address);
        }

        /// Reads one, two or four bytes the way the hart would, without raising a trap.
        pub fn peek(self: *Self, comptime bytes: u8, address: u32) ?contract.Word(bytes) {
            const held = self.protected;
            defer self.protected = held;
            return contract.read(Self, self, address, .{ .kind = .read, .bytes = bytes });
        }

        /// Writes one, two or four bytes the way the hart would, without raising a trap.
        pub fn poke(self: *Self, comptime bytes: u8, address: u32, value: contract.Word(bytes)) ?void {
            const held = self.protected;
            defer self.protected = held;
            return contract.write(Self, self, address, .{ .kind = .write, .bytes = bytes }, value);
        }

        fn readLane(self: *Self, comptime T: type, address: u32) T {
            self.observe();
            const word = self.intc.readRegister(address & ~@as(u32, 3));
            return @truncate(word >> @intCast((address & 3) * 8));
        }
    };
}
