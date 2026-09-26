//! The Arm half's host for the isa step loop. Processor holds the core state, the spec of
//! the part it is, SysTick, the SCB, the NVIC, the DWT, the SAU and the two MPUs, the bus and
//! the trace ring, and answers every question the instruction set asks. Around that sits the
//! exception model: one set over exception numbers for pending and one for active, entry
//! through the vector table with the floating-point frame and its lazy bookkeeping, tail
//! chaining, escalation to HardFault and then to lockup, and the run loop over a due word.
const std = @import("std");
const builtin = @import("builtin");
const State = @import("isa").arm.State;
const arch_step = @import("isa").arm.step;
const core = @import("core.zig");
const instruction = @import("isa").arm.instruction;
const Class = instruction.Class;
const Cost = instruction.Cost;
const Architecture = @import("isa").arm.Architecture;
const decode = @import("isa").arm.decode;
const ppb = @import("ppb.zig");
const SysTick = @import("systick.zig").SysTick;
const scb_block = @import("scb.zig");
const nvic_block = @import("nvic.zig");
const dwt_block = @import("dwt.zig");
const sau_block = @import("sau.zig");
const m7_block = @import("m7.zig");
const icb_block = @import("icb.zig");
const impdef_block = @import("impdef.zig");
const ras_block = @import("ras.zig");
const ewic_block = @import("ewic.zig");
const mpu_block = @import("mpu.zig");
const trace = @import("../trace.zig");
const regions = @import("../../memory/regions.zig");
const contract = @import("../../contract.zig");
const fp = @import("isa").arm.fp;

const Stop = arch_step.Stop;

const sg_half: u16 = 0xe97f;

/// The comptime configuration of a Processor: the cores it answers for, and the bus type.
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
/// where `asleep` asks, a WFI or WFE nothing wakes, which otherwise waits in the run.
pub const Limit = struct { instructions: u64, cycles: u64 = std.math.maxInt(u64), asleep: bool = false };

/// Which bound stopped a run, which is the one answer that always distinguishes them.
pub const Ended = enum { budget, deadline, stopped, asleep };

/// What one run produced, latency being the cycles of it spent in exception entry and return.
pub const Run = struct { instructions: u64, cycles: u64, latency: u64, stop: ?Stop, ended: Ended };

/// One exception number; a Non-secure alias is its Secure number plus ns_base.
pub const Index = u9;

/// NMI.
pub const nmi: Index = 2;
const hard_fault: Index = 3;
const mem_manage: Index = 4;
const bus_fault: Index = 5;
const usage_fault: Index = 6;
const secure_fault: Index = 7;
const svcall: Index = 11;
/// PendSV.
pub const pendsv: Index = 14;
/// SysTick.
pub const systick: Index = 15;
/// IRQ 0, which every interrupt line is offset by.
pub const first_interrupt: Index = 16;
const restricted: i16 = 0x80;

const return_to_handler: u32 = 0xffff_fff1;
const return_to_thread_main: u32 = 0xffff_fff9;

const frame_align: u32 = 1 << 9;
const frame_sfpa: u32 = 1 << 20;
const basic_frame: u32 = 1 << 4;
const secure_stack: u32 = 1 << 6;
const default_callee: u32 = 1 << 5;
const secure_target: u32 = 1 << 0;
const callee_frame: u32 = 0x28;
const state_frame: u32 = 0x20;
const fp_caller_frame: u32 = 0x48;
const fp_callee_frame: u32 = 0x40;
const signature: u32 = 0xfefa_125a;

const Next = struct { n: Index, priority: i16 };

fn frameSize(wide_frame: bool, callee_fp: bool) u32 {
    return state_frame + (if (wide_frame) fp_caller_frame else 0) + (if (callee_fp) fp_callee_frame else 0);
}

/// Builds the core type: one struct answering the host contract over the caller's bus.
pub fn Processor(comptime options: Options) type {
    const profiles = blk: {
        var out: [options.cores.len]scb_block.Profile = undefined;
        for (options.cores, 0..) |c, i| out[i] = scb_block.profileOf(c);
        break :blk out;
    };
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
    const M7 = if (std.mem.indexOfScalar(core.Core, options.cores, .m7) != null) m7_block.Control else void;
    const Impdef = for (options.cores) |c| {
        if (c == .m55 or c == .m85) break impdef_block.Block;
    } else void;
    const Ewic = if (Impdef == void) void else ewic_block.Ewic;
    const choices = blk: {
        var out: [options.cores.len]core.Choices = undefined;
        for (options.cores, 0..) |c, i| out[i] = core.choicesOf(c);
        break :blk out;
    };
    const Mpu = blk: {
        var most: u16 = 0;
        for (choices) |c| most = @max(most, c.mpu_regions.most(), c.mpu_ns_regions.most());
        break :blk mpu_block.Mpu(@intCast(most));
    };
    const SysTickNs = for (specs) |s| {
        if (s.security) break ?SysTick;
    } else void;
    const MpuNs = for (choices) |c| {
        if (c.mpu_ns_regions.most() != 0) break Mpu;
    } else void;
    const lines = blk: {
        var most: u16 = nvic_block.lines;
        for (choices) |c| most = @max(most, c.interrupts.most());
        break :blk most;
    };
    const Nvic = nvic_block.Nvic(lines);
    return struct {
        const Self = @This();

        /// A set of the interrupt lines the listed cores may carry, one bit each: 480 where one of them is an M33, M55 or M85, else 240.
        pub const Lines = Nvic.Lines;
        /// Where the Non-secure aliases begin, above every Secure exception number.
        pub const ns_base: Index = first_interrupt + lines;
        /// A set of exception numbers, both banks in one word.
        pub const Set = std.meta.Int(.unsigned, @as(u16, ns_base) + first_interrupt);

        /// The set holding one exception number.
        pub fn one(i: Index) Set {
            return @as(Set, 1) << @intCast(i);
        }

        fn nameOf(i: Index) []const u8 {
            return switch (numberOf(i)) {
                1 => "Reset",
                nmi => "NMI",
                hard_fault => "HardFault",
                mem_manage => "MemManage",
                bus_fault => "BusFault",
                usage_fault => "UsageFault",
                secure_fault => "SecureFault",
                svcall => "SVCall",
                12 => "DebugMonitor",
                pendsv => "PendSV",
                systick => "SysTick",
                else => "IRQ",
            };
        }

        fn numberOf(i: Index) Index {
            return if (i >= ns_base) i - ns_base else i;
        }

        fn bit(set: Set, n: Index) u32 {
            return @truncate((set >> @intCast(n)) & 1);
        }

        fn summary(set: Set) u32 {
            return @as(u32, @truncate(set & 3)) | @as(u32, @intFromBool(set >> 2 != 0)) << 2;
        }

        /// The union of the decode groups the listed cores need, which prunes the tree.
        pub const allowed: decode.Groups = blk: {
            var m: decode.Groups = 0;
            for (specs) |s| m |= decode.selectionOf(s.architecture).groups;
            break :blk m;
        };

        /// This family's trace module, reachable from the processor type itself.
        pub const Trace = trace;
        /// This family's semihosting module, reachable from the processor type itself.
        pub const semihosting = @import("../semihosting.zig");

        const Flags = packed struct(u8) {
            sttns: bool = false,
            escalated: bool = false,
            event: bool = false,
            for_event: bool = false,
            nocp_secure: bool = false,
            _: u3 = 0,
        };

        const stopped: Set = 1 << 0;
        const returned: Set = 1 << 1;
        const stopped_due: u32 = 1 << 0;
        const returned_due: u32 = 1 << 1;
        const other_due: u32 = 1 << 2;
        const reset_due: u32 = 1 << 4;

        const asleep_due: u32 = 1 << 3;

        const bound_due: u32 = 1 << 5;

        const kept_due: u32 = asleep_due | reset_due | bound_due;

        const sleep_limit: u32 = 1 << 16;

        const Taken = struct { kind: Stop, n: Index, at: u32, address: u32, code: ?u32, vector: Vector };

        const Vector = struct { n: Index = 0, at: u32 = 0, target: u32 = 0, from: u32 = 0 };

        spec: core.Spec,
        model: arch_step.Model,
        state: State,
        memory: *options.Bus,
        systick: SysTick,
        systick_ns: SysTickNs,
        scb: scb_block.Scb,
        scb_ns: scb_block.Scb,
        icb: icb_block.Icb,
        nvic: Nvic,
        dwt: dwt_block.Dwt,
        sau: sau_block.Sau,
        m7: M7,
        impdef: Impdef,
        ewic: Ewic,
        mpu: Mpu,
        mpu_ns: MpuNs,
        banked: State.Banked,
        itns: Lines,
        flags: Flags,
        active: Set,
        pending: Set,
        due: u32,
        cycles: u64,
        exceptions: u64,
        irqs: u64,
        latency: u64,
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
        override: ?Stop,
        derived: ?Index,
        protection: bool,
        unguarded: bool,
        guarding: u32,
        forced_unpriv: bool,
        taken: ?Taken,
        vector: Vector,

        fn slotOf(c: core.Core) usize {
            for (options.cores, 0..) |candidate, i| {
                if (candidate == c) return i;
            }
            unreachable;
        }

        /// A core of that part over the bus, with what the part was built with, reset through the vector table, with the ring attached.
        pub fn init(memory: *options.Bus, c: core.Core, part: core.Part, ring: trace.Ring) Self {
            return build(memory, c, fitted(c, part), ring);
        }

        fn fitted(c: core.Core, part: core.Part) core.Part {
            const at = slotOf(c);
            const spec = specs[at];
            const choice = choices[at];
            var out = part;
            out.mpu_regions = if (part.mpu_regions) |n| @intCast(choice.mpu_regions.fit(n)) else spec.mpu_regions;
            out.mpu_ns_regions = if (part.mpu_ns_regions) |n| @intCast(choice.mpu_ns_regions.fit(n)) else if (spec.security) spec.mpu_regions else 0;
            out.sau_regions = if (part.sau_regions) |n| @intCast(choice.sau_regions.fit(n)) else if (spec.security) sau_block.regions else 0;
            out.priority_bits = if (part.priority_bits) |n| @intCast(choice.priority_bits.fit(n)) else spec.priority_bits;
            out.interrupts = if (part.interrupts) |n| choice.interrupts.fit(n) else @min(choice.interrupts.most(), nvic_block.lines);
            return out;
        }

        fn build(memory: *options.Bus, c: core.Core, part: core.Part, ring: trace.Ring) Self {
            const at = slotOf(c);
            const spec = specs[at];
            var made: Self = .{
                .spec = spec,
                .model = .{ .decoding = decode.selectionOf(spec.architecture), .costs = costs[at] },
                .state = .{ .secure = spec.security, .fpscr = fp.fixedFields(spec.architecture, 0) },
                .memory = memory,
                .systick = .{ .calibration = SysTick.noref | (part.calibration & SysTick.calibrated) },
                .systick_ns = if (SysTickNs == void) {} else if (spec.security and (spec.architecture.main() or part.systick_ns)) .{ .calibration = SysTick.noref | (part.calibration_ns & SysTick.calibrated) } else null,
                .scb = .init(&profiles[at], part, part.vtor),
                .scb_ns = .init(&profiles[at], part, part.vtor_ns),
                .icb = .{},
                .nvic = .init(part.priority_bits.?, part.interrupts.?),
                .dwt = .init(spec.architecture.main()),
                .sau = .init(spec.security, spec.architecture.main(), part.sau_regions.?),
                .m7 = if (M7 == void) {} else .init(part),
                .impdef = if (Impdef == void) {} else .init(c, part),
                .ewic = if (Ewic == void) {} else .init(if (c == .m55 or c == .m85) part.ewic else 0),
                .mpu = .init(part.mpu_regions.?, spec.architecture.v8(), spec.architecture == .armv8_1m_main),
                .mpu_ns = if (MpuNs == void) {} else .init(part.mpu_ns_regions.?, spec.architecture.v8(), spec.architecture == .armv8_1m_main),
                .banked = .{},
                .itns = 0,
                .flags = .{},
                .active = 0,
                .pending = 0,
                .due = 0,
                .cycles = 0,
                .exceptions = 0,
                .irqs = 0,
                .latency = 0,
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
                .override = null,
                .derived = null,
                .protection = false,
                .unguarded = true,
                .guarding = 0,
                .forced_unpriv = false,
                .taken = null,
                .vector = .{},
            };
            made.reguard();
            made.atReset();
            return made;
        }

        /// What the cycle table charges an instruction class.
        pub fn costOf(self: *const Self, class: Class) Cost {
            return self.model.costOf(class);
        }

        const gate: ?decode.Groups = if (options.cores.len == 1) decode.selectionOf(specs[0].architecture).groups else null;

        /// The decode groups this core runs, which the disassembler is rendered against.
        pub fn groups(self: *const Self) decode.Groups {
            return self.model.decoding.groups;
        }

        /// The architecture this core is, which isa asks to decide unaligned accesses and MSR writes.
        pub fn architecture(self: *const Self) Architecture {
            return self.model.decoding.architecture;
        }

        /// Whether the Security Extension is fitted.
        pub fn security(self: *const Self) bool {
            return self.spec.security;
        }

        /// How many priority bits the core implements.
        pub fn priorityBits(self: *const Self) u4 {
            return @intCast(@popCount(self.nvic.lanes & 0xff));
        }

        /// Whether the floating-point unit is double precision.
        pub fn doublePrecision(self: *const Self) bool {
            return self.spec.double_precision;
        }

        /// Whether it handles half-precision arithmetic.
        pub fn halfPrecision(self: *const Self) bool {
            return self.spec.half_precision;
        }

        /// Whether it is an FPv5 unit rather than FPv4.
        pub fn fpv5(self: *const Self) bool {
            return self.spec.fpv5;
        }

        /// Whether pointer authentication and branch target identification are fitted.
        pub fn pacbti(self: *const Self) bool {
            return self.spec.pacbti;
        }

        /// Whether the M-profile Vector Extension is fitted.
        pub fn mve(self: *const Self) bool {
            return self.spec.mve;
        }

        /// Returns a running core to its reset state, which is also what SYSRESETREQ does.
        pub fn reset(self: *Self) void {
            const before = self.impdef;
            self.* = build(self.memory, self.spec.core, self.built(), self.trace);
            if (Impdef != void) self.impdef.keep(&before);
        }

        fn built(self: *const Self) core.Part {
            var out: core.Part = .{
                .data = self.scb.data,
                .instruction = self.scb.instruction,
                .mpu_regions = self.mpu.count,
                .mpu_ns_regions = if (MpuNs == void) 0 else self.mpu_ns.count,
                .sau_regions = self.sau.count,
                .priority_bits = self.priorityBits(),
                .interrupts = self.nvic.count,
                .revidr = self.scb.revision,
                .vtor = self.scb.table,
                .vtor_ns = self.scb_ns.table,
                .calibration = self.systick.calibration & SysTick.calibrated,
            };
            if (M7 != void) self.m7.wiring(&out);
            if (Impdef != void) {
                if (self.spec.core == .m55 or self.spec.core == .m85) self.impdef.wiring(&out);
                out.ewic = self.ewic.events;
            }
            if (SysTickNs != void) {
                if (self.systick_ns) |timer| {
                    out.systick_ns = true;
                    out.calibration_ns = timer.calibration & SysTick.calibrated;
                }
            }
            return out;
        }

        fn atReset(self: *Self) void {
            const table = self.scb.get(scb_block.vtor);
            const sp = self.load(4, table) orelse return self.lockAtReset(table);
            const entry = self.load(4, table +% 4) orelse return self.lockAtReset(table +% 4);
            self.state.msp = sp & ~@as(u32, 3);
            self.state.lr = 0xffff_ffff;
            self.state.branchTo(entry);
            if (self.trace.recording()) self.last = trace.snapshot(&self.state);
        }

        fn restart(self: *Self) void {
            const instructions = self.instructions;
            const cycles = self.cycles;
            const ring = self.trace;
            const count = self.exceptions;
            const irqs = self.irqs;
            const latency = self.latency;
            self.reset();
            self.instructions = instructions;
            self.cycles = cycles;
            self.serviced = cycles;
            self.trace = ring;
            self.exceptions = count;
            self.irqs = irqs;
            self.latency = latency;
        }

        fn lockAt(self: *Self, stop: Stop) Stop {
            self.state.lockup = true;
            self.stop = stop;
            self.pending |= stopped;
            self.due |= stopped_due;
            return stop;
        }

        fn record(self: *Self, pc: u32, code: ?u32, why: trace.Note) void {
            if (!self.trace.recording()) return;
            self.trace.reserve().write(pc, code, &self.last, &self.state, self.touched, self.cycles, why);
        }

        /// Which unit a stop blames, for the record that refused access is written into.
        pub fn refusalOf(stop: ?Stop) trace.Note.Refusal {
            return switch (stop orelse return .none) {
                .fetch_fault, .data_fault => .no_memory,
                .fetch_violation, .data_violation => .protection,
                .secure_fault => .secure,
                else => .none,
            };
        }

        fn lockAtReset(self: *Self, address: u32) void {
            _ = self.faultAt(address, .fetch_fault);
        }

        fn faultAt(self: *Self, pc: u32, stop: Stop) Stop {
            self.touched = if (stop == .data_fault or stop == .data_violation) self.last_access else pc;
            self.record(pc, null, .{ .refused = refusalOf(self.override orelse stop) });
            return self.lockAt(stop);
        }

        fn forget(self: *Self) void {
            self.touched = null;
        }

        fn agrees(self: *Self) void {
            if (self.due & other_due != 0) return;
            const next = self.best() orelse return;
            std.debug.assert(next.priority >= self.executionPriority());
        }

        /// Runs one instruction, or one exception entry or return when one is due, and reports it.
        pub fn step(self: *Self) Step {
            if (builtin.mode == .Debug) self.agrees();
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
                    self.redirected = r.branched;
                }
            }
            if (self.due & returned_due != 0) {
                self.finishReturn();
                self.redirected = true;
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
            if (self.stop == .breakpoint) {
                self.stop = null;
                self.state.pc +%= 2;
                if (self.state.inIt()) self.state.itAdvance();
            }
        }

        fn perform(self: *Self, model: arch_step.Model, comptime tracing: bool) arch_step.Result {
            self.restand();
            if (tracing) self.forget();
            const pc = self.state.pc;
            const r = @call(.always_inline, arch_step.step, .{ Self, gate, &self.state, self, model });
            if (tracing) {
                if (r.halt() == .data_fault or r.halt() == .data_violation or r.halt() == .unaligned_access) self.touched = self.last_access;
                self.record(pc, r.fetchedCode(), .{ .refused = refusalOf(self.override orelse r.halt()) });
            }
            if (r.executed) {
                self.instructions += 1;
                self.charge(r.cycles);
            }
            self.stop = if (r.halted) self.settle(r.stop) else null;
            return r;
        }

        fn advance(self: *Self, model: arch_step.Model, comptime tracing: bool) ?Stop {
            _ = @call(.always_inline, perform, .{ self, model, tracing });
            return self.stop;
        }

        noinline fn settle(self: *Self, stop: Stop) ?Stop {
            switch (stop) {
                .breakpoint, .unimplemented => return stop,
                else => {},
            }
            const kind = self.override orelse stop;
            self.override = null;
            defer self.flags.nocp_secure = false;
            self.scbOf(self.state.secure or self.flags.nocp_secure).fault(kind, self.last_access);
            return self.escalated(kind);
        }

        fn escalated(self: *Self, kind: Stop) ?Stop {
            if (self.executionPriority() <= -1) return self.lockAt(kind);
            if (self.configurable(kind)) |n| {
                self.remember(kind, n, self.last_access);
                self.raise(n);
                self.derived = n;
                return null;
            }
            const forced = self.instance(hard_fault);
            const start = self.vectorAt(forced) orelse 0;
            if (start & 1 == 0) return self.lockAt(kind);
            self.scbOf(!self.spec.security or forced < ns_base).hardFault(scb_block.forced);
            self.flags.escalated = true;
            self.remember(kind, forced, self.last_access);
            self.raise(forced);
            self.derived = forced;
            return null;
        }

        fn remember(self: *Self, kind: Stop, n: Index, address: u32) void {
            const last = self.trace.last();
            const entering_ = kind == .not_t32_state and last != null and last.?.pc == self.vector.target;
            self.taken = .{
                .kind = kind,
                .n = n,
                .at = if (entering_) self.vector.from else if (last) |r| r.pc else self.state.pc,
                .address = address,
                .code = if (entering_) null else if (last) |r| r.codeOf() else null,
                .vector = self.vector,
            };
        }

        fn entering(self: *Self, n: Index, vector: u32, start: u32, from: u32) void {
            self.vector = .{ .n = n, .at = vector, .target = start & ~@as(u32, 1), .from = from };
            self.exceptions += 1;
            self.irqs += @intFromBool(numberOf(n) >= first_interrupt);
        }

        fn stacked(self: *Self) ?Stop {
            const kind = self.override orelse Stop.data_fault;
            self.override = null;
            self.touched = self.last_access;
            self.record(self.state.pc, null, .{ .refused = refusalOf(kind) });
            self.scs().stacking(kind);
            return self.escalated(kind);
        }

        fn vectorAt(self: *Self, i: Index) ?u32 {
            const target = !self.spec.security or i < ns_base;
            const was = self.state.secure;
            const held = self.override;
            self.state.secure = target;
            self.reguard();
            defer {
                self.state.secure = was;
                self.override = held;
                self.reguard();
            }
            return self.readVector(self.scbOf(target).get(scb_block.vtor) +% 4 * @as(u32, numberOf(i)));
        }

        fn shiftsNonSecure(self: *Self) bool {
            return self.spec.security and self.scb.get(scb_block.aircr) & scb_block.pris != 0;
        }

        fn faultsNonSecure(self: *Self) bool {
            return self.spec.security and self.scb.get(scb_block.aircr) & scb_block.bfhfnmins != 0;
        }

        fn masks(self: *Self, secure: bool) State.Banked {
            if (!self.spec.security or secure == self.state.secure) return .{ .primask = self.state.primask, .basepri = self.state.basepri, .faultmask = self.state.faultmask };
            return .{ .primask = self.banked.primask, .basepri = self.banked.basepri, .faultmask = self.banked.faultmask };
        }

        fn instance(self: *Self, n: Index) Index {
            if (!self.spec.security) return n;
            return n + switch (n) {
                nmi, bus_fault => if (self.faultsNonSecure()) ns_base else 0,
                hard_fault => if (self.faultsNonSecure() and !self.state.secure) ns_base else 0,
                mem_manage, usage_fault, svcall, pendsv => if (self.state.secure) 0 else ns_base,
                systick => if (self.flags.sttns) ns_base else 0,
                else => 0,
            };
        }

        fn targetsSecure(self: *Self, n: Index) bool {
            if (!self.spec.security or n < first_interrupt) return true;
            return self.itns & @as(Lines, 1) << @intCast(n - first_interrupt) == 0;
        }

        fn readItns(self: *Self, word: u32, ns: bool) ?u32 {
            if (!self.spec.security) return null;
            return if (ns) 0 else nvic_block.wordOf(self.itns, word);
        }

        fn writeItns(self: *Self, word: u32, ns: bool, value: u32) bool {
            if (!self.spec.security) return false;
            if (!ns) self.itns = (self.itns & ~nvic_block.placed(Lines, 0xffff_ffff, word)) | nvic_block.placed(Lines, value, word);
            return true;
        }

        fn scbOf(self: *Self, secure: bool) *scb_block.Scb {
            if (!self.spec.security) return &self.scb;
            return if (secure) &self.scb else &self.scb_ns;
        }

        /// The MPU of a security state, or the only one where the core has no Security Extension.
        pub fn mpuOf(self: *Self, secure: bool) *Mpu {
            if (secure or !self.spec.security) return &self.mpu;
            return self.nonSecureMpu().?;
        }

        fn nonSecureMpu(self: *Self) ?*Mpu {
            return if (MpuNs == void) null else &self.mpu_ns;
        }

        fn impdefBlock(self: *Self) ?*Impdef {
            if (self.spec.core != .m55 and self.spec.core != .m85) return null;
            return &self.impdef;
        }

        fn impdefHidden(self: *Self, offset: u32) bool {
            if (!self.spec.security or self.state.secure) return false;
            return impdef_block.secureOnly(offset) or !self.faultsNonSecure();
        }

        fn readRas(self: *Self, offset: u32, ns: bool) ?u32 {
            if (Impdef == void) return null;
            const block = self.impdefBlock() orelse return null;
            const word = ras_block.readRegister(self.spec.core, block.wired.ecc, offset) orelse return null;
            return if (ns and ras_block.gated(offset) and !self.faultsNonSecure()) 0 else word;
        }

        fn ewicOpen(self: *Self) bool {
            return !self.spec.security or self.state.secure or self.faultsNonSecure();
        }

        fn writeImpdef(self: *Self, offset: u32, value: u32) bool {
            if (Impdef == void) return false;
            const block = self.impdefBlock() orelse return false;
            if (block.readRegister(offset) == null) return false;
            if (self.impdefHidden(offset)) return true;
            if (offset == impdef_block.eventspr) {
                if (value & impdef_block.event != 0) self.event();
                if (value & impdef_block.nmi != 0) self.raise(self.instance(nmi));
            }
            return block.writeRegister(offset, value);
        }

        fn m7Control(self: *Self) ?*m7_block.Control {
            return if (M7 == void) null else if (self.spec.core == .m7) &self.m7 else null;
        }

        fn scs(self: *Self) *scb_block.Scb {
            return self.scbOf(self.state.secure);
        }

        fn configurable(self: *Self, stop: Stop) ?Index {
            if (!self.architecture().main()) return null;
            const n: Index, const enable: u32 = switch (stop) {
                .fetch_fault, .data_fault => .{ bus_fault, scb_block.busfaultena },
                .fetch_violation, .data_violation => .{ mem_manage, scb_block.memfaultena },
                .secure_fault => .{ secure_fault, scb_block.secureflt_ena },
                .undefined_instruction, .not_t32_state, .unaligned_access, .divide_by_zero, .no_coprocessor, .authentication_failure, .not_branch_target, .tail_predication, .exception_return => .{ usage_fault, scb_block.usgfaultena },
                else => return null,
            };
            const i = if (self.flags.nocp_secure) n else self.instance(n);
            if (self.scbOf(!self.spec.security or i < ns_base).get(scb_block.shcsr) & enable == 0) return null;
            if (self.priority(i) >= self.executionPriority()) return null;
            return i;
        }

        noinline fn raise(self: *Self, n: Index) void {
            self.pending |= one(n);
            self.due |= if (n < 2) @as(u32, 1) << @intCast(n) else other_due;
            self.pended();
            if (self.due & asleep_due != 0 and self.woken()) self.due &= ~asleep_due;
        }

        fn pended(self: *Self) void {
            if (self.scs().get(scb_block.scr) & scb_block.sevonpend != 0) self.flags.event = true;
        }

        fn escalateHardFault(self: *Self) void {
            const forced = self.instance(hard_fault);
            self.scbOf(!self.spec.security or forced < ns_base).hardFault(scb_block.forced);
            self.flags.escalated = true;
            self.raise(forced);
        }

        /// Recomputes the due word from the pending set, keeping the bits no exception decides.
        pub fn rearm(self: *Self) void {
            self.due = (self.due & kept_due) | summary(self.pending);
        }

        /// Takes what the instruction set signalled: an SVC, an exception return, or a return from a call.
        pub fn signal(self: *Self, what: arch_step.Signal) void {
            switch (what) {
                .supervisor_call => {
                    const call = self.instance(svcall);
                    if (self.priority(call) < self.executionPriority()) self.raise(call) else self.escalateHardFault();
                },
                .exception_return => {
                    self.pending |= returned;
                    self.due |= returned_due;
                },
                .function_return => self.finishCall(),
            }
        }

        noinline fn attend(self: *Self) bool {
            self.restand();
            if (self.due & stopped_due != 0) return true;
            if (self.due & reset_due != 0) {
                self.restart();
                return true;
            }
            if (self.due & asleep_due != 0) self.stall();
            var handled = false;
            if (self.due & returned_due != 0) {
                self.finishReturn();
                if (self.stop != null or self.due & bound_due != 0) return true;
                handled = true;
            }
            if (self.takePending()) return true;
            self.due = (self.due & kept_due) | summary(self.pending & (stopped | returned));
            return handled;
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

        noinline fn finishCall(self: *Self) void {
            if (!self.spec.security) return;
            const s = &self.state;
            s.secure = true;
            self.bank();
            const stack: *u32 = if (!s.handler() and s.control & State.control_spsel != 0) &s.psp else &s.msp;
            const frame = stack.*;
            const start = self.load(4, frame) orelse return self.forceHardFault();
            const partial = self.load(4, frame +% 4) orelse return self.forceHardFault();
            const number = partial & State.ipsr_mask;
            if (s.xpsr & State.ipsr_mask > 1 or s.handler() != (number != 0)) return self.forceHardFault();
            stack.* = frame +% 8;
            s.xpsr = (s.xpsr & ~(State.ipsr_mask | State.it_mask)) | number;
            s.control = (s.control & ~State.control_sfpa) | (partial >> 20 & 1) << 3;
            s.branchTo(start);
            self.forget();
            self.record(s.pc, null, .{ .kind = .exit, .latency = self.spec.exit });
            self.delay(self.spec.exit);
        }

        fn forceHardFault(self: *Self) void {
            self.escalateHardFault();
            self.rearm();
        }

        noinline fn finishReturn(self: *Self) void {
            self.pending &= ~returned;
            self.stop = self.leave(self.state.pc);
            self.delay(self.spec.exit);
            const held = self.memory.asserted();
            if (held != 0) self.pending |= @as(Set, held) << first_interrupt;
            self.rearm();
            if (self.stop == null and self.sleepsOnExit()) self.sleep(.interrupt);
        }

        fn sleepsOnExit(self: *Self) bool {
            return !self.state.handler() and self.active == 0 and self.scs().get(scb_block.scr) & scb_block.sleeponexit != 0;
        }

        fn delay(self: *Self, cycles: u32) void {
            self.latency += cycles;
            self.charge(cycles);
        }

        /// Adds cycles to the core's count, servicing SysTick and the bus once it passes the attention point.
        pub fn charge(self: *Self, cycles: u32) void {
            self.cycles += cycles;
            if (self.cycles >= self.attention) self.service();
        }

        noinline fn service(self: *Self) void {
            const elapsed: u32 = @intCast(@min(self.cycles - self.serviced, std.math.maxInt(u32)));
            self.serviced = self.cycles;
            if (self.systick.advance(elapsed)) self.raise(if (self.spec.security and self.flags.sttns) systick + ns_base else systick);
            if (self.timerNs()) |timer| {
                if (timer.advance(elapsed)) self.raise(systick + ns_base);
            }
            if (self.memory.interrupts()) |raised| self.pendAll(raised);
            self.schedule();
            if (self.cycles >= self.deadline) self.due |= bound_due;
        }

        fn schedule(self: *Self) void {
            self.memory.follow(&self.cycles, &self.attention);
            const other = if (self.timerNs()) |timer| timer.deadline() else std.math.maxInt(u64);
            const next = self.serviced +| @min(self.systick.deadline(), other, self.memory.untilDue());
            self.attention = if (self.cycles < self.deadline) @min(next, self.deadline) else next;
        }

        /// Raises one interrupt line.
        pub fn pend(self: *Self, line: nvic_block.Line) void {
            if (line >= lines) return;
            self.pendAll(@as(Lines, 1) << @intCast(line));
        }

        /// Raises a whole set of lines, waking a sleeping core if one of them can be taken.
        pub fn pendAll(self: *Self, raised: Lines) void {
            self.pending |= @as(Set, raised & self.nvic.present()) << first_interrupt;
            if (Ewic != void and self.ewic.enabled) {
                for (0..ewic_block.banks) |n| self.ewic.latch(@intCast(n), nvic_block.wordOf(raised & self.nvic.present(), @intCast(n)));
            }
            self.pended();
            self.due = (self.due & kept_due) | summary(self.pending);
            if (self.due & asleep_due != 0 and self.woken()) self.due &= ~asleep_due;
        }

        /// Takes a WFI or WFE, unless an exception is already asking or an event is standing.
        pub fn sleep(self: *Self, wait: arch_step.Wait) void {
            if (wait == .event and self.flags.event) {
                self.flags.event = false;
                return;
            }
            if (self.best() != null) return;
            self.flags.for_event = wait == .event;
            self.due |= asleep_due;
        }

        /// Sets the event register, which is what SEV does.
        pub fn event(self: *Self) void {
            self.flags.event = true;
        }

        fn woken(self: *Self) bool {
            if (self.best() != null) return true;
            return self.flags.for_event and self.scs().get(scb_block.scr) & scb_block.sevonpend != 0;
        }

        /// Whether the NVIC enable bit for a line is set.
        pub fn enabled(self: *const Self, line: nvic_block.Line) bool {
            if (line >= lines) return false;
            return self.nvic.enabled & @as(Lines, 1) << @intCast(line) != 0;
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
            if (limit.instructions == 0) return .{ .instructions = 0, .cycles = 0, .latency = 0, .stop = null, .ended = .budget };
            const model = self.model;
            const instructions = self.instructions;
            const cycles = self.cycles;
            const latency = self.latency;
            var stop: ?Stop = null;
            const ends = bound_due | if (limit.asleep) asleep_due else 0;
            if (self.due & bound_due != 0) return .{ .instructions = 0, .cycles = 0, .latency = 0, .stop = null, .ended = .deadline };
            self.leaveBreakpoint();
            outer: while (self.instructions - instructions < limit.instructions) {
                if (builtin.mode == .Debug) self.agrees();
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
                    if (builtin.mode == .Debug) self.agrees();
                    if (self.due != 0) continue :outer;
                    stop = @call(.always_inline, advance, .{ self, model, tracing });
                    if (stop != null) break :outer;
                }
            }
            if (self.due & returned_due != 0) {
                self.finishReturn();
                stop = self.stop;
            }
            return .{
                .instructions = self.instructions - instructions,
                .cycles = self.cycles - cycles,
                .latency = self.latency - latency,
                .stop = stop,
                .ended = if (stop != null) .stopped else if (self.due & ends & asleep_due != 0) .asleep else if (self.cycles >= self.deadline) .deadline else .budget,
            };
        }

        /// Prints the stop, the last records, the fault, the status registers and any unreachable interrupt.
        pub fn explain(self: *const Self, w: *std.Io.Writer, recap: u64) !void {
            if (self.stop) |stop| try trace.explain(w, stop, &self.trace, recap, self.groups());
            if (self.taken) |t| try self.blame(w, t);
            try self.status(w);
            try self.unreachable_(w);
        }

        fn blame(self: *const Self, w: *std.Io.Writer, t: Taken) !void {
            try w.print("The core took a {s} at pc={x:0>8} as {s}", .{
                className(t.kind), t.at, nameOf(t.n),
            });
            if (t.n >= first_interrupt) try w.print(" {d}", .{numberOf(t.n) - first_interrupt});
            try w.writeAll(": ");
            switch (t.kind) {
                .unaligned_access => try w.print("the access to {x:0>8} is not aligned to its size and CCR.UNALIGN_TRP is set", .{t.address}),
                .undefined_instruction => try w.print("the code {x:0>4} is not an instruction of this architecture", .{t.code orelse 0}),
                .data_violation, .fetch_violation => try w.print("the Memory Protection Unit does not let this code reach {x:0>8}", .{t.address}),
                .data_fault, .fetch_fault => try w.print("no memory answered the access to {x:0>8}", .{t.address}),
                .secure_fault => try w.print("the Security Attribution Unit marks {x:0>8} Secure", .{t.address}),
                .not_t32_state => try w.print("the {s} vector at VTOR+{x} = {x:0>8} holds an even address, so the entry from pc={x:0>8} left T32 state", .{
                    nameOf(t.vector.n), t.vector.at -% self.scb.get(scb_block.vtor), t.vector.at, t.vector.from,
                }),
                .exception_return => try w.print("the handler returned with EXC_RETURN {x:0>8}, which matches no active exception or frame", .{t.address}),
                .divide_by_zero => try w.writeAll("the code divided by zero with CCR.DIV_0_TRP set"),
                .no_coprocessor => try w.writeAll("CPACR leaves the coprocessor the code named disabled"),
                else => try w.writeAll(@tagName(t.kind)),
            }
            try w.writeAll(".\n");
        }

        fn className(kind: Stop) []const u8 {
            return switch (kind) {
                .fetch_fault, .data_fault => "BusFault",
                .fetch_violation, .data_violation => "MemManage",
                .secure_fault => "SecureFault",
                else => "UsageFault",
            };
        }

        fn status(self: *const Self, w: *std.Io.Writer) !void {
            const cfsr = self.scb.get(scb_block.cfsr);
            const hfsr = self.scb.get(scb_block.hfsr);
            if (cfsr == 0 and hfsr == 0) return;
            try w.print("CFSR={x:0>8}", .{cfsr});
            var lead: []const u8 = " (";
            for (scb_block.recorded) |flag| {
                if (cfsr & flag.bit == 0) continue;
                try w.print("{s}{s}", .{ lead, flag.name });
                lead = " ";
            }
            if (lead[0] == ' ' and lead.len == 1) try w.writeAll(")");
            try w.print(" HFSR={x:0>8} MMFAR={x:0>8} BFAR={x:0>8}\n", .{
                hfsr, self.scb.get(scb_block.mmfar), self.scb.get(scb_block.bfar),
            });
        }

        fn unreachable_(self: *const Self, w: *std.Io.Writer) !void {
            var waiting = @as(Lines, @truncate(self.pending >> first_interrupt)) & ~self.nvic.enabled;
            while (waiting != 0) : (waiting &= waiting - 1) {
                const line: nvic_block.Line = @intCast(@ctz(waiting));
                try w.print("IRQ {d} is pending in NVIC_ISPR{d}={x:0>8} and its bit in NVIC_ISER{d}={x:0>8} was never written, so the core will not take it.\n", .{
                    line,                                              line / 32,
                    nvic_block.wordOf(self.pendingLines(), line / 32), line / 32,
                    nvic_block.wordOf(self.nvic.enabled, line / 32),
                });
            }
        }

        fn pendingLines(self: *const Self) Lines {
            return @truncate(self.pending >> first_interrupt);
        }

        fn alignsStack(self: *Self) bool {
            return self.scs().get(scb_block.ccr) & scb_block.stkalign != 0;
        }

        /// Whether CCR.UNALIGN_TRP makes an unaligned access fault.
        pub fn trapsUnaligned(self: *Self) bool {
            return self.architecture().main() and self.scs().get(scb_block.ccr) & scb_block.unalign_trp != 0;
        }

        /// Whether CCR.DIV_0_TRP makes a divide by zero fault.
        pub fn trapsDivideByZero(self: *Self) bool {
            return self.architecture().main() and self.scs().get(scb_block.ccr) & scb_block.div_0_trp != 0;
        }

        /// The FPDSCR a new floating-point context starts from.
        pub fn defaultFpscr(self: *Self) u32 {
            return self.scs().get(scb_block.fpdscr);
        }

        /// The Non-secure bank's FPDSCR, which a Secure handler restores a Non-secure context with.
        pub fn nonSecureFpscr(self: *Self) u32 {
            return self.scbOf(false).get(scb_block.fpdscr);
        }

        /// Whether FPCCR.ASPEN saves the floating-point context on exception entry.
        pub fn automaticFpState(self: *Self) bool {
            return self.scs().get(scb_block.fpccr) & scb_block.aspen != 0;
        }

        fn lazyBlock(self: *Self) *scb_block.Scb {
            if (!self.spec.security) return &self.scb;
            return self.scbOf(self.scb.get(scb_block.fpccr) & scb_block.fp_secure != 0);
        }

        /// The address of a reserved but unfilled lazy floating-point frame, if one stands.
        pub fn lazyFpFrame(self: *Self) ?u32 {
            const owner = self.lazyBlock();
            if (owner.get(scb_block.fpccr) & scb_block.lspact == 0) return null;
            return owner.get(scb_block.fpcar);
        }

        /// Whether that frame also holds the callee-saved registers, which the Secure bank decides.
        pub fn lazyFpCallee(self: *Self) bool {
            const owner = self.scbOf(true).get(scb_block.fpccr);
            return owner & scb_block.fp_secure != 0 and owner & scb_block.treat_as_secure != 0;
        }

        /// Whether the core has a floating-point register file at all.
        pub fn floatingPoint(self: *const Self) bool {
            return self.spec.floating_point or self.spec.mve;
        }

        /// Whether FPCCR.TS makes the floating-point registers Secure state.
        pub fn treatAsSecure(self: *Self) bool {
            return self.spec.security and self.scbOf(true).get(scb_block.fpccr) & scb_block.treat_as_secure != 0;
        }

        /// Whether FPCCR.LSPEN, one bit for both Security states, makes the saving lazy rather than eager.
        pub fn lazyFpEnabled(self: *Self) bool {
            return self.scb.get(scb_block.fpccr) & scb_block.lspen != 0;
        }

        /// Reserves a lazy frame at an address and records what could fault then, or clears LSPACT.
        pub fn setLazyFp(self: *Self, frame: ?u32) void {
            const address = frame orelse {
                const owner = self.lazyBlock();
                owner.put(scb_block.fpccr, owner.get(scb_block.fpccr) & ~scb_block.lspact);
                return;
            };
            const owner = self.scs();
            const recorded = scb_block.fp_user | scb_block.fp_thread | scb_block.ufrdy | scb_block.sfrdy | scb_block.bfrdy | scb_block.mmrdy | scb_block.hfrdy;
            const unbanked: u32 = if (self.spec.security) scb_block.sfrdy | scb_block.bfrdy | scb_block.hfrdy else 0;
            const ready = self.readiness();
            var value = (owner.get(scb_block.fpccr) & ~recorded) | scb_block.lspact | (ready & ~unbanked);
            if (!self.state.handler()) {
                value |= scb_block.fp_thread;
                if (self.state.control & State.control_npriv != 0) value |= scb_block.fp_user;
            }
            owner.put(scb_block.fpcar, address & ~@as(u32, 7));
            owner.put(scb_block.fpccr, value);
            if (self.spec.security) {
                const top = self.scb.get(scb_block.fpccr) & ~(scb_block.fp_secure | unbanked);
                self.scb.put(scb_block.fpccr, top | (ready & unbanked) | (if (self.state.secure) scb_block.fp_secure else 0));
            }
        }

        fn readiness(self: *Self) u32 {
            var value: u32 = 0;
            if (self.executionPriority() > -1) value |= scb_block.hfrdy;
            if (self.configurable(.data_violation) != null) value |= scb_block.mmrdy;
            if (self.configurable(.data_fault) != null) value |= scb_block.bfrdy;
            if (self.configurable(.undefined_instruction) != null) value |= scb_block.ufrdy;
            if (self.spec.security and self.configurable(.secure_fault) != null) value |= scb_block.sfrdy;
            return value;
        }

        /// Marks the next stop as a tail predication fault, which only MVE raises.
        pub fn invalidState(self: *Self) void {
            self.override = .tail_predication;
        }

        /// Makes the next accesses unprivileged, which the unprivileged loads and stores need.
        pub fn forceUnprivileged(self: *Self, on: bool) void {
            self.forced_unpriv = on;
            self.restand();
        }

        /// Whether CPACR, NSACR for Non-secure code, and CPPWR.SU10 let this code reach the floating-point coprocessor; a refusal by NSACR, or by SU10 under SUS10, marks the NOCP UsageFault for the Secure state, v8-M RDXYK and IsCPEnabled.
        pub fn coprocessorEnabled(self: *Self) bool {
            if (!self.architecture().main() or self.scs().get(scb_block.cpacr) & scb_block.cp10 == 0) return false;
            return !self.spec.security or self.securityPermits();
        }

        fn securityPermits(self: *Self) bool {
            if (!self.state.secure and self.scb.get(scb_block.nsacr) & scb_block.nsacr_cp10 == 0) {
                self.flags.nocp_secure = true;
                return false;
            }
            if (self.icb.cppwr & icb_block.su10 == 0) return true;
            self.flags.nocp_secure = self.icb.cppwr & icb_block.sus10 != 0;
            return false;
        }

        inline fn permits(self: *Self, address: u32, comptime wanted: contract.Kind) ?contract.Failure {
            if (builtin.mode == .Debug) std.debug.assert(self.unguarded == self.guardless());
            if (self.unguarded) return null;
            return @call(.never_inline, refused, .{ self, address, wanted });
        }

        fn refused(self: *Self, address: u32, comptime wanted: contract.Kind) ?contract.Failure {
            const fetch = wanted == .fetch;
            if (self.spec.security and !self.state.secure) {
                const found = self.sau.check(address, fetch, false);
                if (!found.ns and !(fetch and found.nsc and self.gated(address))) {
                    self.sau.violation(address, fetch);
                    self.last_access = address;
                    return error.Secure;
                }
            }
            if (self.guards(address, self.state.secure)) |unit| {
                if (!unit.permits(address, self.state.privileged() and !self.forced_unpriv, wanted)) {
                    self.last_access = address;
                    return error.Violation;
                }
            }
            return null;
        }

        /// Remembers which unit refused an access, so the fault the core takes can name it.
        pub fn blamed(self: *Self, comptime a: contract.Access, err: contract.Failure) void {
            self.override = switch (err) {
                error.Violation => if (a.kind == .fetch) .fetch_violation else .data_violation,
                error.Secure => .secure_fault,
                error.DataFault => return,
            };
        }

        fn gated(self: *Self, address: u32) bool {
            const half = self.memory.parcel(address);
            return half == sg_half;
        }

        const negative_priority: Set = (1 << 1) | (1 << nmi) | (1 << hard_fault) |
            (1 << (ns_base + 1)) | (1 << (ns_base + nmi)) | (1 << (ns_base + hard_fault));

        fn mayRunNegative(self: *const Self) bool {
            return self.state.faultmask or self.banked.faultmask or self.active & negative_priority != 0;
        }

        fn guards(self: *Self, address: u32, secure: bool) ?*Mpu {
            const unit = self.mpuOf(secure);
            if (!unit.enabled() or ppb.region(address) != .memory) return null;
            if (unit.control & mpu_block.hfnmiena == 0 and self.mayRunNegative() and self.executionPriority() < 0) return null;
            return unit;
        }

        /// What the MPU lets that privilege and state do at an address, which is what TT answers from.
        pub fn accessible(self: *Self, address: u32, privileged: bool, secure: bool) mpu_block.Reach {
            const unit = self.guards(address, secure) orelse return .{ .read = true, .write = true };
            return .{
                .read = unit.permits(address, privileged, .read),
                .write = unit.permits(address, privileged, .write),
            };
        }

        /// Recomputes the guard word and unfolds the cache when anything deciding a refusal changed.
        pub noinline fn reguard(self: *Self) void {
            const was = self.protection;
            const stood = self.guarding;
            self.protection = self.mpu.enabled() or (if (self.nonSecureMpu()) |unit| unit.enabled() else false);
            self.unguarded = self.guardless();
            self.guarding = self.regard();
            if (was != self.protection or stood != self.guarding or self.spec.security) self.memory.folded.unfold();
        }

        const guard_privileged: u32 = 1 << 0;
        const guard_negative: u32 = 1 << 1;

        fn regard(self: *Self) u32 {
            return @as(u32, @intFromBool(self.state.privileged() and !self.forced_unpriv)) |
                @as(u32, @intFromBool(self.mayRunNegative())) << 1;
        }

        fn restand(self: *Self) void {
            if (self.protection and self.guarding != self.regard()) self.reguard();
        }

        fn guardless(self: *Self) bool {
            return !self.protection and (!self.spec.security or self.state.secure);
        }

        /// Swaps the banked registers between the two security states.
        pub fn bank(self: *Self) void {
            defer self.reguard();
            if (!self.spec.security) return;
            const s = &self.state;
            const held: State.Banked = .{ .msp = s.msp, .psp = s.psp, .control = s.control, .primask = s.primask, .basepri = s.basepri, .faultmask = s.faultmask, .pac_key = s.pac_key, .msplim = s.msplim, .psplim = s.psplim };
            s.msp = self.banked.msp;
            s.psp = self.banked.psp;
            s.control = self.banked.control;
            s.primask = self.banked.primask;
            s.basepri = self.banked.basepri;
            s.faultmask = self.banked.faultmask;
            s.pac_key = self.banked.pac_key;
            s.msplim = self.banked.msplim;
            s.psplim = self.banked.psplim;
            self.banked = held;
        }

        /// The other bank, which the Non-secure register accesses of a Secure handler reach.
        pub fn alternate(self: *Self) *State.Banked {
            return &self.banked;
        }

        /// What the SAU says about an address from the current security state.
        pub fn attribute(self: *Self, address: u32, fetch: bool) sau_block.Attribution {
            return self.sau.check(address, fetch, self.state.secure);
        }

        /// The address a run of accesses began at, recorded only while the ring is recording.
        pub fn touch(self: *Self, address: u32) void {
            if (self.trace.recording()) self.noted(address);
        }

        noinline fn noted(self: *Self, address: u32) void {
            self.last_access = address;
            if (self.touched == null) self.touched = address;
        }

        noinline fn unanswered(self: *Self, address: u32) bool {
            self.last_access = address;
            return self.ignoring(address);
        }

        /// The bytes an access may use directly, from the folded lane, refolding out of line if it must.
        pub fn span(self: *Self, at: u32, comptime a: contract.Access) []u8 {
            const kind = comptime folding(a.kind);
            const bytes = self.memory.folded.reach(at, a.bytes, kind, self, describe);
            if (builtin.mode == .Debug and bytes.len != 0) self.verify(at, kind);
            return bytes;
        }

        fn folding(comptime kind: contract.Kind) contract.Kind {
            return switch (kind) {
                .fetch => .fetch,
                .read, .vector => .read,
                .write => .write,
            };
        }

        fn describe(self: *Self, address: u32, kind: contract.Kind) regions.Block {
            const found = self.memory.lookup(address);
            var low: u64 = found.base;
            var high: u64 = @as(u64, found.base) + found.len;
            var backed = found.host != null and (kind != .write or found.writable);
            regions.narrow(address, &low, &high, ppb.ppb_start);
            regions.narrow(address, &low, &high, ppb.ppb_end);
            if (ppb.region(address) != .memory) backed = false;
            if (kind == .fetch) {
                inline for (.{ 0x4000_0000, 0x6000_0000, 0xa000_0000 }) |edge| regions.narrow(address, &low, &high, edge);
                if (!fetchable(address)) backed = false;
            }
            if (backed) backed = self.guarded(address, &low, &high, kind);
            return .{
                .base = @intCast(low),
                .len = high - low,
                .host = if (backed) found.host.? + (low - found.base) else null,
            };
        }

        fn guarded(self: *Self, address: u32, low: *u64, high: *u64, kind: contract.Kind) bool {
            if (self.spec.security and !self.state.secure) return false;
            const unit = self.mpuOf(self.state.secure);
            if (!unit.enabled()) return true;
            if (unit.v8) return false;
            if (self.guarding & guard_negative != 0 and unit.control & mpu_block.hfnmiena == 0) return false;
            bound(unit, address, low, high);
            return unit.permits(address, self.guarding & guard_privileged != 0, kind);
        }

        fn bound(unit: *const Mpu, address: u32, low: *u64, high: *u64) void {
            for (0..unit.count) |i| {
                const attributes = unit.limit[i];
                if (attributes & mpu_block.region_enable == 0) continue;
                const power: u5 = @intCast((attributes >> mpu_block.size_shift) & 0x1f);
                if (power < 4) continue;
                const size = @as(u64, 1) << (@as(u6, power) + 1);
                const first = @as(u64, unit.base[i] & ~@as(u32, @truncate(size - 1)));
                regions.narrow(address, low, high, first);
                regions.narrow(address, low, high, first + size);
                if (power < 7 or (attributes >> mpu_block.srd_shift) & 0xff == 0) continue;
                var at = first + (size >> 3);
                while (at < first + size) : (at += size >> 3) regions.narrow(address, low, high, at);
            }
        }

        fn fetchable(address: u32) bool {
            const top = address >> 29;
            return top != 0b010 and top < 0b101;
        }

        fn verify(self: *Self, address: u32, comptime kind: contract.Kind) void {
            const block = self.describe(address, kind);
            const host = block.host orelse unreachable;
            const cached = self.memory.folded.span(address, 1, kind);
            std.debug.assert(host + (address - block.base) == cached.ptr);
            std.debug.assert(self.permits(address, kind) == null);
            std.debug.assert(ppb.region(address) == .memory);
        }

        /// The slow lane: the protection units, the private peripheral bus, and whatever no span answered.
        pub fn access(self: *Self, at: u32, comptime a: contract.Access, value: u32) contract.Failure!u32 {
            if (a.kind == .fetch) {
                if (!fetchable(at)) return error.Violation;
                if (self.permits(at, .fetch)) |err| return err;
                return self.memory.parcel(at) orelse error.DataFault;
            }
            if (self.permits(at, a.kind)) |err| return err;
            const T = contract.Word(a.bytes);
            const peripheral = ppb.region(at) != .memory;
            if (a.kind == .write) {
                const word: T = @truncate(value);
                const done = if (peripheral)
                    (if (a.bytes == 4) self.writePpb(at, word) else self.writeLane(T, at, word))
                else
                    self.memory.poke(a.bytes, at, word);
                if (done != null) return 0;
                return if (self.unanswered(at)) 0 else error.DataFault;
            }
            const got: ?T = if (peripheral)
                (if (a.bytes == 4) self.wordPpb(at) else self.readLane(T, at))
            else
                self.memory.peek(a.bytes, at);
            if (got) |word| return word;
            if (a.kind == .vector) return error.DataFault;
            return if (self.unanswered(at)) 0 else error.DataFault;
        }

        /// One halfword of code, without letting the lookup blame a unit for a later fault.
        pub fn parcel(self: *Self, address: u32) ?u16 {
            const held = self.override;
            defer self.override = held;
            return contract.read(Self, self, address, .{ .kind = .fetch, .bytes = 2 });
        }

        /// Reads one, two or four bytes the way the core would, without raising a fault.
        pub fn peek(self: *Self, comptime bytes: u8, address: u32) ?contract.Word(bytes) {
            const held = self.override;
            defer self.override = held;
            const sfsr = self.sau.status;
            const sfar = self.sau.address;
            return self.load(bytes, address) orelse {
                self.sau.status = sfsr;
                self.sau.address = sfar;
                return null;
            };
        }

        fn load(self: *Self, comptime bytes: u8, address: u32) ?contract.Word(bytes) {
            return contract.read(Self, self, address, .{ .kind = .read, .bytes = bytes });
        }

        fn readVector(self: *Self, address: u32) ?u32 {
            return contract.read(Self, self, address, .{ .kind = .vector, .bytes = 4 });
        }

        noinline fn ignoring(self: *Self, address: u32) bool {
            if (self.scb.get(scb_block.ccr) & scb_block.bfhfnmign == 0) return false;
            if (self.executionPriority() > -1) return false;
            self.scs().fault(.data_fault, address);
            return true;
        }

        /// Writes one, two or four bytes the way the core would, without raising a fault.
        pub fn poke(self: *Self, comptime bytes: u8, address: u32, value: contract.Word(bytes)) ?void {
            const held = self.override;
            defer self.override = held;
            const sfsr = self.sau.status;
            const sfar = self.sau.address;
            return self.store(bytes, address, value) orelse {
                self.sau.status = sfsr;
                self.sau.address = sfar;
                return null;
            };
        }

        fn store(self: *Self, comptime bytes: u8, address: u32, value: contract.Word(bytes)) ?void {
            return contract.write(Self, self, address, .{ .kind = .write, .bytes = bytes }, value);
        }

        fn readLane(self: *Self, comptime T: type, address: u32) ?T {
            if (!self.architecture().main() or address % @sizeOf(T) != 0 or lanes(address) == null) return null;
            const word = self.wordPpb(address & ~@as(u32, 3)) orelse return null;
            return @truncate(word >> @intCast((address & 3) * 8));
        }

        fn writeLane(self: *Self, comptime T: type, address: u32, value: T) ?void {
            if (!self.architecture().main() or address % @sizeOf(T) != 0) return null;
            const kind = lanes(address) orelse return null;
            const aligned = address & ~@as(u32, 3);
            const shift: u5 = @intCast((address & 3) * 8);
            const raised = @as(u32, value) << shift;
            if (kind == .cleared) return self.writePpb(aligned, raised);
            const word = self.wordPpb(aligned) orelse return null;
            const lane = @as(u32, std.math.maxInt(T)) << shift;
            return self.writePpb(aligned, (word & ~lane) | raised);
        }

        const Lane = enum { merged, cleared };

        fn lanes(address: u32) ?Lane {
            const word = address & ~@as(u32, 3);
            return switch (ppb.region(address)) {
                .scb => scbLane(word - ppb.scb_base),
                .scb_ns => scbLane(word - ppb.scb_base - ppb.alias),
                .nvic => nvicLane(word - ppb.nvic_base),
                .nvic_ns => nvicLane(word - ppb.nvic_base - ppb.alias),
                else => null,
            };
        }

        fn scbLane(offset: u32) ?Lane {
            return switch (offset) {
                scb_block.shpr1, scb_block.shpr2, scb_block.shpr3 => .merged,
                scb_block.cfsr => .cleared,
                else => null,
            };
        }

        fn nvicLane(offset: u32) ?Lane {
            return if (offset -% nvic_block.ipr < nvic_block.size - nvic_block.ipr) .merged else null;
        }

        fn addressable(self: *Self, address: u32, comptime write: bool) bool {
            if (self.state.privileged() and !self.forced_unpriv) return true;
            const region = ppb.region(address);
            if (region == .itm) return true;
            if (!write or region != .scb or address -% ppb.scb_base != scb_block.stir) return false;
            return self.scs().get(scb_block.ccr) & scb_block.usersetmpend != 0;
        }

        fn timerNs(self: *Self) ?*SysTick {
            if (SysTickNs == void) return null;
            return if (self.systick_ns) |*timer| timer else null;
        }

        fn sysTickOf(self: *Self, ns: bool) ?*SysTick {
            if (!ns) return &self.systick;
            return self.timerNs() orelse if (self.flags.sttns) &self.systick else null;
        }

        fn aliasedTimer(self: *Self) ?*SysTick {
            return if (self.state.secure) self.timerNs() else null;
        }

        fn answered(into: *u32, word: ?u32) bool {
            into.* = word orelse return false;
            return true;
        }

        noinline fn readPpb(self: *Self, address: u32, into: *u32) bool {
            if (self.cycles != self.serviced) self.service();
            if (!self.addressable(address, false)) return false;
            switch (ppb.region(address)) {
                .memory => unreachable,
                .systick => return answered(into, if (self.sysTickOf(self.spec.security and !self.state.secure)) |timer| timer.readRegister(address - ppb.systick_base) else 0),
                .systick_ns => return self.spec.security and answered(into, if (self.aliasedTimer()) |timer| timer.readRegister(address - ppb.systick_base - ppb.alias) else 0),
                .control_ns => return self.spec.security and answered(into, if (!self.state.secure) 0 else switch (address - ppb.control_base - ppb.alias) {
                    ppb.ictr => (@as(u32, self.nvic.count) + 31) / 32 - 1,
                    icb_block.actlr, icb_block.cppwr => |offset| self.icb.readRegister(self.spec.core, offset, true),
                    else => null,
                }),
                .itm => return answered(into, 0),
                .dwt => return answered(into, self.dwt.readRegister(address - ppb.dwt_base, self.cycles)),
                .control => return answered(into, switch (address - ppb.control_base) {
                    ppb.ictr => if (self.architecture() != .armv6m) (@as(u32, self.nvic.count) + 31) / 32 - 1 else 0,
                    icb_block.actlr => self.icb.readRegister(self.spec.core, icb_block.actlr, self.spec.security and !self.state.secure),
                    icb_block.cppwr => if (self.architecture().v8()) self.icb.readRegister(self.spec.core, icb_block.cppwr, self.spec.security and !self.state.secure) else null,
                    else => null,
                }),
                .scb => switch (address - ppb.scb_base) {
                    scb_block.icsr => return answered(into, self.readIcsr(self.spec.security and !self.state.secure)),
                    ras_block.rfsr => return answered(into, self.readRfsr()),
                    scb_block.shcsr => return answered(into, self.readShcsr(self.spec.security and !self.state.secure)),
                    scb_block.aircr, scb_block.scr, scb_block.ccr, scb_block.nsacr, scb_block.fpccr => |offset| return answered(into, self.readView(self.spec.security and !self.state.secure, offset)),
                    sau_block.first...sau_block.last => |offset| return answered(into, if (self.spec.security and !self.state.secure) 0 else self.sau.readRegister(offset - sau_block.first)),
                    m7_block.first...m7_block.last => |offset| return answered(into, if (self.m7Control()) |block| block.readRegister(offset - m7_block.first) else null),
                    mpu_block.first...mpu_block.last => |offset| return answered(into, self.mpuOf(self.state.secure).readRegister(offset - mpu_block.first)),
                    else => |offset| return answered(into, self.scs().readRegister(offset)),
                },
                .scb_ns => {
                    if (!self.spec.security) return false;
                    if (!self.state.secure) return answered(into, 0);
                    return answered(into, switch (address - ppb.scb_base - ppb.alias) {
                        scb_block.icsr => self.readIcsr(true),
                        ras_block.rfsr => self.readRfsr(),
                        scb_block.shcsr => self.readShcsr(true),
                        scb_block.aircr, scb_block.scr, scb_block.ccr, scb_block.nsacr, scb_block.fpccr => |offset| self.readView(true, offset),
                        mpu_block.first...mpu_block.last => |offset| self.nonSecureMpu().?.readRegister(offset - mpu_block.first),
                        else => |offset| self.scb_ns.readRegister(offset),
                    });
                },
                .revidr, .revidr_ns => |region| return answered(into, self.readRevidr(region == .revidr_ns)),
                .nvic => return answered(into, self.readNvic(address - ppb.nvic_base, self.spec.security and !self.state.secure)),
                .nvic_ns => return self.spec.security and answered(into, if (self.state.secure) self.readNvic(address - ppb.nvic_base - ppb.alias, true) else 0),
                .ras => return answered(into, self.readRas(address - ras_block.base, self.spec.security and !self.state.secure)),
                .ewic => {
                    if (Ewic == void or !self.ewicOpen()) return false;
                    return answered(into, self.ewic.readRegister(address - ewic_block.base));
                },
                .impdef => {
                    if (Impdef == void) return false;
                    const block = self.impdefBlock() orelse return false;
                    const word = block.readRegister(address - impdef_block.base) orelse return false;
                    return answered(into, if (self.impdefHidden(address - impdef_block.base)) 0 else word);
                },
                .ppb_unmapped => return false,
            }
        }

        fn readRfsr(self: *Self) ?u32 {
            return if (self.architecture() == .armv8_1m_main) 0 else null;
        }

        fn readRevidr(self: *Self, aliased: bool) ?u32 {
            return switch (self.architecture()) {
                .armv6m, .armv7m, .armv7em => null,
                .armv8m_base, .armv8m_main => 0,
                .armv8_1m_main => if (self.state.secure and !aliased) self.scb.revision else null,
            };
        }

        fn wordPpb(self: *Self, address: u32) ?u32 {
            var word: u32 = undefined;
            return if (self.readPpb(address, &word)) word else null;
        }

        fn writePpb(self: *Self, address: u32, value: u32) ?void {
            if (self.cycles != self.serviced) self.service();
            if (!self.addressable(address, true)) return null;
            const was = self.pending;
            defer if (self.pending & ~was != 0) self.pended();
            defer self.schedule();
            defer self.rearm();
            defer self.reguard();
            defer self.dwt.retime(self.cycles, self.scb.get(scb_block.demcr) & scb_block.trcena != 0);
            const written = switch (ppb.region(address)) {
                .memory => unreachable,
                .systick => if (self.sysTickOf(self.spec.security and !self.state.secure)) |timer| timer.writeRegister(address - ppb.systick_base, value) else true,
                .systick_ns => self.spec.security and if (self.aliasedTimer()) |timer| timer.writeRegister(address - ppb.systick_base - ppb.alias, value) else true,
                .control_ns => self.spec.security and (!self.state.secure or switch (address - ppb.control_base - ppb.alias) {
                    ppb.ictr => true,
                    icb_block.actlr, icb_block.cppwr => |offset| blk: {
                        self.icb.writeRegister(self.spec.core, offset, true, value);
                        break :blk true;
                    },
                    else => false,
                }),
                .itm => true,
                .dwt => self.dwt.writeRegister(address - ppb.dwt_base, value, self.cycles),
                .control => switch (address - ppb.control_base) {
                    ppb.ictr => true,
                    icb_block.actlr, icb_block.cppwr => |offset| blk: {
                        if (offset == icb_block.cppwr and !self.architecture().v8()) break :blk false;
                        self.icb.writeRegister(self.spec.core, offset, self.spec.security and !self.state.secure, value);
                        break :blk true;
                    },
                    else => false,
                },
                .scb => switch (address - ppb.scb_base) {
                    scb_block.aircr => self.writeAircr(self.spec.security and !self.state.secure, value),
                    scb_block.icsr => self.writeIcsr(self.spec.security and !self.state.secure, value),
                    ras_block.rfsr => self.readRfsr() != null,
                    scb_block.shcsr => self.writeShcsr(self.spec.security and !self.state.secure, value),
                    scb_block.stir => self.trigger(value),
                    scb_block.scr, scb_block.ccr, scb_block.nsacr, scb_block.fpccr => |offset| self.writeView(self.spec.security and !self.state.secure, offset, value),
                    scb_block.shpr1, scb_block.shpr2, scb_block.shpr3 => |offset| self.scs().writeRegister(offset, value & self.nvic.lanes),
                    sau_block.first...sau_block.last => |offset| if (self.spec.security and !self.state.secure) true else self.sau.writeRegister(offset - sau_block.first, value),
                    m7_block.first...m7_block.last => |offset| if (self.m7Control()) |block| block.writeRegister(offset - m7_block.first, value) else false,
                    mpu_block.first...mpu_block.last => |offset| self.reprogram(self.mpuOf(self.state.secure), offset - mpu_block.first, value),
                    else => |offset| self.scs().writeRegister(offset, value),
                },
                .scb_ns => self.spec.security and (!self.state.secure or switch (address - ppb.scb_base - ppb.alias) {
                    scb_block.aircr => self.writeAircr(true, value),
                    scb_block.icsr => self.writeIcsr(true, value),
                    ras_block.rfsr => self.readRfsr() != null,
                    scb_block.shcsr => self.writeShcsr(true, value),
                    scb_block.stir => self.trigger(value),
                    scb_block.scr, scb_block.ccr, scb_block.nsacr, scb_block.fpccr => |offset| self.writeView(true, offset, value),
                    mpu_block.first...mpu_block.last => |offset| self.reprogram(self.nonSecureMpu().?, offset - mpu_block.first, value),
                    scb_block.shpr1, scb_block.shpr2, scb_block.shpr3 => |offset| self.scb_ns.writeRegister(offset, value & self.nvic.lanes),
                    else => |offset| self.scb_ns.writeRegister(offset, value),
                }),
                .revidr, .revidr_ns => |region| self.readRevidr(region == .revidr_ns) != null,
                .nvic => self.writeNvic(address - ppb.nvic_base, self.spec.security and !self.state.secure, value),
                .nvic_ns => self.spec.security and (!self.state.secure or self.writeNvic(address - ppb.nvic_base - ppb.alias, true, value)),
                .ras => self.readRas(address - ras_block.base, self.spec.security and !self.state.secure) != null,
                .impdef => self.writeImpdef(address - impdef_block.base, value),
                .ewic => Ewic != void and self.ewicOpen() and self.ewic.writeRegister(address - ewic_block.base, value),
                .ppb_unmapped => false,
            };
            return if (written) {} else null;
        }

        fn reprogram(self: *Self, unit: *Mpu, offset: u32, value: u32) bool {
            defer if (offset != mpu_block.rnr) self.memory.folded.unfold();
            return unit.writeRegister(offset, value);
        }

        fn nvicVisible(self: *Self, offset: u32, ns: bool) u32 {
            const implemented = self.nvic.implemented(offset);
            if (!ns) return implemented;
            return implemented & switch (offset) {
                nvic_block.iser...nvic_block.iser + nvic_block.bank,
                nvic_block.icer...nvic_block.icer + nvic_block.bank,
                nvic_block.ispr...nvic_block.ispr + nvic_block.bank,
                nvic_block.icpr...nvic_block.icpr + nvic_block.bank,
                nvic_block.iabr...nvic_block.iabr + nvic_block.bank,
                => nvic_block.wordOf(self.itns, (offset % 0x80) / 4),
                nvic_block.ipr...nvic_block.last_ipr => self.visibleLanes(offset - nvic_block.ipr),
                else => 0xffff_ffff,
            };
        }

        fn visibleLanes(self: *Self, first: u32) u32 {
            var mask: u32 = 0;
            for (0..4) |i| {
                const line = first + @as(u32, @intCast(i));
                if (line < lines and !self.targetsSecure(@intCast(first_interrupt + line))) mask |= @as(u32, 0xff) << @intCast(i * 8);
            }
            return mask;
        }

        fn readNvic(self: *Self, offset: u32, ns: bool) ?u32 {
            if (offset & 3 != 0) return null;
            const word = switch (offset) {
                nvic_block.ispr...nvic_block.ispr + nvic_block.bank => nvic_block.wordOf(self.pendingLines(), (offset - nvic_block.ispr) / 4),
                nvic_block.icpr...nvic_block.icpr + nvic_block.bank => nvic_block.wordOf(self.pendingLines(), (offset - nvic_block.icpr) / 4),
                nvic_block.iabr...nvic_block.iabr + nvic_block.bank => nvic_block.wordOf(@as(Lines, @truncate(self.active >> first_interrupt)), (offset - nvic_block.iabr) / 4),
                nvic_block.itns...nvic_block.itns + nvic_block.bank => self.readItns((offset - nvic_block.itns) / 4, ns) orelse return null,
                else => self.nvic.readRegister(offset) orelse return null,
            };
            return word & self.nvicVisible(offset, ns);
        }

        fn writeNvic(self: *Self, offset: u32, ns: bool, value: u32) bool {
            if (offset & 3 != 0) return false;
            const seen = value & self.nvicVisible(offset, ns);
            switch (offset) {
                nvic_block.ispr...nvic_block.ispr + nvic_block.bank => self.pending |= @as(Set, nvic_block.placed(Lines, seen, (offset - nvic_block.ispr) / 4)) << first_interrupt,
                nvic_block.icpr...nvic_block.icpr + nvic_block.bank => self.pending &= ~(@as(Set, nvic_block.placed(Lines, seen, (offset - nvic_block.icpr) / 4)) << first_interrupt),
                nvic_block.iabr...nvic_block.iabr + nvic_block.bank => {},
                nvic_block.itns...nvic_block.itns + nvic_block.bank => return self.writeItns((offset - nvic_block.itns) / 4, ns, value & self.nvic.implemented(offset)),
                nvic_block.ipr...nvic_block.last_ipr => {
                    const kept = (self.nvic.readRegister(offset) orelse 0) & ~self.nvicVisible(offset, ns);
                    return self.nvic.writeRegister(offset, kept | seen);
                },
                else => return self.nvic.writeRegister(offset, seen),
            }
            return true;
        }

        fn trigger(self: *Self, value: u32) bool {
            if (!self.architecture().main()) return self.architecture().v8();
            const line = value & 0x1ff;
            if (line >= self.nvic.count) return true;
            const n: Index = @intCast(first_interrupt + line);
            if (self.spec.security and !self.state.secure and self.targetsSecure(n)) return true;
            self.pending |= one(n);
            return true;
        }

        const Held = struct {
            bit: u5,
            n: Index,
            pending: bool = false,
            reach: enum { banked, routed, secure } = .banked,
            v8: bool = false,
            baseline: bool = false,
        };

        const held_bits = [_]Held{
            .{ .bit = 0, .n = mem_manage },
            .{ .bit = 1, .n = bus_fault, .reach = .routed },
            .{ .bit = 2, .n = hard_fault, .v8 = true, .baseline = true },
            .{ .bit = 3, .n = usage_fault },
            .{ .bit = 4, .n = secure_fault, .reach = .secure },
            .{ .bit = 5, .n = nmi, .reach = .routed, .v8 = true, .baseline = true },
            .{ .bit = 7, .n = svcall, .baseline = true },
            .{ .bit = 10, .n = pendsv, .baseline = true },
            .{ .bit = 11, .n = systick, .baseline = true },
            .{ .bit = 12, .n = usage_fault, .pending = true },
            .{ .bit = 13, .n = mem_manage, .pending = true },
            .{ .bit = 14, .n = bus_fault, .pending = true, .reach = .routed },
            .{ .bit = 15, .n = svcall, .pending = true, .baseline = true },
            .{ .bit = 20, .n = secure_fault, .pending = true, .reach = .secure },
            .{ .bit = 21, .n = hard_fault, .pending = true, .v8 = true, .baseline = true },
        };

        fn shcsrHeld(self: *Self, comptime slot: Held, ns: bool) ?Index {
            if (slot.v8 and !self.architecture().v8()) return null;
            if (!slot.baseline and !self.architecture().main()) return null;
            if (!self.spec.security) return if (slot.reach == .secure) null else slot.n;
            return switch (slot.reach) {
                .banked => slot.n + if (ns) ns_base else 0,
                .routed => if (self.reaches(ns)) self.instance(slot.n) else null,
                .secure => if (ns) null else slot.n,
            };
        }

        fn reaches(self: *Self, ns: bool) bool {
            return !ns or self.faultsNonSecure();
        }

        fn shcsrWritable(self: *Self, comptime slot: Held, ns: bool, set: bool) bool {
            if (slot.pending or (slot.n != hard_fault and slot.n != nmi)) return true;
            return !set and ns and self.state.secure;
        }

        fn shcsrBlocks(self: *Self, ns: bool) [3]struct { *scb_block.Scb, u32 } {
            return .{
                .{ self.scbOf(!ns), scb_block.memfaultena | scb_block.usgfaultena },
                .{ &self.scb, scb_block.monitoract | (if (ns) 0 else scb_block.secureflt_ena) },
                .{ self.scbOf(!self.faultsNonSecure()), if (self.reaches(ns)) scb_block.busfaultena else 0 },
            };
        }

        fn readShcsr(self: *Self, ns: bool) u32 {
            if (self.architecture() == .armv6m) return 0;
            var value: u32 = 0;
            if (self.architecture().main()) {
                for (self.shcsrBlocks(ns)) |part| value |= part[0].get(scb_block.shcsr) & part[1];
            }
            inline for (held_bits) |slot| {
                if (self.shcsrHeld(slot, ns)) |i| {
                    value |= bit(if (slot.pending) self.pending else self.active, i) << slot.bit;
                }
            }
            return value;
        }

        fn writeShcsr(self: *Self, ns: bool, value: u32) bool {
            if (self.architecture() == .armv6m) return true;
            if (self.architecture().main()) {
                for (self.shcsrBlocks(ns)) |part| part[0].writeBits(scb_block.shcsr, part[1], value);
            }
            inline for (held_bits) |slot| {
                const set = value >> slot.bit & 1 != 0;
                if (self.shcsrHeld(slot, ns)) |i| {
                    if (self.shcsrWritable(slot, ns, set)) {
                        const mask = one(i);
                        const target = if (slot.pending) &self.pending else &self.active;
                        target.* = if (set) target.* | mask else target.* & ~mask;
                    }
                }
            }
            return true;
        }

        fn own(self: *Self) Index {
            return if (self.spec.security and !self.state.secure) ns_base else 0;
        }

        fn nmiVisible(self: *Self, ns: bool) bool {
            return !ns or self.faultsNonSecure();
        }

        fn sysTickException(self: *Self, ns: bool) ?Index {
            if (self.timerNs() != null) return if (ns) systick + ns_base else systick;
            return if (!ns or self.flags.sttns) self.instance(systick) else null;
        }

        fn readIcsr(self: *Self, ns: bool) u32 {
            const interrupts: Lines = @truncate(self.pending >> first_interrupt);
            const to_base: u32 = if (!self.architecture().main()) 0 else @intFromBool(@popCount(self.active) < 2);
            const side: Index = if (ns) ns_base else 0;
            return (self.state.xpsr & State.ipsr_mask) |
                to_base << 11 |
                @as(u32, if (self.best()) |next| numberOf(next.n) else 0) << 12 |
                @as(u32, @intFromBool(interrupts != 0)) << 22 |
                (if (!ns and self.flags.sttns) scb_block.sttns else 0) |
                (if (self.sysTickException(ns)) |tick| bit(self.pending, tick) else 0) << 26 |
                bit(self.pending, pendsv + side) << 28 |
                (if (self.nmiVisible(ns)) bit(self.pending, self.instance(nmi)) else 0) << 31;
        }

        fn writeAircr(self: *Self, ns: bool, value: u32) bool {
            if (value >> 16 != scb_block.vectkey) return true;
            const kept = ns and self.scb.get(scb_block.aircr) & scb_block.sysresetreqs != 0;
            if (value & scb_block.sysresetreq != 0 and !kept) self.due |= reset_due;
            return self.writeView(ns, scb_block.aircr, value);
        }

        const Shared = struct { held: u32 = 0, readable: u32 = 0, writable: u32 = 0 };

        fn sharedOf(self: *Self, offset: u32) Shared {
            return switch (offset) {
                scb_block.aircr => blk: {
                    const open: u32 = if (self.faultsNonSecure()) scb_block.iesb else 0;
                    break :blk .{ .held = scb_block.pris | scb_block.bfhfnmins | scb_block.sysresetreqs | scb_block.iesb, .readable = scb_block.bfhfnmins | open, .writable = open };
                },
                scb_block.ccr => blk: {
                    const open: u32 = if (self.faultsNonSecure()) scb_block.bfhfnmign else 0;
                    break :blk .{ .held = scb_block.bfhfnmign, .readable = scb_block.bfhfnmign, .writable = open };
                },
                scb_block.fpccr => blk: {
                    const word = self.scb.get(scb_block.fpccr);
                    const routed: u32 = if (self.faultsNonSecure()) scb_block.bfrdy | scb_block.hfrdy else 0;
                    const lazy: u32 = if (word & scb_block.lspens != 0) 0 else scb_block.lspen;
                    const clear: u32 = if (word & scb_block.clronrets != 0) 0 else scb_block.clronret;
                    break :blk .{
                        .held = scb_block.lspen | scb_block.lspens | scb_block.clronret | scb_block.clronrets | scb_block.treat_as_secure | scb_block.monrdy | scb_block.sfrdy | scb_block.bfrdy | scb_block.hfrdy | scb_block.fp_secure,
                        .readable = scb_block.lspen | scb_block.clronret | scb_block.monrdy | routed,
                        .writable = lazy | clear | scb_block.monrdy | routed,
                    };
                },
                scb_block.nsacr => .{ .held = 0xffff_ffff },
                scb_block.scr => blk: {
                    const open: u32 = if (self.scb.get(scb_block.scr) & scb_block.sleepdeeps != 0) 0 else scb_block.sleepdeep;
                    break :blk .{ .held = scb_block.sleepdeeps | scb_block.sleepdeep, .readable = open, .writable = open };
                },
                else => .{},
            };
        }

        fn readView(self: *Self, ns: bool, offset: u32) ?u32 {
            if (!ns) return self.scb.readRegister(offset);
            const shared = self.sharedOf(offset);
            const word = self.scb_ns.readRegister(offset) orelse return null;
            return (word & ~shared.held) | (self.scb.readRegister(offset).? & shared.readable);
        }

        fn writeView(self: *Self, ns: bool, offset: u32, value: u32) bool {
            if (!ns) return self.scb.writeRegister(offset, value);
            const shared = self.sharedOf(offset);
            if (shared.writable != 0) self.scb.writeBits(offset, shared.writable, value);
            return self.scb_ns.writeRegister(offset, value & ~shared.held);
        }

        fn writeIcsr(self: *Self, ns: bool, value: u32) bool {
            const side: Index = if (ns) ns_base else 0;
            if (value & 1 << 31 != 0 and self.nmiVisible(ns)) self.pending |= one(self.instance(nmi));
            if (value & 1 << 30 != 0 and self.architecture().v8() and self.nmiVisible(ns)) self.pending &= ~one(self.instance(nmi));
            if (value & 1 << 28 != 0) self.pending |= one(pendsv + side);
            if (value & 1 << 27 != 0) self.pending &= ~one(pendsv + side);
            if (self.sysTickException(ns)) |n| {
                const tick = one(n);
                if (value & 1 << 26 != 0) self.pending |= tick;
                if (value & 1 << 25 != 0) self.pending &= ~tick;
            }
            if (self.spec.security and !ns and self.timerNs() == null) self.flags.sttns = value & scb_block.sttns != 0;
            return true;
        }

        fn targets(self: *Self, i: Index) bool {
            if (!self.security()) return true;
            return i < ns_base and (numberOf(i) < first_interrupt or self.targetsSecure(i));
        }

        fn carriesFp(self: *Self) bool {
            if (!self.architecture().main()) return false;
            return self.floatingPoint() and self.state.control & State.control_fpca != 0;
        }

        fn priority(self: *Self, i: Index) i16 {
            const secured = self.security();
            if (!secured) return self.configured(i, true);
            const secure = self.targets(i);
            const raw = self.configured(numberOf(i), secure);
            if (secure or raw < 0 or !self.shiftsNonSecure()) return raw;
            return (raw >> 1) + restricted;
        }

        fn configured(self: *Self, n: Index, secure: bool) i16 {
            return switch (n) {
                1 => -3,
                nmi => -2,
                hard_fault => if (secure and self.security() and self.faultsNonSecure()) -3 else -1,
                mem_manage => self.shpr(secure, 0),
                bus_fault => self.shpr(secure, 8),
                usage_fault => self.shpr(secure, 16),
                secure_fault => self.shpr(true, 24),
                svcall => @intCast(self.scbOf(secure).get(scb_block.shpr2) >> 24),
                pendsv => @intCast((self.scbOf(secure).get(scb_block.shpr3) >> 16) & 0xff),
                systick => @intCast(self.scbOf(secure).get(scb_block.shpr3) >> 24),
                first_interrupt...first_interrupt + lines - 1 => self.nvic.priority(@intCast(n - first_interrupt)),
                else => 256,
            };
        }

        fn shpr(self: *Self, secure: bool, comptime shift: u5) i16 {
            if (!self.architecture().main()) return 256;
            return @intCast((self.scbOf(secure).get(scb_block.shpr1) >> shift) & 0xff);
        }

        fn executionPriority(self: *Self) i16 {
            return @min(self.rawPriority(), self.boosted());
        }

        fn rawPriority(self: *Self) i16 {
            var highest: i16 = 256;
            var active = self.active;
            while (active != 0) : (active &= active - 1) {
                highest = @min(highest, self.priority(@intCast(@ctz(active))));
            }
            return highest;
        }

        fn boosted(self: *Self) i16 {
            const s = &self.state;
            if (!self.security()) {
                var boost: i16 = 256;
                if (s.basepri != 0) boost = s.basepri;
                if (s.primask) boost = 0;
                if (s.faultmask) boost = -1;
                return boost;
            }
            const shift = self.shiftsNonSecure();
            const floor: i16 = if (shift) restricted else 0;
            const ns = self.masks(false);
            const secure = self.masks(true);
            var level: i16 = 256;
            if (ns.basepri != 0) level = if (shift) (@as(i16, ns.basepri) >> 1) + restricted else ns.basepri;
            if (secure.basepri != 0) level = @min(level, secure.basepri);
            if (ns.primask) level = @min(level, floor);
            if (secure.primask) level = 0;
            if (ns.faultmask) level = if (self.faultsNonSecure()) -1 else @min(level, floor);
            if (secure.faultmask) level = if (self.faultsNonSecure()) -3 else -1;
            return level;
        }

        fn rankOf(i: Index, level: i16) u32 {
            return @as(u32, @intCast(level + 4)) << 16 | @as(u32, numberOf(i)) << 1 | @intFromBool(i >= ns_base);
        }

        fn best(self: *Self) ?Next {
            const reachable: Set = 0xffff | @as(Set, self.nvic.enabled) << first_interrupt |
                (if (self.security()) @as(Set, 0xffff) << ns_base else 0);
            var found: ?Next = null;
            var rank: u32 = 0;
            var waiting = self.pending & ~@as(Set, 3) & reachable;
            while (waiting != 0) : (waiting &= waiting - 1) {
                const i: Index = @intCast(@ctz(waiting));
                const level = self.priority(i);
                const order = rankOf(i, level);
                if (found == null or order < rank) {
                    found = .{ .n = i, .priority = level };
                    rank = order;
                }
            }
            return found;
        }

        fn takePending(self: *Self) bool {
            const next = self.best() orelse return false;
            if (next.priority < self.executionPriority()) {
                self.pending &= ~one(next.n);
                self.flags.escalated = false;
                _ = self.enter(next.n);
                self.delay(self.spec.entry);
                return true;
            }
            if (self.flags.escalated and numberOf(next.n) == hard_fault) {
                _ = self.lockAt(.unrecoverable_exception);
                return true;
            }
            return false;
        }

        noinline fn enter(self: *Self, n: Index) ?Stop {
            const s = &self.state;
            const secured = self.security();
            const wide_frame = self.carriesFp();
            const hand_over = secured and s.secure and !self.targets(n);
            self.derived = null;
            if (self.push(!s.handler(), wide_frame)) |stop| return stop;
            if (hand_over) {
                if (self.pushCallee(wide_frame)) |stop| return stop;
            }
            const i = self.arriving(n);
            const secure = self.targets(i);
            const target = if (secured and s.secure != secure) self.banked.control else s.control;
            var lr = (if (s.handler()) return_to_handler else return_to_thread_main) | (target & State.control_spsel) << 1;
            if (wide_frame) lr &= ~basic_frame;
            if (secured) {
                if (!s.secure) lr &= ~secure_stack;
                if (hand_over and secure) lr &= ~default_callee;
                if (!secure) {
                    lr &= ~secure_target;
                    s.r[0] = 0;
                    s.r[1] = 0;
                    s.r[2] = 0;
                    s.r[3] = 0;
                    s.r[12] = 0;
                    s.xpsr &= ~(@as(u32, 0xf800_0000) | State.flag_ge);
                }
                if (hand_over and !secure) {
                    for (4..12) |r| s.r[r] = 0;
                }
                if (s.secure != secure) {
                    s.secure = secure;
                    self.bank();
                }
            }
            return self.take(i, lr);
        }

        fn arriving(self: *Self, n: Index) Index {
            const d = self.derived orelse return n;
            if (!self.spec.architecture.v8()) return n;
            if (rankOf(d, self.priority(d)) >= rankOf(n, self.priority(n))) return n;
            self.pending = (self.pending | one(n)) & ~one(d);
            self.due |= other_due;
            return d;
        }

        fn pushCallee(self: *Self, wide_frame: bool) ?Stop {
            const s = &self.state;
            const sp: *u32 = if (!s.handler() and s.control & State.control_spsel != 0) &s.psp else &s.msp;
            sp.* -%= callee_frame;
            const frame = sp.*;
            const words = [10]u32{ signature | @intFromBool(!wide_frame), 0, s.r[4], s.r[5], s.r[6], s.r[7], s.r[8], s.r[9], s.r[10], s.r[11] };
            for (words, 0..) |word, i| {
                const at = frame + @as(u32, @intCast(i)) * 4;
                self.touch(at);
                self.store(4, at, word) orelse return self.stacked();
            }
            return null;
        }

        fn popCallee(self: *Self, sp: *u32) ?Stop {
            const s = &self.state;
            const frame = sp.*;
            for (0..8) |i| {
                const at = frame + 8 + @as(u32, @intCast(i)) * 4;
                self.touch(at);
                s.r[4 + i] = self.load(4, at) orelse return self.faultAt(s.pc, .data_fault);
            }
            sp.* = frame +% callee_frame;
            return null;
        }

        fn push(self: *Self, thread: bool, wide_frame: bool) ?Stop {
            const s = &self.state;
            const sp: *u32 = if (thread and s.control & State.control_spsel != 0) &s.psp else &s.msp;
            const forced = wide_frame or self.alignsStack();
            const misaligned = if (forced) (sp.* >> 2) & 1 else 0;
            const callee_fp = wide_frame and s.secure and self.treatAsSecure();
            sp.* = (sp.* -% frameSize(wide_frame, callee_fp)) & ~(if (forced) @as(u32, 4) else 0);
            const frame = sp.*;
            const stacked_sfpa: u32 = if (s.secure) (s.control & State.control_sfpa) << 17 else 0;
            const words = [8]u32{ s.r[0], s.r[1], s.r[2], s.r[3], s.r[12], s.lr, s.pc, (s.xpsr & ~(frame_align | frame_sfpa)) | (misaligned << 9) | stacked_sfpa };
            for (words, 0..) |word, i| {
                const at = frame + @as(u32, @intCast(i)) * 4;
                self.touch(at);
                self.store(4, at, word) orelse return self.stacked();
            }
            if (!wide_frame) return null;
            if (self.lazyFpEnabled()) {
                self.setLazyFp(frame + 0x20);
                return null;
            }
            for (0..16) |i| {
                const at = frame + 0x20 + @as(u32, @intCast(i)) * 4;
                self.touch(at);
                self.store(4, at, s.fp[i]) orelse return self.stacked();
            }
            self.store(4, frame + 0x60, s.fpscr) orelse return self.stacked();
            self.store(4, frame + 0x64, if (self.mve()) s.vpr else 0) orelse return self.stacked();
            if (!callee_fp) return null;
            for (16..32) |i| {
                const at = frame + state_frame + fp_caller_frame + 4 * @as(u32, @intCast(i - 16));
                self.touch(at);
                self.store(4, at, s.fp[i]) orelse return self.stacked();
            }
            return null;
        }

        fn take(self: *Self, i: Index, lr: u32) ?Stop {
            const s = &self.state;
            s.exclusive = null;
            s.lr = lr;
            if (self.floatingPoint()) s.control &= ~(State.control_fpca | (if (self.security()) State.control_sfpa else 0));
            s.xpsr = (s.xpsr & ~(State.ipsr_mask | State.it_mask | State.flag_b)) | numberOf(i);
            s.control &= ~State.control_spsel;
            self.active |= one(i);
            const at = self.scs().get(scb_block.vtor) +% @as(u32, numberOf(i)) * 4;
            const from = s.pc;
            const start = self.readVector(at) orelse {
                self.scbOf(true).hardFault(scb_block.vecttbl);
                self.active &= ~one(i);
                const forced = self.instance(hard_fault);
                if (numberOf(i) == hard_fault or self.priority(forced) >= self.executionPriority()) return self.faultAt(at, .fetch_fault);
                return self.take(forced, lr);
            };
            self.entering(i, at, start, from);
            s.branchTo(start);
            self.event();
            self.forget();
            self.record(s.pc, null, .{
                .kind = if (numberOf(i) >= first_interrupt) .irq else .entry,
                .number = if (numberOf(i) >= first_interrupt) numberOf(i) - first_interrupt else numberOf(i),
                .latency = self.spec.entry,
            });
            return null;
        }

        noinline fn leave(self: *Self, exc_return: u32) ?Stop {
            const s = &self.state;
            const number = s.xpsr & State.ipsr_mask;
            const nested = @popCount(self.active) != 1;
            const main_profile = self.architecture().main();
            const secured = self.security();
            const shape: u32 = if (secured) 0x0fff_ff80 else if (main_profile) 0x0fff_ffe0 else 0x0fff_fff0;
            if (exc_return & shape != shape) return self.lockAt(.exception_return);
            if (number >= ns_base) return self.refuse(number, exc_return);
            const n: Index = if (secured and number < first_interrupt and exc_return & secure_target == 0) @intCast(number + ns_base) else @intCast(number);
            if (self.active & one(n) == 0) return self.refuse(number, exc_return);
            switch (if (secured) exc_return & 0xe | 1 else exc_return & 0xf) {
                0x1 => if (!nested and !main_profile) return self.refuse(number, exc_return),
                0x5 => if (!secured or (!nested and !main_profile)) return self.refuse(number, exc_return),
                0x9, 0xd => if (nested and self.scs().get(scb_block.ccr) & scb_block.nonbasethrdena == 0) return self.refuse(number, exc_return),
                else => return self.refuse(number, exc_return),
            }
            const raw = self.rawPriority();
            self.active &= ~one(n);
            self.event();
            if (self.floatingPoint() and s.control & State.control_fpca != 0 and self.scb.get(scb_block.fpccr) & scb_block.clronret != 0) {
                if (self.scbOf(true).get(scb_block.fpccr) & scb_block.lspact != 0) {
                    self.sau.flag(sau_block.lserr);
                    return self.escalate(.secure_fault, exc_return);
                }
                if (self.architecture() == .armv8_1m_main) {
                    if (self.coprocessorRefused(true, exc_return & secure_target != 0)) |target| return self.refuseCoprocessor(target, exc_return);
                }
                @memset(s.fp[0..16], 0);
                s.fpscr = 0;
                s.vpr = 0;
            }
            if (secured) {
                const background = exc_return & secure_stack != 0;
                if (background != s.secure) {
                    s.secure = background;
                    self.bank();
                }
            }
            const spsel: u32 = (exc_return >> 1) & State.control_spsel;
            if (self.returningIsCurrent(secured, exc_return)) {
                s.control = (s.control & ~State.control_spsel) | spsel;
            } else {
                self.banked.control = (self.banked.control & ~State.control_spsel) | spsel;
            }
            const thread = exc_return & 0x8 != 0;
            const process = thread and s.control & State.control_spsel != 0;
            const sp: *u32 = if (process) &s.psp else &s.msp;
            s.exclusive = null;
            if (secured and exc_return & secure_stack != 0 and exc_return & (secure_target | default_callee) != secure_target | default_callee) {
                self.touch(sp.*);
                const mark = self.load(4, sp.*) orelse return self.faultAt(s.pc, .data_fault);
                if (mark != signature | (exc_return >> 4 & 1)) {
                    self.sau.flag(sau_block.invis);
                    return self.escalate(.secure_fault, exc_return);
                }
                if (self.popCallee(sp)) |stop| return stop;
            }
            var words: [8]u32 = undefined;
            for (&words, 0..) |*word, i| {
                const at = sp.* + @as(u32, @intCast(i)) * 4;
                self.touch(at);
                word.* = self.load(4, at) orelse return self.faultAt(s.pc, .data_fault);
            }
            s.r[0] = words[0];
            s.r[1] = words[1];
            s.r[2] = words[2];
            s.r[3] = words[3];
            s.r[12] = words[4];
            s.lr = words[5];
            s.pc = words[6] & ~@as(u32, 1);
            const psr = words[7];
            const wide_frame = main_profile and exc_return & basic_frame == 0;
            const callee_fp = wide_frame and s.secure and self.treatAsSecure();
            if (wide_frame) {
                if (self.lazyFpFrame() != null) {
                    self.setLazyFp(null);
                } else {
                    for (0..16) |i| {
                        const at = sp.* + 0x20 + @as(u32, @intCast(i)) * 4;
                        self.touch(at);
                        s.fp[i] = self.load(4, at) orelse return self.faultAt(s.pc, .data_fault);
                    }
                    s.fpscr = fp.written(Self, self, self.load(4, sp.* + 0x60) orelse return self.faultAt(s.pc, .data_fault));
                    const vpr = self.load(4, sp.* + 0x64) orelse return self.faultAt(s.pc, .data_fault);
                    if (self.mve()) s.vpr = vpr;
                    if (callee_fp) {
                        for (16..32) |i| {
                            const at = sp.* + state_frame + fp_caller_frame + 4 * @as(u32, @intCast(i - 16));
                            self.touch(at);
                            s.fp[i] = self.load(4, at) orelse return self.faultAt(s.pc, .data_fault);
                        }
                    }
                }
            }
            if (self.floatingPoint()) {
                s.control = (s.control & ~State.control_fpca) | (if (wide_frame) State.control_fpca else 0);
                if (secured and s.secure) s.control = (s.control & ~State.control_sfpa) | (psr & frame_sfpa) >> 17;
            }
            sp.* = (sp.* +% frameSize(wide_frame, callee_fp)) | (if (wide_frame or self.alignsStack()) (psr & frame_align) >> 7 else 0);
            if (if (self.architecture().v8()) raw >= 0 else numberOf(n) != nmi) {
                if (self.returningIsCurrent(secured, exc_return)) s.faultmask = false else self.banked.faultmask = false;
            }
            const force_thread = !main_profile and thread and s.control & State.control_npriv != 0;
            const apsr: u32 = if (main_profile) 0xf800_0000 | State.flag_ge else 0xf000_0000;
            s.xpsr = (psr & apsr) | (psr & State.flag_t) | (if (main_profile) psr & State.it_mask else 0) | (if (self.pacbti()) psr & State.flag_b else 0) | (if (force_thread) 0 else psr & State.ipsr_mask);
            self.forget();
            self.record(s.pc, null, .{ .kind = .exit, .latency = self.spec.exit });
            const handler_frame = !force_thread and psr & State.ipsr_mask != 0;
            if (handler_frame != thread) return null;
            if (!main_profile) return self.lockAt(.exception_return);
            self.scs().fault(.exception_return, 0);
            if (self.push(thread, self.carriesFp())) |stop| return stop;
            return self.escalate(.exception_return, exc_return);
        }

        fn coprocessorRefused(self: *Self, privileged: bool, secure: bool) ?bool {
            const field = self.scbOf(secure).get(scb_block.cpacr) & scb_block.cp10;
            if (field == 0 or (field == 1 << 20 and !privileged)) return secure;
            if (!self.spec.security) return null;
            if (!secure and self.scb.get(scb_block.nsacr) & scb_block.nsacr_cp10 == 0) return true;
            if (self.icb.cppwr & icb_block.su10 != 0) return secure or self.icb.cppwr & icb_block.sus10 != 0;
            return null;
        }

        fn refuseCoprocessor(self: *Self, secure: bool, exc_return: u32) ?Stop {
            self.scbOf(secure).fault(.no_coprocessor, 0);
            self.flags.nocp_secure = secure;
            defer self.flags.nocp_secure = false;
            return self.escalate(.no_coprocessor, exc_return);
        }

        fn returningIsCurrent(self: *Self, secured: bool, exc_return: u32) bool {
            return !secured or (exc_return & secure_target != 0) == self.state.secure;
        }

        fn refuse(self: *Self, number: u32, exc_return: u32) ?Stop {
            if (!self.architecture().main()) return self.lockAt(.exception_return);
            if (number < ns_base) self.active &= ~one(@intCast(number));
            self.scs().fault(.exception_return, 0);
            return self.escalate(.exception_return, exc_return);
        }

        fn standingIn(self: *Self) Index {
            const target = self.instance(hard_fault);
            self.scbOf(!self.security() or target < ns_base).hardFault(scb_block.forced);
            return target;
        }

        fn escalate(self: *Self, kind: Stop, exc_return: u32) ?Stop {
            if (self.executionPriority() <= -1) return self.lockAt(.unrecoverable_exception);
            self.delay(self.spec.entry);
            const target = self.configurable(kind) orelse self.standingIn();
            self.remember(kind, target, 0xf000_0000 | exc_return);
            const secure = !self.security() or target < ns_base;
            if (secure != self.state.secure) {
                self.state.secure = secure;
                self.bank();
            }
            return self.take(target, 0xf000_0000 | exc_return);
        }
    };
}
