const std = @import("std");
const core = @import("core");
const harness = @import("harness");

const Loaded = harness.consumer.Loaded;
const Ran = harness.facade.Ran;
const Snapshot = harness.snapshot.Snapshot;
const Stop = harness.snapshot.Stop;

const which: core.riscv.Core = @field(core.riscv.Core, @import("rep").riscv);
const Cpu = core.riscv.Processor(.{ .cores = &.{which}, .Bus = core.memory.Regions });

pub const Machine = struct {
    pub const arch: harness.facade.Arch = .rv32imc;
    pub const result_register: u5 = 10;
    pub const isa_provides: []const harness.contract.Requirement = &isa_requirements;

    pub const table_bytes: u64 = @sizeOf(core.memory.Regions);

    pub const processor_bytes: u64 = @sizeOf(Machine);

    cpu: Cpu,
    event: u16 = 0,
    console: ?*std.Io.Writer,

    pub fn init(loaded: Loaded) !Machine {
        var self: Machine = .{
            .cpu = Cpu.init(try harness.consumer.bus(loaded), which, try .init(try loaded.arena.alloc(core.riscv.trace.Record, loaded.history))),
            .console = loaded.console,
        };
        self.cpu.state.pc = harness.consumer.entryOf(loaded.elf);
        if (self.cpu.trace.recording()) self.cpu.last = core.riscv.trace.snapshot(&self.cpu.state);
        return self;
    }

    pub fn run(self: *Machine, budget: u64) Ran {
        return self.until(budget, std.math.maxInt(u64), .budget);
    }

    pub fn step(self: *Machine) Ran {
        const before = self.work();
        const returns = self.cpu.returns;
        const one = self.cpu.step();
        if (one.asleep) self.cpu.charge(1);
        const entered = one.class == null and one.stop == null and !one.asleep;
        self.event = (if (self.cpu.returns != returns) @as(u16, 1) << 15 else 0) |
            (if (entered) @as(u16, 1) << 14 else 0);
        const after = self.work();
        return .{
            .retired = @intFromBool(one.class != null),
            .cycles = after.cycles - before.cycles,
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

    fn work(self: *const Machine) struct { cycles: u64, exceptions: u64, irqs: u64 } {
        return .{ .cycles = self.cpu.cycles, .exceptions = self.cpu.exceptions, .irqs = self.cpu.irqs };
    }

    fn serviced(self: *Machine) bool {
        const console = self.console orelse return false;
        if (!Cpu.semihosting.trapped(&self.cpu)) return false;
        const exited = Cpu.semihosting.call(&self.cpu, console) catch return false;
        return exited == null;
    }

    pub fn snapshot(self: *const Machine) Snapshot {
        const cause = self.cpu.state.csr.mcause;
        return .{
            .regs = self.cpu.state.x,
            .pc = self.cpu.state.pc,
            .flags = self.cpu.state.csr.read(.mstatus),
            .retired = self.cpu.instructions,
            .cycles = self.cpu.cycles,
            .pending_lo = self.cpu.intc.pending(),
            .stop = if (self.cpu.stop) |stop| stopOf(stop) else .running,
            .exception = if (cause >> 31 != 0) @truncate(cause & 0x1f) else 0,
        };
    }

    pub fn trap(self: *const Machine) harness.snapshot.Trap {
        return .{
            .cause = self.cpu.state.csr.mcause,
            .epc = self.cpu.state.csr.mepc,
            .tval = self.cpu.state.csr.mtval,
            .event = self.event,
        };
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

    fn stopOf(stop: core.riscv.Stop) Stop {
        return switch (stop) {
            .breakpoint => .breakpoint,
            .unimplemented => .undefined_instruction,
            .unrecoverable_trap => .data_fault,
        };
    }
};

const isa_requirements = [_]harness.contract.Requirement{
    .{ .name = "span", .Signature = @TypeOf(Cpu.span), .why = "one lookup answers the whole per-access question: whether the PMP permits it (Privileged 3.7), whether the address is a controller register or a device, and which host bytes back it, returning the span from the address to the end of the answer so both parcels of one instruction are fetched once" },
    .{ .name = "access", .Signature = @TypeOf(Cpu.access), .why = "the controller and device lane, reached only where span answered a span shorter than the access, so no access site tests intc.region on the fast path; the fault is its return value rather than a refusal the caller interprets" },
    .{ .name = "touch", .Signature = @TypeOf(Cpu.touch), .why = "the address of every data access, which mtval names on a refusal or a misaligned address, Privileged 3.1.16, and which the trace line prints" },
    .{ .name = "allowed", .Signature = @TypeOf(Cpu.allowed), .why = "comptime group word; selects which rows the decode tables hold" },
    .{ .name = "readPmp", .Signature = @TypeOf(Cpu.readPmp), .why = "a CSR read of a protection register, which the hart does not hold" },
    .{ .name = "writePmp", .Signature = @TypeOf(Cpu.writePmp), .why = "a CSR write of a protection register, which reprograms the unit" },
    .{ .name = "rearm", .Signature = @TypeOf(Cpu.rearm), .why = "a write to mstatus or mie changed what the hart is due" },
    .{ .name = "returned", .Signature = @TypeOf(Cpu.returned), .why = "an MRET changed the privilege, the guard word and the pending state" },
    .{ .name = "sleep", .Signature = @TypeOf(Cpu.sleep), .why = "WFI" },
};

pub const main = harness.consumer.Consumer(Machine).main;
