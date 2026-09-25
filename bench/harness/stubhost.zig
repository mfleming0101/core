const std = @import("std");
const core = @import("core");
const isa = @import("isa");
const consumer = @import("consumer.zig");
const contract = @import("contract.zig");
const facade = @import("facade.zig");
const snapshot = @import("snapshot.zig");

const Loaded = consumer.Loaded;
const Ran = facade.Ran;
const Snapshot = snapshot.Snapshot;
const Trap = snapshot.Trap;
const Stop = snapshot.Stop;

const Access = struct {
    kind: enum { fetch, read, write },
    bytes: u8,
};

const Failure = error{DataFault};

fn Memory(comptime Host: type) type {
    return struct {
        const Self = @This();

        bytes: []u8,
        base: u32,
        code_top: u32,
        code_gen: u32 = 0,

        pub fn span(self: *Self, address: u32, comptime a: Access) []u8 {
            const offset = address -% self.base;
            if (offset >= self.bytes.len) return &.{};
            if (a.kind == .write) self.wrote(address);
            return self.bytes[offset..];
        }

        fn wrote(self: *Self, address: u32) void {
            if (address >= self.code_top) return;
            self.code_gen +%= 1;
            if (comptime @hasDecl(Host, "onWrite")) Host.onWrite(address);
        }
    };
}

const Window = struct {
    bytes: []u8,
    code_top: u32,

    pub fn place(self: Window, address: u32, bytes: []const u8, span: usize) bool {
        if (bytes.len > span or @as(u64, address) + span > self.bytes.len) return false;
        @memcpy(self.bytes[address..][0..bytes.len], bytes);
        @memset(self.bytes[address + bytes.len ..][0 .. span - bytes.len], 0);
        return true;
    }
};

fn flatten(loaded: Loaded) !Window {
    var top: u64 = 0;
    var code_top: u32 = 0;
    for (loaded.map.regions) |region| {
        top = @max(top, @as(u64, region.base) + region.size);
        if (region.alias) |at| top = @max(top, @as(u64, at) + region.size);
        if (!region.writable) code_top = @max(code_top, region.base +| region.size);
    }
    const window: Window = .{ .bytes = try loaded.arena.alloc(u8, @intCast(top)), .code_top = code_top };
    @memset(window.bytes, 0);
    try core.memory.elf.load(loaded.elf, window);
    return window;
}

fn entryOf(elf: []const u8) u32 {
    return std.mem.readInt(u32, elf[24..28], .little);
}

fn resetSp(window: Window) u32 {
    if (window.bytes.len < 4) return 0;
    return std.mem.readInt(u32, window.bytes[0..4], .little);
}

fn flatCosts(comptime Costs: type) Costs {
    return @splat(.{ .cycles = 1, .taken = 0 });
}

fn wordAt(bus: anytype, address: u32) ?u32 {
    const bytes = bus.span(address, .{ .kind = .read, .bytes = 4 });
    if (bytes.len < 4) return null;
    return std.mem.readInt(u32, bytes[0..4], .little);
}

const empty_requirements: []const contract.Requirement = &.{};

pub const Arm = struct {
    const arch_step = isa.arm.step;
    const decode = isa.arm.decode;
    const spec = core.arm.spec(.m3);
    const gate = isa.arm.decode.selectionOf(spec.architecture).groups;

    pub const arch: facade.Arch = .armv7m;
    pub const result_register: u5 = 0;
    pub const isa_provides = empty_requirements;
    pub const table_bytes: u64 = 0;
    pub const processor_bytes: u64 = @sizeOf(Arm);

    state: isa.arm.State = .{},
    bus: Bus,

    pub const Bus = struct {
        pub const allowed = decode.selectionOf(spec.architecture).groups;

        memory: Memory(Arm),
        model: arch_step.Model,

        pub fn touch(_: *Bus, _: u32) void {}

        pub fn signal(_: *Bus, _: arch_step.Signal) void {}

        pub fn rearm(_: *Bus) void {}

        pub fn sleep(_: *Bus, _: arch_step.Wait) void {}

        pub fn event(_: *Bus) void {}

        pub fn architecture(_: *Bus) isa.arm.Architecture {
            return spec.architecture;
        }

        pub fn security(_: *Bus) bool {
            return spec.security;
        }

        pub fn pacbti(_: *Bus) bool {
            return spec.pacbti;
        }

        pub fn priorityBits(_: *Bus) u4 {
            return spec.priority_bits;
        }

        pub fn coprocessorEnabled(_: *Bus) bool {
            return false;
        }

        pub fn mve(_: *Bus) bool {
            return spec.mve;
        }

        pub fn doublePrecision(_: *Bus) bool {
            return spec.double_precision;
        }

        pub fn halfPrecision(_: *Bus) bool {
            return spec.half_precision;
        }

        pub fn fpv5(_: *Bus) bool {
            return spec.fpv5;
        }

        pub fn defaultFpscr(_: *Bus) u32 {
            return 0;
        }

        pub fn nonSecureFpscr(_: *Bus) u32 {
            return 0;
        }

        pub fn floatingPoint(_: *Bus) bool {
            return true;
        }

        pub fn treatAsSecure(_: *Bus) bool {
            return false;
        }

        pub fn automaticFpState(_: *Bus) bool {
            return false;
        }

        pub fn lazyFpEnabled(_: *Bus) bool {
            return false;
        }

        pub fn lazyFpCallee(_: *Bus) bool {
            return false;
        }

        pub fn lazyFpFrame(_: *Bus) ?u32 {
            return null;
        }

        pub fn setLazyFp(_: *Bus, _: ?u32) void {}

        pub fn trapsUnaligned(_: *Bus) bool {
            return spec.ccr & 1 << 3 != 0;
        }

        pub fn trapsDivideByZero(_: *Bus) bool {
            return spec.ccr & 1 << 4 != 0;
        }

        pub fn span(self: *Bus, address: u32, comptime a: Access) []u8 {
            return self.memory.span(address, a);
        }

        pub fn access(_: *Bus, _: u32, comptime _: Access, _: u32) Failure!u32 {
            return error.DataFault;
        }
    };

    pub fn init(loaded: Loaded) !Arm {
        const window = try flatten(loaded);
        var self: Arm = .{ .bus = .{
            .memory = .{ .bytes = window.bytes, .base = 0, .code_top = window.code_top },
            .model = .{ .decoding = decode.selectionOf(spec.architecture), .costs = flatCosts(arch_step.Model.Costs) },
        } };
        self.state.msp = resetSp(window) & ~@as(u32, 3);
        self.state.lr = facade.armv7m_reset.lr;
        self.state.xpsr = facade.armv7m_reset.xpsr;
        self.state.branchTo(entryOf(loaded.elf));
        return self;
    }

    pub fn run(self: *Arm, budget: u64) Ran {
        const model = self.bus.model;
        var retired: u64 = 0;
        while (retired < budget) {
            const result = @call(.always_inline, arch_step.step, .{ Bus, gate, &self.state, &self.bus, model });
            if (stopOf(result)) |stop| return .{ .retired = retired, .cycles = retired, .stop = stop };
            retired += 1;
        }
        return .{ .retired = retired, .cycles = retired, .stop = .budget };
    }

    pub fn step(self: *Arm) Ran {
        const result = arch_step.step(Bus, gate, &self.state, &self.bus, self.bus.model);
        if (stopOf(result)) |stop| return .{ .stop = stop };
        return .{ .retired = 1, .cycles = 1 };
    }

    pub fn burst(self: *Arm, budget: u64, cycles: u64) Ran {
        return run(self, @min(budget, cycles));
    }

    fn stopOf(result: arch_step.Result) ?Stop {
        if (!result.halted) return null;
        return switch (result.stop) {
            .breakpoint => .breakpoint,
            .fetch_fault, .fetch_violation => .fetch_fault,
            .data_fault, .data_violation, .secure_fault, .unrecoverable_exception => .data_fault,
            .unaligned_access => .unaligned,
            else => .undefined_instruction,
        };
    }

    pub fn snapshot(self: *const Arm) Snapshot {
        var out: Snapshot = .{ .pc = self.state.pc, .flags = self.state.xpsr };
        @memcpy(out.regs[0..13], &self.state.r);
        out.regs[13] = self.state.sp();
        out.regs[14] = self.state.lr;
        out.regs[15] = self.state.pc;
        return out;
    }

    pub fn trap(_: *const Arm) Trap {
        return .{};
    }

    pub fn clock(_: *const Arm) *const u64 {
        return &still;
    }

    pub fn read32(self: *Arm, address: u32) ?u32 {
        return wordAt(&self.bus, address);
    }

    pub fn explain(_: *Arm, into: []u8) []const u8 {
        return into[0..0];
    }
};

const still: u64 = 0;

pub const Riscv = struct {
    const arch_step = isa.riscv.step;
    const spec = core.riscv.spec(.esp32c3);
    const gate = spec.groups;

    pub const arch: facade.Arch = .rv32imc;
    pub const result_register: u5 = 10;
    pub const isa_provides = empty_requirements;
    pub const table_bytes: u64 = 0;
    pub const processor_bytes: u64 = @sizeOf(Riscv);

    state: isa.riscv.State = .{},
    bus: Bus,
    model: arch_step.Model,

    pub const Bus = struct {
        pub const allowed = spec.groups;

        memory: Memory(Riscv),

        pub fn touch(_: *Bus, _: u32) void {}

        pub fn readPmp(_: *Bus, _: isa.riscv.csr.Protection) u32 {
            return 0;
        }

        pub fn writePmp(_: *Bus, _: isa.riscv.csr.Protection, _: u32) void {}

        pub fn rearm(_: *Bus) void {}

        pub fn returned(_: *Bus) void {}

        pub fn sleep(_: *Bus) void {}

        pub fn span(self: *Bus, address: u32, comptime a: Access) []u8 {
            return self.memory.span(address, a);
        }

        pub fn access(_: *Bus, _: u32, comptime _: Access, _: u32) Failure!u32 {
            return error.DataFault;
        }
    };

    pub fn init(loaded: Loaded) !Riscv {
        const window = try flatten(loaded);
        var self: Riscv = .{
            .bus = .{ .memory = .{ .bytes = window.bytes, .base = 0, .code_top = window.code_top } },
            .model = .{ .decoding = Bus.allowed, .costs = flatCosts(arch_step.Model.Costs) },
        };
        self.state.pc = entryOf(loaded.elf);
        return self;
    }

    pub fn run(self: *Riscv, budget: u64) Ran {
        const model = self.model;
        var retired: u64 = 0;
        while (retired < budget) {
            const result = @call(.always_inline, arch_step.step, .{ Bus, gate, &self.state, &self.bus, model });
            if (stopOf(result)) |stop| return .{ .retired = retired, .cycles = retired, .stop = stop };
            retired += 1;
        }
        return .{ .retired = retired, .cycles = retired, .stop = .budget };
    }

    pub fn step(self: *Riscv) Ran {
        const result = arch_step.step(Bus, gate, &self.state, &self.bus, self.model);
        if (stopOf(result)) |stop| return .{ .stop = stop };
        return .{ .retired = 1, .cycles = 1 };
    }

    pub fn burst(self: *Riscv, budget: u64, cycles: u64) Ran {
        return run(self, @min(budget, cycles));
    }

    fn stopOf(result: arch_step.Result) ?Stop {
        if (result.trap != .none) return switch (result.trap) {
            .none => unreachable,
            .instruction_access_fault => .fetch_fault,
            .illegal_instruction => .undefined_instruction,
            .load_access_fault, .store_access_fault => .data_fault,
            .environment_call => .exited,
        };
        if (!result.halted) return null;
        return switch (result.stop) {
            .breakpoint => .breakpoint,
            .unimplemented => .undefined_instruction,
            .unrecoverable_trap => .data_fault,
        };
    }

    pub fn snapshot(self: *const Riscv) Snapshot {
        return .{ .regs = self.state.x, .pc = self.state.pc };
    }

    pub fn trap(_: *const Riscv) Trap {
        return .{};
    }

    pub fn clock(_: *const Riscv) *const u64 {
        return &still;
    }

    pub fn read32(self: *Riscv, address: u32) ?u32 {
        return wordAt(&self.bus, address);
    }

    pub fn explain(_: *Riscv, into: []u8) []const u8 {
        return into[0..0];
    }
};
