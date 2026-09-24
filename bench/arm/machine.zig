const std = @import("std");
const core = @import("core");
const harness = @import("harness");

const Loaded = harness.consumer.Loaded;
const Ran = harness.facade.Ran;
const Snapshot = harness.snapshot.Snapshot;
const Stop = harness.snapshot.Stop;

const which: core.arm.Core = @field(core.arm.Core, @import("rep").arm);
const Cpu = core.arm.Processor(.{ .cores = &.{which}, .Bus = core.memory.Regions });

pub const Machine = struct {
    pub const arch: harness.facade.Arch = .armv7m;
    pub const result_register: u5 = 0;
    pub const isa_provides: []const harness.contract.Requirement = &isa_requirements;

    pub const table_bytes: u64 = @sizeOf(core.memory.Regions);

    pub const processor_bytes: u64 = @sizeOf(Machine);

    cpu: Cpu,
    event: u16 = 0,
    console: ?*std.Io.Writer,

    pub fn init(loaded: Loaded) !Machine {
        const bus = try harness.consumer.bus(loaded);
        var self: Machine = .{
            .cpu = Cpu.init(bus, which, try .init(try loaded.arena.alloc(core.arm.trace.Record, loaded.history))),
            .console = loaded.console,
        };
        self.cpu.state.msp = (bus.peek(4, 0) orelse 0) & ~@as(u32, 3);
        self.cpu.state.lr = harness.facade.armv7m_reset.lr;
        self.cpu.state.xpsr = harness.facade.armv7m_reset.xpsr;
        self.cpu.state.branchTo(harness.consumer.entryOf(loaded.elf));
        if (self.cpu.trace.recording()) self.cpu.last = core.arm.trace.snapshot(&self.cpu.state);
        return self;
    }

    pub fn run(self: *Machine, budget: u64) Ran {
        return self.until(budget, std.math.maxInt(u64), .budget);
    }

    pub fn step(self: *Machine) Ran {
        const before = self.work();
        const active = self.cpu.active;
        const one = self.cpu.step();
        if (one.asleep) self.cpu.charge(1);
        const entered = self.cpu.active & ~active != 0;
        self.event = (if (active & ~self.cpu.active != 0) @as(u16, 1) << 15 else 0) |
            (if (entered) @as(u16, @truncate(self.cpu.state.xpsr & 0x1ff)) else 0);
        const after = self.work();
        return .{
            .retired = @intFromBool(one.class != null),
            .cycles = after.cycles - before.cycles,
            .latency = after.latency - before.latency,
            .stop = if (one.stop) |stop| if (self.serviced()) .running else stopOf(stop) else .running,
            .exceptions = after.exceptions - before.exceptions,
            .irqs = after.irqs - before.irqs,
        };
    }

    pub fn burst(self: *Machine, budget: u64, cycles: u64) Ran {
        return self.until(budget, cycles, .running);
    }

    fn until(self: *Machine, budget: u64, cycles: u64, ended: Stop) Ran {
        const before = self.work();
        var total: Ran = .{ .stop = ended };
        while (total.retired < budget) {
            const ran = self.cpu.run(.{ .instructions = budget - total.retired, .cycles = cycles -| total.cycles });
            total.retired += ran.instructions;
            total.cycles += ran.cycles;
            total.latency += ran.latency;
            const stop = ran.stop orelse break;
            if (self.serviced()) continue;
            total.stop = stopOf(stop);
            break;
        }
        const after = self.work();
        total.exceptions = after.exceptions - before.exceptions;
        total.irqs = after.irqs - before.irqs;
        return total;
    }

    fn work(self: *const Machine) struct { cycles: u64, exceptions: u64, irqs: u64, latency: u64 } {
        return .{ .cycles = self.cpu.cycles, .exceptions = self.cpu.exceptions, .irqs = self.cpu.irqs, .latency = self.cpu.latency };
    }

    fn serviced(self: *Machine) bool {
        const console = self.console orelse return false;
        if (!Cpu.semihosting.trapped(&self.cpu)) return false;
        const exited = Cpu.semihosting.call(&self.cpu, console) catch return false;
        return exited == null;
    }

    pub fn snapshot(self: *const Machine) Snapshot {
        var out: Snapshot = .{
            .pc = self.cpu.state.pc,
            .flags = self.cpu.state.xpsr,
            .retired = self.cpu.instructions,
            .cycles = self.cpu.cycles,
            .pending_lo = @truncate(self.cpu.pending),
            .active_lo = @truncate(self.cpu.active),
            .stop = if (self.cpu.stop) |stop| stopOf(stop) else .running,
            .systick_cvr = self.cpu.systick.cvr,
            .exception = @truncate(self.cpu.state.xpsr & 0x1ff),
            .primask = @intFromBool(self.cpu.state.primask),
            .basepri = self.cpu.state.basepri,
            .faultmask = @intFromBool(self.cpu.state.faultmask),
            .control = @truncate(self.cpu.state.control),
        };
        @memcpy(out.regs[0..13], &self.cpu.state.r);
        out.regs[13] = self.cpu.state.sp();
        out.regs[14] = self.cpu.state.lr;
        out.regs[15] = self.cpu.state.pc;
        return out;
    }

    pub fn trap(self: *const Machine) harness.snapshot.Trap {
        return .{ .event = self.event };
    }

    pub fn clock(self: *const Machine) *const u64 {
        return &self.cpu.cycles;
    }

    pub fn read32(self: *Machine, address: u32) ?u32 {
        return self.cpu.peek(4, address);
    }

    pub fn explain(self: *Machine, into: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(into);
        self.cpu.explain(&w, 0) catch {};
        return w.buffered();
    }

    fn stopOf(stop: core.arm.Stop) Stop {
        return switch (stop) {
            .breakpoint => .breakpoint,
            .fetch_fault, .fetch_violation => .fetch_fault,
            .data_fault, .data_violation, .secure_fault, .unrecoverable_exception, .exception_return => .data_fault,
            .unaligned_access => .unaligned,
            else => .undefined_instruction,
        };
    }
};

const isa_requirements = [_]harness.contract.Requirement{
    .{ .name = "span", .Signature = @TypeOf(Cpu.span), .why = "one lookup answers the whole per-access question: whether the MPU permits it (Armv7-M B3.5), whether the default map makes it execute-never, whether it is a device or a private peripheral, and which host bytes back it, returning the span from the address to the end of the answer so a load multiple and a two-parcel fetch are answered once" },
    .{ .name = "access", .Signature = @TypeOf(Cpu.access), .why = "the device and private peripheral lane, reached only where span answered a span shorter than the access, so no access site tests ppb.region on the fast path; the fault is its return value, which is what the instruction set stops for instead of reading the reason back out of the core" },
    .{ .name = "touch", .Signature = @TypeOf(Cpu.touch), .why = "the address a run of accesses begins at, once per lookup rather than once per word, for the fault address registers Armv7-M B3.2.17 and B3.2.18 and the trace line" },
    .{ .name = "allowed", .Signature = @TypeOf(Cpu.allowed), .why = "comptime group word; selects which rows the decode tables hold" },
    .{ .name = "model", .Signature = @FieldType(Cpu, "model"), .why = "the decode selection and the cost table this core steps with" },
    .{ .name = "costOf", .Signature = @TypeOf(Cpu.costOf), .why = "what the core's published table charges the class it just retired" },
    .{ .name = "architecture", .Signature = @TypeOf(Cpu.architecture), .why = "profile test, so one build answers for several architectures" },
    .{ .name = "security", .Signature = @TypeOf(Cpu.security), .why = "whether the security extension is present" },
    .{ .name = "priorityBits", .Signature = @TypeOf(Cpu.priorityBits), .why = "how many priority bits BASEPRI keeps" },
    .{ .name = "doublePrecision", .Signature = @TypeOf(Cpu.doublePrecision), .why = "whether the FPU has the double-precision registers" },
    .{ .name = "halfPrecision", .Signature = @TypeOf(Cpu.halfPrecision), .why = "whether the FPU has the half-precision instructions" },
    .{ .name = "fpv5", .Signature = @TypeOf(Cpu.fpv5), .why = "which floating-point architecture the FPU implements" },
    .{ .name = "pacbti", .Signature = @TypeOf(Cpu.pacbti), .why = "whether pointer authentication is present" },
    .{ .name = "mve", .Signature = @TypeOf(Cpu.mve), .why = "whether the vector extension is present" },
    .{ .name = "floatingPoint", .Signature = @TypeOf(Cpu.floatingPoint), .why = "whether a floating-point or vector unit is fitted, which makes CONTROL.FPCA and SFPA writable" },
    .{ .name = "treatAsSecure", .Signature = @TypeOf(Cpu.treatAsSecure), .why = "FPCCR.TS, whether the floating-point context is treated as Secure", .optional = true },
    .{ .name = "coprocessorEnabled", .Signature = @TypeOf(Cpu.coprocessorEnabled), .why = "tells an absent coprocessor from an undefined encoding" },
    .{ .name = "trapsUnaligned", .Signature = @TypeOf(Cpu.trapsUnaligned), .why = "CCR.UNALIGN_TRP, which the access layer tests before it resolves" },
    .{ .name = "trapsDivideByZero", .Signature = @TypeOf(Cpu.trapsDivideByZero), .why = "CCR.DIV_0_TRP" },
    .{ .name = "defaultFpscr", .Signature = @TypeOf(Cpu.defaultFpscr), .why = "FPDSCR, the value an exception entry gives FPSCR" },
    .{ .name = "nonSecureFpscr", .Signature = @TypeOf(Cpu.nonSecureFpscr), .why = "the Non-secure FPDSCR, for a Secure call that clears the register file" },
    .{ .name = "automaticFpState", .Signature = @TypeOf(Cpu.automaticFpState), .why = "FPCCR.ASPEN, which decides whether an FP instruction stacks state" },
    .{ .name = "lazyFpEnabled", .Signature = @TypeOf(Cpu.lazyFpEnabled), .why = "FPCCR.LSPEN, which defers the FP half of an exception frame" },
    .{ .name = "lazyFpCallee", .Signature = @TypeOf(Cpu.lazyFpCallee), .why = "whether deferred state carries the callee registers" },
    .{ .name = "lazyFpFrame", .Signature = @TypeOf(Cpu.lazyFpFrame), .why = "FPCAR, where deferred state must be written before it is read" },
    .{ .name = "setLazyFp", .Signature = @TypeOf(Cpu.setLazyFp), .why = "records or clears the deferred frame the core owes" },
    .{ .name = "signal", .Signature = @TypeOf(Cpu.signal), .why = "supervisor call, exception return and function return" },
    .{ .name = "rearm", .Signature = @TypeOf(Cpu.rearm), .why = "a write to PRIMASK, BASEPRI or FAULTMASK changed what the core is due" },
    .{ .name = "sleep", .Signature = @TypeOf(Cpu.sleep), .why = "WFI and WFE" },
    .{ .name = "event", .Signature = @TypeOf(Cpu.event), .why = "SEV" },
    .{ .name = "bank", .Signature = @TypeOf(Cpu.bank), .why = "a write to CONTROL.SPSEL swaps which stack pointer is live", .optional = true },
    .{ .name = "alternate", .Signature = @TypeOf(Cpu.alternate), .why = "the other security state's banked registers, for MSP_NS and friends", .optional = true },
    .{ .name = "attribute", .Signature = @TypeOf(Cpu.attribute), .why = "what the SAU says an address is; returns core's Attribution", .optional = true },
    .{ .name = "accessible", .Signature = @TypeOf(Cpu.accessible), .why = "what the MPU lets TT report; returns core's Reach", .optional = true },
    .{ .name = "forceUnprivileged", .Signature = @TypeOf(Cpu.forceUnprivileged), .why = "the unprivileged loads and stores run one access as user code", .optional = true },
    .{ .name = "invalidState", .Signature = @TypeOf(Cpu.invalidState), .why = "a tail-predication fault is the one refusal the contract does not carry, so it is still announced", .optional = true },
};

pub const main = harness.consumer.Consumer(Machine).main;
