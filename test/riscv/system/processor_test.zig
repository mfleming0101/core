const std = @import("std");
const Word = @import("../../../src/contract.zig").Word;
const riscv = @import("../../../src/riscv/root.zig");
const every: []const riscv.Core = std.enums.values(riscv.Core);
const csr = @import("isa").riscv.csr;
const Class = @import("isa").riscv.instruction.Class;

const flash_base = riscv.spec(.esp32c3).flat.flash_base;
const ram_base = riscv.spec(.esp32c3).flat.ram_base;

const Memory = struct {
    flash: [64]u8 = @splat(0),
    ram: [64]u8 = @splat(0),
    folded: regions.Folded = .{},

    pub fn lookup(self: *Memory, address: u32) regions.Found {
        if (address -% flash_base < self.flash.len) return .{ .base = flash_base, .len = self.flash.len, .host = &self.flash };
        if (address -% ram_base < self.ram.len) return .{ .base = ram_base, .len = self.ram.len, .host = &self.ram, .writable = true };
        return .{ .base = address, .len = 1 };
    }

    fn readable(self: *Memory, address: u32, comptime n: usize) ?*[n]u8 {
        const offset = address -% flash_base;
        if (@as(u64, offset) + n <= self.flash.len) return self.flash[offset..][0..n];
        return self.writable(address, n);
    }

    fn writable(self: *Memory, address: u32, comptime n: usize) ?*[n]u8 {
        const offset = address -% ram_base;
        if (@as(u64, offset) + n <= self.ram.len) return self.ram[offset..][0..n];
        return null;
    }

    fn program(self: *Memory, words: []const u32) void {
        for (words, 0..) |word, i| std.mem.writeInt(u32, self.flash[i * 4 ..][0..4], word, .little);
    }

    fn parcels(self: *Memory, halves: []const u16) void {
        for (halves, 0..) |half, i| std.mem.writeInt(u16, self.flash[i * 2 ..][0..2], half, .little);
    }

    fn handler(self: *Memory, words: []const u32) void {
        for (words, 0..) |word, i| std.mem.writeInt(u32, self.ram[i * 4 ..][0..4], word, .little);
    }

    pub fn peek(self: *Memory, comptime width: u8, address: u32) ?Word(width) {
        return std.mem.readInt(Word(width), self.readable(address, width) orelse return null, .little);
    }

    pub fn poke(self: *Memory, comptime width: u8, address: u32, value: Word(width)) ?void {
        std.mem.writeInt(Word(width), self.writable(address, width) orelse return null, value, .little);
    }

    pub fn parcel(self: *Memory, address: u32) ?u16 {
        return self.peek(2, address);
    }

    pub fn interrupts(_: *Memory) ?regions.Lines {
        return null;
    }

    pub fn asserted(_: *const Memory) regions.Lines {
        return 0;
    }

    pub fn follow(_: *Memory, _: *const u64, _: *u64) void {}

    pub fn untilDue(_: *const Memory) u64 {
        return std.math.maxInt(u64);
    }
};

const Cpu = riscv.Processor(.{ .cores = every, .Bus = Memory });

var ring: [64]riscv.trace.Record = undefined;
var explanation: [512]u8 = undefined;

const li_a0_5: u32 = 0x0050_0513;
const lui_a1_ram: u32 = 0x3fc8_05b7;
const sw_a0_a1: u32 = 0x00a5_a023;
const sw_a0_a1_one: u32 = 0x00a5_a0a3;
const lw_a2_a1: u32 = 0x0005_a603;
const lw_a2_a1_far: u32 = 0x0205_a603;
const ebreak: u32 = 0x0010_0073;
const ecall: u32 = 0x0000_0073;
const c_li_a0_5: u16 = 0x4515;
const c_add_a0_a1: u16 = 0x952e;
const c_ebreak: u16 = 0x9002;

const csrr_t0_mepc: u32 = 0x3410_22f3;
const csrw_mepc_t0: u32 = 0x3412_9073;
const csrr_t0_mstatus: u32 = 0x3000_22f3;
const addi_t0_t0_4: u32 = 0x0042_8293;
const mret: u32 = 0x3020_0073;
const wfi: u32 = 0x1050_0073;
const illegal: u32 = 0x0000_0000;
const c_illegal: u16 = 0x0000;

const resuming_handler = [_]u32{ csrr_t0_mepc, addi_t0_t0_4, csrw_mepc_t0, mret };

fn grantFlash(cpu: *Cpu) void {
    cpu.pmp.addr[0] = (flash_base >> 2) | ((4 * 1024 * 1024 >> 3) - 1);
    cpu.pmp.cfg[0] = .{ .r = true, .x = true, .mode = .napot };
    cpu.reguard();
}

fn started(memory: *Memory, records: []riscv.trace.Record) Cpu {
    var cpu = Cpu.init(memory, .esp32c3, riscv.trace.Ring.init(records) catch unreachable);
    cpu.reset();
    return cpu;
}

test "reset leaves the program counter in the flash window a raw image runs from, C3 TRM 3.3" {
    var memory: Memory = .{};
    const cpu = started(&memory, &.{});
    try std.testing.expectEqual(flash_base, cpu.state.pc);
    try std.testing.expectEqual(@as(u64, 0), cpu.instructions);
    try std.testing.expectEqual(@as(?riscv.Stop, null), cpu.stop);
}

test "the run loop counts what it executed and stops at EBREAK, Unprivileged 2.8" {
    var memory: Memory = .{};
    memory.program(&.{ li_a0_5, ebreak });
    var cpu = started(&memory, &.{});
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(@as(u64, 1), ran.instructions);
    try std.testing.expectEqual(@as(u64, 1), ran.cycles);
    try std.testing.expectEqual(@as(u32, 5), cpu.state.x[10]);
    try std.testing.expectEqual(flash_base + 4, cpu.state.pc);
}

test "a run stops at the chip's deadline, one with no cycles to spend retires nothing, and the span after it carries on from there" {
    var memory: Memory = .{};
    memory.program(&.{ nop, nop, nop, nop, nop, nop, ebreak });
    var cpu = started(&memory, &.{});
    try std.testing.expectEqual(riscv.Run{ .instructions = 0, .cycles = 0, .stop = null, .ended = .deadline }, cpu.run(.{ .instructions = 100, .cycles = 0 }));
    try std.testing.expectEqual(riscv.Run{ .instructions = 4, .cycles = 4, .stop = null, .ended = .deadline }, cpu.run(.{ .instructions = 100, .cycles = 4 }));
    try std.testing.expectEqual(riscv.Run{ .instructions = 2, .cycles = 2, .stop = .breakpoint, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
}

test "a step reports the class and the address of the instruction it ran, and charges the hart the one cycle it cost" {
    var memory: Memory = .{};
    memory.program(&.{ li_a0_5, ebreak });
    var cpu = started(&memory, &.{});
    try std.testing.expectEqual(riscv.Step{ .address = flash_base, .class = .data_processing, .cost = null, .charged = 1, .sequential = false, .asleep = false, .stop = null }, cpu.step());
    try std.testing.expectEqual(@as(u64, 1), cpu.instructions);
    try std.testing.expectEqual(@as(u64, 1), cpu.cycles);
}

test "a step reports no cycle count on either part, because neither TRM publishes a cycle table" {
    for ([_]riscv.Core{ .esp32c3, .esp32c6 }) |c| {
        var memory: Memory = .{};
        memory.program(&.{ li_a0_5, ebreak });
        var cpu = startedAs(&memory, c, &.{});
        const ran = cpu.step();
        try std.testing.expectEqual(@as(?Class, .data_processing), ran.class);
        try std.testing.expectEqual(@as(?u8, null), ran.cost);
    }
}

test "a step whose fetch follows the instruction before it is sequential, and the one after a taken jump is not" {
    var memory: Memory = .{};
    memory.program(&.{ li_a0_5, jal(0, 8), ebreak, li_a0_5, ebreak });
    var cpu = started(&memory, &.{});
    try std.testing.expect(!cpu.step().sequential);
    const jump = cpu.step();
    try std.testing.expectEqual(@as(?Class, .jump), jump.class);
    try std.testing.expect(jump.sequential);
    const target = cpu.step();
    try std.testing.expectEqual(flash_base + 12, target.address);
    try std.testing.expect(!target.sequential);
}

test "the step that enters a trap handler retires no instruction and charges nothing, because this family models no entry latency, Privileged 3.1.6.1" {
    var memory: Memory = .{};
    memory.program(&.{ li_a0_5, ecall, li_a0_5 });
    memory.handler(&.{ebreak});
    var cpu = started(&memory, &.{});
    cpu.state.csr.mtvec = ram_base | 1;
    try std.testing.expectEqual(@as(?Class, .data_processing), cpu.step().class);
    const entry = cpu.step();
    try std.testing.expectEqual(@as(?Class, null), entry.class);
    try std.testing.expectEqual(@as(?u8, null), entry.cost);
    try std.testing.expectEqual(@as(u8, 0), entry.charged);
    try std.testing.expectEqual(@as(u64, 1), cpu.instructions);
    try std.testing.expectEqual(@as(u64, 1), cpu.cycles);
    try std.testing.expectEqual(ram_base, cpu.state.pc);
}

test "a run of zero instructions executes nothing, reports no stop of its own and leaves the standing breakpoint in place" {
    var memory: Memory = .{};
    memory.program(&.{ ebreak, li_a0_5, ebreak });
    var cpu = started(&memory, &.{});
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(riscv.Run{ .instructions = 0, .cycles = 0, .stop = null, .ended = .budget }, cpu.run(.{ .instructions = 0 }));
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.stop);
    try std.testing.expectEqual(flash_base, cpu.state.pc);
}

test "a run whose cycle deadline is already reached executes nothing and leaves the standing breakpoint in place" {
    var memory: Memory = .{};
    memory.program(&.{ ebreak, li_a0_5, ebreak });
    var cpu = started(&memory, &.{});
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(riscv.Run{ .instructions = 0, .cycles = 0, .stop = null, .ended = .deadline }, cpu.run(.{ .instructions = 100, .cycles = 0 }));
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.stop);
    try std.testing.expectEqual(flash_base, cpu.state.pc);
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(flash_base + 8, cpu.state.pc);
}

test "a run that begins on the breakpoint it stopped at steps over it" {
    var memory: Memory = .{};
    memory.program(&.{ ebreak, li_a0_5, ebreak });
    var cpu = started(&memory, &.{});
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 5), cpu.state.x[10]);
    try std.testing.expectEqual(flash_base + 8, cpu.state.pc);
}

test "a compressed instruction advances the program counter by two, and a run that stops on C.EBREAK steps over two bytes, Unprivileged 28.1 and 28.5.6" {
    var memory: Memory = .{};
    memory.parcels(&.{ c_li_a0_5, c_ebreak, c_add_a0_a1, c_ebreak });
    var cpu = started(&memory, &.{});
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(@as(u64, 1), ran.instructions);
    try std.testing.expectEqual(@as(u32, 5), cpu.state.x[10]);
    try std.testing.expectEqual(flash_base + 2, cpu.state.pc);
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 5), cpu.state.x[10]);
    try std.testing.expectEqual(flash_base + 6, cpu.state.pc);
}

test "reset leaves the hart in machine mode with the CSRs at the values the TRM's reset column gives them, C3 TRM 1.4.2" {
    var memory: Memory = .{};
    const cpu = started(&memory, &.{});
    try std.testing.expectEqual(csr.Privilege.machine, cpu.state.privilege);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(cpu.state.csr.mstatus)));
    try std.testing.expectEqual(@as(u32, 1), cpu.state.csr.mtvec);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.csr.mcause);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.csr.mepc);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.csr.mtval);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.csr.mscratch);
}

test "an ECALL from machine mode enters the handler with mcause 11, mepc on the ECALL and mtval zero, C3 TRM Register 1.10" {
    var memory: Memory = .{};
    memory.program(&.{ li_a0_5, ecall, li_a0_5 });
    memory.handler(&.{ebreak});
    var cpu = started(&memory, &.{});
    cpu.state.csr.mtvec = ram_base | 1;
    cpu.state.csr.mstatus.mie = true;
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(@as(u64, 1), ran.instructions);
    try std.testing.expectEqual(ram_base, cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 11), cpu.state.csr.mcause);
    try std.testing.expectEqual(flash_base + 4, cpu.state.csr.mepc);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.csr.mtval);
    try std.testing.expect(!cpu.state.csr.mstatus.mie);
    try std.testing.expect(cpu.state.csr.mstatus.mpie);
    try std.testing.expectEqual(csr.Privilege.machine, cpu.state.csr.mstatus.mpp);
    try std.testing.expectEqual(csr.Privilege.machine, cpu.state.privilege);
}

test "the handler steps mepc over the ECALL and MRET resumes the instruction after it, restoring MIE from MPIE and setting MPIE, Privileged 3.1.6.1" {
    var memory: Memory = .{};
    memory.program(&.{ li_a0_5, ecall, sw_a0_a1, ebreak });
    memory.handler(&resuming_handler);
    var cpu = started(&memory, &.{});
    cpu.state.csr.mtvec = ram_base | 1;
    cpu.state.csr.mstatus.mie = true;
    cpu.state.x[11] = ram_base + 32;
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(flash_base + 12, cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 5), memory.peek(4, ram_base + 32).?);
    try std.testing.expect(cpu.state.csr.mstatus.mie);
    try std.testing.expect(cpu.state.csr.mstatus.mpie);
    try std.testing.expectEqual(csr.Privilege.user, cpu.state.csr.mstatus.mpp);
    try std.testing.expectEqual(csr.Privilege.machine, cpu.state.privilege);
}

test "an ECALL from the user mode an MRET left the hart in is code 8 rather than code 11, C3 TRM Register 1.10" {
    var memory: Memory = .{};
    memory.program(&.{ mret, ecall });
    memory.handler(&.{ebreak});
    var cpu = started(&memory, &.{});
    grantFlash(&cpu);
    cpu.state.csr.mtvec = ram_base | 1;
    cpu.state.csr.mepc = flash_base + 4;
    cpu.state.csr.mstatus.mpp = .user;
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 8), cpu.state.csr.mcause);
    try std.testing.expectEqual(flash_base + 4, cpu.state.csr.mepc);
    try std.testing.expectEqual(csr.Privilege.machine, cpu.state.privilege);
    try std.testing.expectEqual(csr.Privilege.user, cpu.state.csr.mstatus.mpp);
}

test "a CSR read from the user mode an MRET left the hart in is an illegal instruction, with the instruction in mtval, Privileged 2.1" {
    var memory: Memory = .{};
    memory.program(&.{ mret, csrr_t0_mstatus });
    memory.handler(&.{ebreak});
    var cpu = started(&memory, &.{});
    grantFlash(&cpu);
    cpu.state.csr.mtvec = ram_base | 1;
    cpu.state.csr.mepc = flash_base + 4;
    cpu.state.csr.mstatus.mpp = .user;
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 2), cpu.state.csr.mcause);
    try std.testing.expectEqual(csrr_t0_mstatus, cpu.state.csr.mtval);
    try std.testing.expectEqual(flash_base + 4, cpu.state.csr.mepc);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.x[5]);
}

test "an instruction fetch no memory answers is an instruction access fault, with the address it could not reach in mtval, C3 TRM Register 1.11" {
    var memory: Memory = .{};
    memory.handler(&.{ebreak});
    var cpu = started(&memory, &ring);
    cpu.state.csr.mtvec = ram_base | 1;
    cpu.state.pc = 0x1000;
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 1), cpu.state.csr.mcause);
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.state.csr.mepc);
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.state.csr.mtval);
    try std.testing.expectEqual(@as(?u32, null), cpu.trace.at(1).?.codeOf());
}

test "a fetch fault on the second parcel of a 32-bit instruction leaves that parcel's address in mtval and the instruction's in mepc, Privileged 3.1.16" {
    var memory: Memory = .{};
    std.mem.writeInt(u16, memory.flash[62..64], 0x0013, .little);
    memory.handler(&.{ebreak});
    var cpu = started(&memory, &.{});
    cpu.state.csr.mtvec = ram_base | 1;
    cpu.state.pc = flash_base + 62;
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 1), cpu.state.csr.mcause);
    try std.testing.expectEqual(flash_base + 62, cpu.state.csr.mepc);
    try std.testing.expectEqual(flash_base + 64, cpu.state.csr.mtval);
}

test "a code no row matches is an illegal instruction, and mtval holds the instruction, four digits wide for a compressed parcel, Privileged 3.1.16" {
    var memory: Memory = .{};
    memory.program(&.{illegal});
    memory.handler(&.{ebreak});
    var cpu = started(&memory, &.{});
    cpu.state.csr.mtvec = ram_base | 1;
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 2), cpu.state.csr.mcause);
    try std.testing.expectEqual(flash_base, cpu.state.csr.mepc);
    try std.testing.expectEqual(illegal, cpu.state.csr.mtval);

    var narrow: Memory = .{};
    narrow.parcels(&.{ 0x4515, c_illegal });
    narrow.handler(&.{ebreak});
    var second = started(&narrow, &.{});
    second.state.csr.mtvec = ram_base | 1;
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), second.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 2), second.state.csr.mcause);
    try std.testing.expectEqual(flash_base + 2, second.state.csr.mepc);
    try std.testing.expectEqual(@as(u32, c_illegal), second.state.csr.mtval);
}

test "a trap with mtvec at its reset value locks the core, because the handler at the base cannot be fetched" {
    var memory: Memory = .{};
    memory.program(&.{ ecall, li_a0_5 });
    var cpu = started(&memory, &ring);
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?riscv.Stop, .unrecoverable_trap), ran.stop);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 11), cpu.state.csr.mcause);
    try std.testing.expectEqual(flash_base, cpu.state.csr.mepc);
    const again = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?riscv.Stop, .unrecoverable_trap), again.stop);
    try std.testing.expectEqual(@as(u64, 0), again.instructions);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.x[10]);

    var w: std.Io.Writer = .fixed(&explanation);
    try cpu.explain(&w, 0);
    try std.testing.expectEqualStrings(
        \\The trap handler at pc=00000000 could not be fetched, and mtvec has nowhere else to send a trap. The core locked up.
        \\The hart took a trap at pc=00000000: instruction access fault fetching 00000000.
        \\mtvec=00000001 mcause=0000000b mepc=42000000 mtval=00000000
        \\
    , w.buffered());
}

test "a trap raised by the first instruction of the handler itself locks the core rather than taking it for ever" {
    var memory: Memory = .{};
    memory.program(&.{ecall});
    memory.handler(&.{illegal});
    var cpu = started(&memory, &ring);
    cpu.state.csr.mtvec = ram_base | 1;
    try std.testing.expectEqual(@as(?riscv.Stop, .unrecoverable_trap), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(ram_base, cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 11), cpu.state.csr.mcause);

    var w: std.Io.Writer = .fixed(&explanation);
    try cpu.explain(&w, 0);
    try std.testing.expectEqualStrings(
        \\The code 00000000 at pc=3fc80000 is the first instruction of the trap handler and it trapped, so the hart would take that trap for ever. The core locked up.
        \\The hart took a trap at pc=3fc80000: illegal instruction on the code 0000.
        \\mtvec=3fc80001 mcause=0000000b mepc=42000000 mtval=00000000
        \\
    , w.buffered());
}

test "a trap a user-mode instruction raised at the mtvec base enters the handler rather than locking the core, Privileged 3.1.6.1" {
    var memory: Memory = .{};
    memory.program(&.{mret});
    memory.handler(&.{ebreak});
    var cpu = started(&memory, &.{});
    cpu.state.csr.mtvec = ram_base | 1;
    grantFlash(&cpu);
    cpu.state.csr.mepc = ram_base;
    cpu.state.csr.mstatus.mpp = .user;
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 1), cpu.state.csr.mcause);
    try std.testing.expectEqual(ram_base, cpu.state.csr.mepc);
    try std.testing.expectEqual(csr.Privilege.machine, cpu.state.privilege);
    try std.testing.expectEqual(csr.Privilege.user, cpu.state.csr.mstatus.mpp);
}

test "WFI retires and does nothing where the memory it runs in can raise no interrupt at all, Privileged 3.3.3" {
    var memory: Memory = .{};
    memory.program(&.{ wfi, li_a0_5, ebreak });
    var cpu = started(&memory, &.{});
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(@as(u64, 2), ran.instructions);
    try std.testing.expectEqual(@as(u32, 5), cpu.state.x[10]);
}

test "a store and a load through the data window reach the memory and the trace records the address" {
    var memory: Memory = .{};
    memory.program(&.{ li_a0_5, lui_a1_ram, sw_a0_a1, lw_a2_a1, ebreak });
    var cpu = started(&memory, &ring);
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(@as(u64, 4), ran.instructions);
    try std.testing.expectEqual(@as(u64, 4), ran.cycles);
    try std.testing.expectEqual(@as(u32, 5), cpu.state.x[12]);
    try std.testing.expectEqual(@as(u32, 5), memory.peek(4, ram_base).?);
    try std.testing.expectEqual(@as(?u32, ram_base), cpu.trace.at(1).?.access);
}

test "a store whose address is not a multiple of its size is a store access fault, since this part's mcause table has no code 6, C3 TRM Register 1.10 and C3 TRM 3.3.1" {
    var memory: Memory = .{};
    memory.program(&.{ li_a0_5, lui_a1_ram, sw_a0_a1_one, ebreak });
    memory.handler(&.{ebreak});
    var cpu = started(&memory, &ring);
    cpu.state.csr.mtvec = ram_base | 1;
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 7), cpu.state.csr.mcause);
    try std.testing.expectEqual(flash_base + 8, cpu.state.csr.mepc);
    try std.testing.expectEqual(ram_base + 1, cpu.state.csr.mtval);
    try std.testing.expectEqual(@as(?u32, ram_base + 1), cpu.trace.at(2).?.access);
}

test "a load no memory answers is a load access fault and a store none answers is a store access fault, Privileged 3.1.15" {
    var memory: Memory = .{};
    memory.program(&.{ lw_a2_a1, ebreak });
    memory.handler(&.{ebreak});
    var cpu = started(&memory, &ring);
    cpu.state.csr.mtvec = ram_base | 1;
    cpu.state.x[11] = 0x1000;
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 5), cpu.state.csr.mcause);
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.state.csr.mtval);

    var second: Memory = .{};
    second.program(&.{ sw_a0_a1, ebreak });
    second.handler(&.{ebreak});
    var store = started(&second, &ring);
    store.state.csr.mtvec = ram_base | 1;
    store.state.x[11] = 0x1000;
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), store.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 7), store.state.csr.mcause);
    try std.testing.expectEqual(@as(u32, 0x1000), store.state.csr.mtval);
}

test "user mode runs inside the region an entry grants it and faults on the first access outside it, C3 TRM 1.8.3" {
    var memory: Memory = .{};
    memory.program(&.{ mret, lw_a2_a1, lw_a2_a1_far });
    memory.handler(&.{ebreak});
    var cpu = started(&memory, &.{});
    grantFlash(&cpu);
    cpu.pmp.addr[1] = (ram_base >> 2) | 1;
    cpu.pmp.cfg[1] = .{ .r = true, .w = true, .mode = .napot };
    cpu.reguard();
    cpu.state.csr.mtvec = ram_base | 1;
    cpu.state.csr.mepc = flash_base + 4;
    cpu.state.csr.mstatus.mpp = .user;
    cpu.state.x[11] = ram_base + 8;
    _ = memory.poke(4, ram_base + 8, 0x0bad_c0de);
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 0x0bad_c0de), cpu.state.x[12]);
    try std.testing.expectEqual(@as(u32, 5), cpu.state.csr.mcause);
    try std.testing.expectEqual(ram_base + 40, cpu.state.csr.mtval);
    try std.testing.expectEqual(flash_base + 8, cpu.state.csr.mepc);
}

test "the handler a user-mode fault enters runs in machine mode, so it reaches the memory the access that faulted could not, Privileged 3.7.1.3" {
    var memory: Memory = .{};
    memory.program(&.{ mret, sw_a0_a1 });
    memory.handler(&.{ sw_a0_a1, ebreak });
    var cpu = started(&memory, &.{});
    grantFlash(&cpu);
    cpu.state.csr.mtvec = ram_base | 1;
    cpu.state.csr.mepc = flash_base + 4;
    cpu.state.csr.mstatus.mpp = .user;
    cpu.state.x[10] = 5;
    cpu.state.x[11] = ram_base + 32;
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 7), cpu.state.csr.mcause);
    try std.testing.expectEqual(ram_base + 32, cpu.state.csr.mtval);
    try std.testing.expectEqual(csr.Privilege.machine, cpu.state.privilege);
    try std.testing.expectEqual(@as(u32, 5), memory.peek(4, ram_base + 32).?);
}

test "the run stops at its instruction limit without a stop reason" {
    var memory: Memory = .{};
    memory.program(&.{ li_a0_5, li_a0_5, li_a0_5, ebreak });
    var cpu = started(&memory, &.{});
    const ran = cpu.run(.{ .instructions = 2 });
    try std.testing.expectEqual(@as(?riscv.Stop, null), ran.stop);
    try std.testing.expectEqual(@as(u64, 2), ran.instructions);
    try std.testing.expectEqual(flash_base + 8, cpu.state.pc);
}

const regions = @import("../../../src/memory/regions.zig");
const Regions = regions.Regions;
const Width = regions.Width;
const Lines = regions.Lines;
const intc = @import("../../../src/riscv/system/intc.zig");

const Board = riscv.Processor(.{ .cores = every, .Bus = Regions });

const sw_intr_0: u32 = 50;
const sw_intr_1: u32 = 51;
const doorbell_base: u32 = 0x600c_0000;
const doorbell_at: u32 = doorbell_base + 0x28;

const vectors: u32 = flash_base + 0x100;
const handler_at: u32 = flash_base + 0x180;

const Doorbell = struct {
    lines: Lines = 0,

    fn sourceOf(offset: u32) Lines {
        return @as(Lines, 1) << @intCast(sw_intr_0 + (offset - 0x28) / 4);
    }

    fn read(context: *anyopaque, offset: u32, _: Width, _: *Lines) ?u32 {
        const self: *Doorbell = @ptrCast(@alignCast(context));
        return @intFromBool(self.lines & sourceOf(offset) != 0);
    }

    fn write(context: *anyopaque, offset: u32, _: Width, value: u32, raise: *Lines) ?void {
        const self: *Doorbell = @ptrCast(@alignCast(context));
        const source = sourceOf(offset);
        if (value == 0) {
            self.lines &= ~source;
            return;
        }
        self.lines |= source;
        raise.* |= source;
    }

    fn asserted(context: *anyopaque) Lines {
        const self: *const Doorbell = @ptrCast(@alignCast(context));
        return self.lines;
    }
};

const Stamping = struct {
    bus: *const Regions,
    seen: u64 = 0,

    fn read(context: *anyopaque, _: u32, _: Width, _: *Lines) ?u32 {
        const self: *Stamping = @ptrCast(@alignCast(context));
        self.seen = self.bus.now;
        return 0;
    }

    fn write(_: *anyopaque, _: u32, _: Width, _: u32, _: *Lines) ?void {}
};

const Alarm = struct {
    left: u32,

    fn read(_: *anyopaque, _: u32, _: Width, _: *Lines) ?u32 {
        return 0;
    }

    fn write(_: *anyopaque, _: u32, _: Width, _: u32, _: *Lines) ?void {}

    fn tick(context: *anyopaque, cycles: u32, raise: *Lines) ?u32 {
        const self: *Alarm = @ptrCast(@alignCast(context));
        if (self.left == 0) return null;
        if (cycles < self.left) {
            self.left -= cycles;
            return self.left;
        }
        self.left = 0;
        raise.* |= @as(Lines, 1) << @intCast(sw_intr_0);
        return null;
    }
};

const nop: u32 = 0x0000_0013;
const csrsi_mstatus_mie: u32 = 0x3004_6073;
const lw_t0_a0: u32 = 0x0005_2283;
const addi_t0_t0_1: u32 = 0x0012_8293;
const sw_t0_a0: u32 = 0x0055_2023;
const sw_zero_a1: u32 = 0x0005_a023;
const sw_t0_a1: u32 = 0x0055_a023;
const sw_t1_a2: u32 = 0x0066_2023;
const csrci_mstatus_mie: u32 = 0x3004_7073;

fn jal(rd: u5, offset: i32) u32 {
    const imm: u32 = @bitCast(offset);
    return (imm >> 20 & 1) << 31 | (imm >> 1 & 0x3ff) << 21 | (imm >> 11 & 1) << 20 |
        (imm >> 12 & 0xff) << 12 | @as(u32, rd) << 7 | 0x6f;
}

fn place(bytes: []u8, offset: u32, code: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], code, .little);
}

fn image(flash: []u8, program: []const u32, id: u5, handler: []const u32) void {
    for (program, 0..) |code, i| place(flash, @intCast(i * 4), code);
    for (0..intc.ids) |slot| place(flash, @intCast(0x100 + slot * 4), ebreak);
    if (handler.len == 0) return;
    place(flash, 0x100 + 4 * @as(u32, id), jal(0, @intCast(handler_at - (vectors + 4 * @as(u32, id)))));
    for (handler, 0..) |code, i| place(flash, @intCast(0x180 + i * 4), code);
}

fn route(cpu: *Board, source: u32, id: u5, priority: u32, edge: bool) void {
    const l = cpu.spec.intc;
    _ = cpu.poke(4, l.matrix_base + 4 * source, id);
    if (edge) _ = cpu.poke(4, l.control_base + l.kinds, cpu.peek(4, l.control_base + l.kinds).? | @as(u32, 1) << id);
    _ = cpu.poke(4, l.control_base + l.priority + 4 * (@as(u32, id) - l.priority_first), priority);
    _ = cpu.poke(4, l.control_base + l.enable, cpu.peek(4, l.control_base + l.enable).? | @as(u32, 1) << id);
}

fn at(cpu: *const Board, offset: u32) u32 {
    return cpu.spec.intc.control_base + offset;
}

fn armed(memory: *Regions, records: []riscv.trace.Record) Board {
    var cpu = Board.init(memory, .esp32c3, riscv.trace.Ring.init(records) catch unreachable);
    cpu.reset();
    cpu.state.csr.mtvec = vectors | 1;
    return cpu;
}

test "the record's cycle count and the bus's clock are one axis: a device answers at the cycle the record stamps" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    image(&flash, &.{ nop, nop, lw_t0_a0, ebreak }, 1, &.{});
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = flash_base, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = ram_base, .bytes = &ram, .writable = true } },
        undefined,
    };
    var memory: Regions = undefined;
    var stamping: Stamping = .{ .bus = &memory };
    entries[2] = .{ .device = .{ .base = doorbell_base, .size = 0x40, .device = .{ .context = &stamping, .read = Stamping.read, .write = Stamping.write } } };
    memory = try Regions.adopt(&entries);
    var records: [8]riscv.trace.Record = undefined;
    var cpu = armed(&memory, &records);
    cpu.state.x[10] = doorbell_at;
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 4 }).stop);
    const load = cpu.trace.at(1).?;
    try std.testing.expectEqual(@as(?u32, doorbell_at), load.access);
    try std.testing.expectEqual(load.cycles, stamping.seen);
}

test "a source a device raises reaches the CPU interrupt the matrix routes it to, at the vector its id names, C3 TRM 1.5.2 and Table 1.5-1" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    var bell: Doorbell = .{};
    image(&flash, &.{ nop, nop, nop, ebreak }, 1, &.{});
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = flash_base, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = ram_base, .bytes = &ram, .writable = true } },
        .{ .device = .{ .base = doorbell_base, .size = 0x40, .device = .{ .context = &bell, .read = Doorbell.read, .write = Doorbell.write, .asserted = Doorbell.asserted } } },
    };
    var memory = try Regions.adopt(&entries);
    var cpu = armed(&memory, &.{});
    route(&cpu, sw_intr_0, 1, 7, false);
    cpu.state.csr.mstatus.mie = true;
    _ = memory.poke(4, doorbell_at, 1);
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(vectors + 4, cpu.state.pc);
    try std.testing.expectEqual(csr.interrupt_flag | 1, cpu.state.csr.mcause);
    try std.testing.expectEqual(flash_base + 4, cpu.state.csr.mepc);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.csr.mtval);
    try std.testing.expect(!cpu.state.csr.mstatus.mie);
    try std.testing.expect(cpu.state.csr.mstatus.mpie);
    try std.testing.expectEqual(csr.Privilege.machine, cpu.state.privilege);
}

test "a level source the handler leaves asserted re-enters at every MRET, and the same source cleared at its device enters once, C3 TRM 1.5.2" {
    const counting = [_]u32{ lw_t0_a0, addi_t0_t0_1, sw_t0_a0, mret };
    const clearing = [_]u32{ sw_zero_a1, lw_t0_a0, addi_t0_t0_1, sw_t0_a0, mret };
    for ([_][]const u32{ &counting, &clearing }, [_]u32{ 3, 1 }) |handler, entered| {
        var flash: [0x200]u8 = @splat(0);
        var ram: [0x40]u8 = @splat(0);
        var bell: Doorbell = .{};
        image(&flash, &.{ nop, nop, nop, nop, ebreak }, 2, handler);
        var entries = [_]Regions.Entry{
            .{ .memory = .{ .base = flash_base, .bytes = &flash, .writable = false } },
            .{ .memory = .{ .base = ram_base, .bytes = &ram, .writable = true } },
            .{ .device = .{ .base = doorbell_base, .size = 0x40, .device = .{ .context = &bell, .read = Doorbell.read, .write = Doorbell.write, .asserted = Doorbell.asserted } } },
        };
        var memory = try Regions.adopt(&entries);
        var cpu = armed(&memory, &.{});
        route(&cpu, sw_intr_0, 2, 7, false);
        cpu.state.csr.mstatus.mie = true;
        cpu.state.x[10] = ram_base;
        cpu.state.x[11] = doorbell_at;
        _ = memory.poke(4, doorbell_at, 1);
        _ = cpu.run(.{ .instructions = 16 });
        try std.testing.expectEqual(entered, std.mem.readInt(u32, ram[0..4], .little));
    }
}

test "a level source raised and dropped while MIE was off is not pending when MIE comes back, C3 TRM 1.5.2" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    var bell: Doorbell = .{};
    image(&flash, &.{ sw_t0_a1, sw_zero_a1, csrsi_mstatus_mie, nop, ebreak }, 1, &.{});
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = flash_base, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = ram_base, .bytes = &ram, .writable = true } },
        .{ .device = .{ .base = doorbell_base, .size = 0x40, .device = .{ .context = &bell, .read = Doorbell.read, .write = Doorbell.write, .asserted = Doorbell.asserted } } },
    };
    var memory = try Regions.adopt(&entries);
    var cpu = armed(&memory, &.{});
    route(&cpu, sw_intr_0, 1, 7, false);
    cpu.state.x[5] = 1;
    cpu.state.x[11] = doorbell_at;
    _ = cpu.run(.{ .instructions = 2 });
    try std.testing.expectEqual(@as(?u32, 0), memory.peek(4, doorbell_at));
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, at(&cpu, cpu.spec.intc.status)));
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(flash_base + 16, cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.csr.mcause);
}

test "a handler that clears its level source and turns MIE back on to allow nesting does not re-enter itself, C3 TRM 1.5.3.2" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    var bell: Doorbell = .{};
    const handler = [_]u32{ sw_zero_a1, lw_t0_a0, addi_t0_t0_1, sw_t0_a0, csrsi_mstatus_mie, nop, csrci_mstatus_mie, mret };
    image(&flash, &.{ nop, nop, nop, nop, ebreak }, 2, &handler);
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = flash_base, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = ram_base, .bytes = &ram, .writable = true } },
        .{ .device = .{ .base = doorbell_base, .size = 0x40, .device = .{ .context = &bell, .read = Doorbell.read, .write = Doorbell.write, .asserted = Doorbell.asserted } } },
    };
    var memory = try Regions.adopt(&entries);
    var cpu = armed(&memory, &.{});
    route(&cpu, sw_intr_0, 2, 7, false);
    cpu.state.csr.mstatus.mie = true;
    cpu.state.x[10] = ram_base;
    cpu.state.x[11] = doorbell_at;
    _ = memory.poke(4, doorbell_at, 1);
    _ = cpu.run(.{ .instructions = 60 });
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, ram[0..4], .little));
}

test "an edge source enters once and stays out until the clear register flushes its latch, C3 TRM 1.5.2" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    var bell: Doorbell = .{};
    image(&flash, &.{ nop, nop, nop, nop, ebreak }, 2, &.{ sw_t1_a2, lw_t0_a0, addi_t0_t0_1, sw_t0_a0, mret });
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = flash_base, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = ram_base, .bytes = &ram, .writable = true } },
        .{ .device = .{ .base = doorbell_base, .size = 0x40, .device = .{ .context = &bell, .read = Doorbell.read, .write = Doorbell.write, .asserted = Doorbell.asserted } } },
    };
    var memory = try Regions.adopt(&entries);
    var cpu = armed(&memory, &.{});
    route(&cpu, sw_intr_0, 2, 7, true);
    cpu.state.csr.mstatus.mie = true;
    cpu.state.x[10] = ram_base;
    cpu.state.x[6] = 1 << 2;
    cpu.state.x[12] = at(&cpu, cpu.spec.intc.clear);
    _ = memory.poke(4, doorbell_at, 1);
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, ram[0..4], .little));
    try std.testing.expectEqual(@as(?u32, 1), memory.peek(4, doorbell_at));
}

test "an interrupt MIE holds off is taken the instruction after software turns MIE on, C3 TRM 1.5.3.2" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    var bell: Doorbell = .{};
    image(&flash, &.{ nop, csrsi_mstatus_mie, nop, ebreak }, 1, &.{});
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = flash_base, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = ram_base, .bytes = &ram, .writable = true } },
        .{ .device = .{ .base = doorbell_base, .size = 0x40, .device = .{ .context = &bell, .read = Doorbell.read, .write = Doorbell.write, .asserted = Doorbell.asserted } } },
    };
    var memory = try Regions.adopt(&entries);
    var cpu = armed(&memory, &.{});
    route(&cpu, sw_intr_0, 1, 7, false);
    _ = memory.poke(4, doorbell_at, 1);
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(@as(u64, 2), ran.instructions);
    try std.testing.expectEqual(flash_base + 8, cpu.state.csr.mepc);
    try std.testing.expectEqual(csr.interrupt_flag | 1, cpu.state.csr.mcause);
}

test "an interrupt is taken in user mode even with mstatus.MIE clear, because a machine interrupt is always enabled below machine mode, Privileged 3.1.6.1" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    var bell: Doorbell = .{};
    image(&flash, &.{ mret, nop, nop, ebreak }, 1, &.{});
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = flash_base, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = ram_base, .bytes = &ram, .writable = true } },
        .{ .device = .{ .base = doorbell_base, .size = 0x40, .device = .{ .context = &bell, .read = Doorbell.read, .write = Doorbell.write, .asserted = Doorbell.asserted } } },
    };
    var memory = try Regions.adopt(&entries);
    var cpu = armed(&memory, &.{});
    route(&cpu, sw_intr_0, 1, 7, false);
    cpu.pmp.addr[0] = (flash_base >> 2) | ((4 * 1024 * 1024 >> 3) - 1);
    cpu.pmp.cfg[0] = .{ .r = true, .x = true, .mode = .napot };
    cpu.reguard();
    cpu.state.csr.mepc = flash_base + 4;
    cpu.state.csr.mstatus.mpp = .user;
    _ = memory.poke(4, doorbell_at, 1);
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), ran.stop);
    try std.testing.expect(!cpu.state.csr.mstatus.mie);
    try std.testing.expectEqual(vectors + 4, cpu.state.pc);
    try std.testing.expectEqual(csr.interrupt_flag | 1, cpu.state.csr.mcause);
    try std.testing.expectEqual(flash_base + 4, cpu.state.csr.mepc);
    try std.testing.expectEqual(csr.Privilege.user, cpu.state.csr.mstatus.mpp);
    try std.testing.expectEqual(csr.Privilege.machine, cpu.state.privilege);
}

test "an interrupt below the threshold is held out of the hart until the threshold comes down, C3 TRM 1.5.2" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    var bell: Doorbell = .{};
    image(&flash, &.{ nop, nop, ebreak }, 1, &.{});
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = flash_base, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = ram_base, .bytes = &ram, .writable = true } },
        .{ .device = .{ .base = doorbell_base, .size = 0x40, .device = .{ .context = &bell, .read = Doorbell.read, .write = Doorbell.write, .asserted = Doorbell.asserted } } },
    };
    var memory = try Regions.adopt(&entries);
    var cpu = armed(&memory, &.{});
    route(&cpu, sw_intr_0, 1, 7, false);
    _ = cpu.poke(4, at(&cpu, cpu.spec.intc.threshold), 8);
    cpu.state.csr.mstatus.mie = true;
    _ = memory.poke(4, doorbell_at, 1);
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(flash_base + 8, cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.csr.mcause);

    cpu.state.pc = flash_base;
    cpu.stop = null;
    _ = cpu.poke(4, at(&cpu, cpu.spec.intc.threshold), 7);
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(vectors + 4, cpu.state.pc);
    try std.testing.expectEqual(csr.interrupt_flag | 1, cpu.state.csr.mcause);
}

test "enabled answers false for a source routed nowhere, for a routed id at priority zero and for one below the threshold, and true once its id is enabled above it, C3 TRM 1.5.2" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    image(&flash, &.{ebreak}, 1, &.{});
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = flash_base, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = ram_base, .bytes = &ram, .writable = true } },
    };
    var memory = try Regions.adopt(&entries);
    var cpu = armed(&memory, &.{});
    try std.testing.expect(!cpu.enabled(sw_intr_0));
    route(&cpu, sw_intr_0, 1, 0, false);
    try std.testing.expect(!cpu.enabled(sw_intr_0));
    route(&cpu, sw_intr_0, 1, 7, false);
    _ = cpu.poke(4, at(&cpu, cpu.spec.intc.threshold), 8);
    try std.testing.expect(!cpu.enabled(sw_intr_0));
    _ = cpu.poke(4, at(&cpu, cpu.spec.intc.threshold), 7);
    try std.testing.expect(cpu.enabled(sw_intr_0));
    try std.testing.expect(!cpu.state.csr.mstatus.mie);
}

test "a source past the last line the bus carries is not enabled and pending it does nothing, C3 TRM 1.5.2" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    image(&flash, &.{ebreak}, 1, &.{});
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = flash_base, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = ram_base, .bytes = &ram, .writable = true } },
    };
    var memory = try Regions.adopt(&entries);
    var cpu = armed(&memory, &.{});
    try std.testing.expect(!cpu.enabled(240));
    cpu.pend(240);
    try std.testing.expectEqual(@as(u32, 0), cpu.intc.pending());
}

test "two sources pending at once are taken highest priority first, whichever id they carry, C3 TRM 1.5.2" {
    for ([_]u32{ 9, 5 }, [_]u5{ 8, 3 }) |priority, first| {
        var flash: [0x200]u8 = @splat(0);
        var ram: [0x40]u8 = @splat(0);
        var bell: Doorbell = .{};
        image(&flash, &.{ nop, nop, ebreak }, 1, &.{});
        var entries = [_]Regions.Entry{
            .{ .memory = .{ .base = flash_base, .bytes = &flash, .writable = false } },
            .{ .memory = .{ .base = ram_base, .bytes = &ram, .writable = true } },
            .{ .device = .{ .base = doorbell_base, .size = 0x40, .device = .{ .context = &bell, .read = Doorbell.read, .write = Doorbell.write, .asserted = Doorbell.asserted } } },
        };
        var memory = try Regions.adopt(&entries);
        var cpu = armed(&memory, &.{});
        route(&cpu, sw_intr_0, 3, 7, false);
        route(&cpu, sw_intr_1, 8, priority, false);
        cpu.state.csr.mstatus.mie = true;
        _ = memory.poke(4, doorbell_at, 1);
        _ = memory.poke(4, doorbell_at + 4, 1);
        try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        try std.testing.expectEqual(csr.interrupt_flag | first, cpu.state.csr.mcause);
        try std.testing.expectEqual(vectors + 4 * @as(u32, first), cpu.state.pc);
    }
}

test "a WFI stands the hart still until a device that keeps time raises the interrupt that wakes it, C3 TRM Register 16.13" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    var alarm: Alarm = .{ .left = 40 };
    image(&flash, &.{ wfi, nop, ebreak }, 1, &.{});
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = flash_base, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = ram_base, .bytes = &ram, .writable = true } },
        .{ .device = .{ .base = doorbell_base, .size = 0x40, .device = .{ .context = &alarm, .read = Alarm.read, .write = Alarm.write, .tick = Alarm.tick } } },
    };
    var memory = try Regions.adopt(&entries);
    var cpu = armed(&memory, &.{});
    route(&cpu, sw_intr_0, 1, 7, true);
    cpu.state.csr.mstatus.mie = true;
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(vectors + 4, cpu.state.pc);
    try std.testing.expectEqual(flash_base + 4, cpu.state.csr.mepc);
    try std.testing.expect(cpu.cycles >= 40);
}

test "a WFI in a memory whose devices raise nothing ends its wait rather than the run, Privileged 3.3.3" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    var bell: Doorbell = .{};
    image(&flash, &.{ wfi, nop, ebreak }, 1, &.{});
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = flash_base, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = ram_base, .bytes = &ram, .writable = true } },
        .{ .device = .{ .base = doorbell_base, .size = 0x40, .device = .{ .context = &bell, .read = Doorbell.read, .write = Doorbell.write, .asserted = Doorbell.asserted } } },
    };
    var memory = try Regions.adopt(&entries);
    var cpu = armed(&memory, &.{});
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(@as(u64, 2), ran.instructions);
}

test "a step of a hart standing in a WFI retires nothing, charges nothing and reports it asleep, Privileged 3.3.3" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    image(&flash, &.{ wfi, li_a0_5, ebreak }, 1, &.{});
    var entries = boardOf(&flash, &ram);
    var memory = try Regions.adopt(&entries);
    var cpu = armed(&memory, &.{});
    route(&cpu, sw_intr_0, 1, 7, true);
    const halting = cpu.step();
    try std.testing.expectEqual(@as(?Class, .system), halting.class);
    try std.testing.expect(halting.asleep);
    const standing = cpu.step();
    try std.testing.expectEqual(@as(?Class, null), standing.class);
    try std.testing.expectEqual(@as(?u8, null), standing.cost);
    try std.testing.expectEqual(@as(u8, 0), standing.charged);
    try std.testing.expect(standing.asleep);
    try std.testing.expectEqual(@as(u64, 1), cpu.instructions);
    try std.testing.expectEqual(@as(u64, 1), cpu.cycles);
    cpu.pend(@intCast(sw_intr_0));
    const resumed = cpu.step();
    try std.testing.expect(!resumed.asleep);
    try std.testing.expectEqual(@as(?Class, .data_processing), resumed.class);
    try std.testing.expectEqual(@as(u32, 5), cpu.state.x[10]);
}

test "an interrupt a device raises when its own time comes arrives between two instructions of the run, C3 TRM 8.3.3" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    var alarm: Alarm = .{ .left = 5 };
    image(&flash, &.{ nop, nop, nop, nop, nop, nop, nop, ebreak }, 1, &.{});
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = flash_base, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = ram_base, .bytes = &ram, .writable = true } },
        .{ .device = .{ .base = doorbell_base, .size = 0x40, .device = .{ .context = &alarm, .read = Alarm.read, .write = Alarm.write, .tick = Alarm.tick } } },
    };
    var memory = try Regions.adopt(&entries);
    var cpu = armed(&memory, &.{});
    route(&cpu, sw_intr_0, 1, 7, true);
    cpu.state.csr.mstatus.mie = true;
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(@as(u64, 5), ran.instructions);
    try std.testing.expectEqual(flash_base + 20, cpu.state.csr.mepc);
    try std.testing.expectEqual(csr.interrupt_flag | 1, cpu.state.csr.mcause);
}

const lr_t0_a1: u32 = 0x1005_a2af;
const sc_t1_t2_a1: u32 = 0x1875_a32f;
const amoadd_t0_t2_a1: u32 = 0x0075_a2af;
const amoswap_t0_t2_a1: u32 = 0x0875_a2af;
const sw_t2_a1: u32 = 0x0075_a023;
const lw_t1_a1: u32 = 0x0005_a303;
const csrr_t0_misa: u32 = 0x3010_22f3;
const csrr_t0_mip: u32 = 0x3440_22f3;
const csrw_mie_t0: u32 = 0x3042_9073;

fn startedAs(memory: *Memory, c: riscv.Core, records: []riscv.trace.Record) Cpu {
    var cpu = Cpu.init(memory, c, riscv.trace.Ring.init(records) catch unreachable);
    cpu.reset();
    return cpu;
}

const word_at: u32 = ram_base + 32;
const word_offset: usize = 32;

fn atomicHart(memory: *Memory, program: []const u32) Cpu {
    memory.program(program);
    var cpu = startedAs(memory, .esp32c6, &.{});
    cpu.state.x[11] = word_at;
    cpu.state.x[7] = 7;
    return cpu;
}

fn wordOf(memory: *Memory) u32 {
    return std.mem.readInt(u32, memory.ram[word_offset..][0..4], .little);
}

test "the ESP32-C6 reads the A bit in misa and its own architecture and implementation ids, C6 TRM Registers 1.2, 1.3 and 1.6" {
    var memory: Memory = .{};
    var cpu = startedAs(&memory, .esp32c6, &.{});
    try std.testing.expectEqual(@as(u32, 0x4010_1105), cpu.state.csr.read(.misa));
    try std.testing.expectEqual(@as(u32, 0x8000_0002), cpu.state.csr.read(.marchid));
    try std.testing.expectEqual(@as(u32, 0x0000_0002), cpu.state.csr.read(.mimpid));
    try std.testing.expectEqual(@as(u32, 0x0000_0612), cpu.state.csr.read(.mvendorid));
    var other: Memory = .{};
    var c3 = startedAs(&other, .esp32c3, &.{});
    try std.testing.expectEqual(@as(u32, 0x4010_1104), c3.state.csr.read(.misa));
    try std.testing.expect(cpu.state.csr.read(.misa) & 1 != 0);
    try std.testing.expect(c3.state.csr.read(.misa) & 1 == 0);
}

test "an AMO runs on the ESP32-C6 and is an illegal instruction on the ESP32-C3, which has no A, C3 TRM 1.1 and C6 TRM 1.1" {
    var memory: Memory = .{};
    memory.program(&.{ amoadd_t0_t2_a1, ebreak });
    var c3 = startedAs(&memory, .esp32c3, &.{});
    c3.state.x[11] = word_at;
    _ = c3.run(.{ .instructions = 4 });
    try std.testing.expectEqual(csr.Cause.illegal_instruction, @as(csr.Cause, @enumFromInt(c3.state.csr.mcause)));
    var c6 = atomicHart(&memory, &.{ amoadd_t0_t2_a1, ebreak });
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), c6.run(.{ .instructions = 4 }).stop);
    try std.testing.expectEqual(@as(u32, 7), wordOf(&memory));
}

test "an LR.W and an SC.W with nothing between them store the word and answer zero, Unprivileged 13.2" {
    var memory: Memory = .{};
    var cpu = atomicHart(&memory, &.{ lr_t0_a1, sc_t1_t2_a1, ebreak });
    _ = cpu.run(.{ .instructions = 8 });
    try std.testing.expectEqual(@as(u32, 0), cpu.state.x[6]);
    try std.testing.expectEqual(@as(u32, 7), wordOf(&memory));
}

test "an LR.W no memory answers is a load access fault, where an AMO at the same address is a store one, Privileged 3.1.15" {
    var lw: Memory = .{};
    var control = atomicHart(&lw, &.{ lw_t1_a1, ebreak });
    control.state.x[11] = 0x1000;
    _ = control.run(.{ .instructions = 8 });
    try std.testing.expectEqual(@as(u32, 5), control.state.csr.mcause);

    var memory: Memory = .{};
    var cpu = atomicHart(&memory, &.{ lr_t0_a1, ebreak });
    cpu.state.x[11] = 0x1000;
    _ = cpu.run(.{ .instructions = 8 });
    try std.testing.expectEqual(@as(u32, 5), cpu.state.csr.mcause);
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.state.csr.mtval);

    var amo: Memory = .{};
    var swapping = atomicHart(&amo, &.{ amoswap_t0_t2_a1, ebreak });
    swapping.state.x[11] = 0x1000;
    _ = swapping.run(.{ .instructions = 8 });
    try std.testing.expectEqual(@as(u32, 7), swapping.state.csr.mcause);
}

test "a store between an LR.W and its SC.W breaks the reservation, so the SC.W stores nothing and answers one, C6 TRM 1.15.2.1" {
    var memory: Memory = .{};
    var cpu = atomicHart(&memory, &.{ lr_t0_a1, sw_t2_a1, sc_t1_t2_a1, ebreak });
    cpu.state.x[7] = 7;
    _ = cpu.run(.{ .instructions = 8 });
    try std.testing.expectEqual(@as(u32, 1), cpu.state.x[6]);
    try std.testing.expectEqual(@as(?u32, null), cpu.state.reservation);
}

test "a load between an LR.W and its SC.W breaks the reservation as well, C6 TRM 1.15.2.1" {
    var memory: Memory = .{};
    var cpu = atomicHart(&memory, &.{ lr_t0_a1, lw_t1_a1, sc_t1_t2_a1, ebreak });
    _ = cpu.run(.{ .instructions = 8 });
    try std.testing.expectEqual(@as(u32, 1), cpu.state.x[6]);
    try std.testing.expectEqual(@as(u32, 0), wordOf(&memory));
}

test "a trap between an LR.W and its SC.W breaks the reservation, C6 TRM 1.15.2.1" {
    var memory: Memory = .{};
    var cpu = atomicHart(&memory, &.{ lr_t0_a1, ecall, sc_t1_t2_a1, ebreak });
    memory.handler(&resuming_handler);
    cpu.state.csr.mtvec = ram_base | 1;
    _ = cpu.run(.{ .instructions = 16 });
    try std.testing.expectEqual(@as(u32, 1), cpu.state.x[6]);
    try std.testing.expectEqual(@as(u32, 0), wordOf(&memory));
}

test "a misaligned atomic address enters the handler as a load access fault for LR and a store access fault for SC and AMO, Privileged 3.1.15" {
    for ([_]struct { u32, csr.Cause }{ .{ lr_t0_a1, .load_access_fault }, .{ sc_t1_t2_a1, .store_access_fault }, .{ amoswap_t0_t2_a1, .store_access_fault } }) |case| {
        const instruction, const cause = case;
        var memory: Memory = .{};
        var cpu = atomicHart(&memory, &.{ instruction, ebreak });
        memory.handler(&.{ebreak});
        cpu.state.csr.mtvec = ram_base | 1;
        cpu.state.x[11] = word_at + 2;
        _ = cpu.run(.{ .instructions = 8 });
        try std.testing.expectEqual(@intFromEnum(cause), cpu.state.csr.mcause);
        try std.testing.expectEqual(word_at + 2, cpu.state.csr.mtval);
        try std.testing.expectEqual(flash_base, cpu.state.csr.mepc);
    }
}

test "an atomic the protection unit refuses is a store access fault whichever half of it was refused, C6 TRM 1.15.2.3" {
    for ([_]bool{ true, false }) |readable| {
        var memory: Memory = .{};
        var cpu = atomicHart(&memory, &.{ mret, amoswap_t0_t2_a1, ebreak });
        memory.handler(&.{ebreak});
        cpu.state.csr.mtvec = ram_base | 1;
        grantFlash(&cpu);
        cpu.pmp.addr[1] = (ram_base >> 2) | ((64 >> 3) - 1);
        cpu.state.x[11] = word_at;
        cpu.pmp.cfg[1] = .{ .r = readable, .w = false, .mode = .napot };
        cpu.reguard();
        cpu.state.csr.mepc = flash_base + 4;
        _ = cpu.run(.{ .instructions = 8 });
        try std.testing.expectEqual(@intFromEnum(csr.Cause.store_access_fault), cpu.state.csr.mcause);
        try std.testing.expectEqual(word_at, cpu.state.csr.mtval);
        try std.testing.expectEqual(@as(u32, 0), wordOf(&memory));
    }
}

test "a debugger read the protection unit refuses is not counted against the next trap the hart takes" {
    var memory: Memory = .{};
    memory.program(&.{illegal});
    var cpu = started(&memory, &.{});
    cpu.pmp.addr[1] = (ram_base >> 2) | ((64 >> 3) - 1);
    cpu.pmp.cfg[1] = .{ .mode = .napot, .l = true };
    cpu.reguard();
    try std.testing.expectEqual(@as(?u32, null), cpu.peek(4, ram_base));
    _ = cpu.step();
    try std.testing.expectEqual(@intFromEnum(csr.Cause.illegal_instruction), cpu.state.csr.mcause);
    try std.testing.expect(!cpu.taken.?.protected);
}

test "mie and mip are CSRs of the C6 and numbers the C3 has no register for, C6 TRM 1.5.1 and C3 TRM 8.3.2" {
    var memory: Memory = .{};
    memory.program(&.{ csrr_t0_mip, ebreak });
    var c3 = startedAs(&memory, .esp32c3, &.{});
    _ = c3.run(.{ .instructions = 4 });
    try std.testing.expectEqual(csr.Cause.illegal_instruction, @as(csr.Cause, @enumFromInt(c3.state.csr.mcause)));
    var c6 = startedAs(&memory, .esp32c6, &.{});
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), c6.run(.{ .instructions = 4 }).stop);
    try std.testing.expectEqual(@as(u32, 0), c6.state.x[5]);
}

fn armedAs(c: riscv.Core, memory: *Regions, records: []riscv.trace.Record) Board {
    var cpu = Board.init(memory, c, riscv.trace.Ring.init(records) catch unreachable);
    cpu.reset();
    cpu.state.csr.mtvec = vectors | 1;
    return cpu;
}

fn boardOf(flash: []u8, ram: []u8) [2]Regions.Entry {
    return .{
        .{ .memory = .{ .base = flash_base, .bytes = flash, .writable = false } },
        .{ .memory = .{ .base = ram_base, .bytes = ram, .writable = true } },
    };
}

fn enable(cpu: *Board, id: u5) void {
    cpu.state.csr.mie |= @as(u32, 1) << id;
    cpu.state.csr.mstatus.mie = true;
    cpu.rearm();
}

fn assert(cpu: *Board, register: u32) void {
    _ = cpu.poke(4, cpu.spec.intc.control_base + cpu.spec.intc.software + 4 * register, 1);
}

test "a C6 program raises its own interrupt through the controller's software register and lands on the vector its id names, C6 TRM 10.4.2 and 1.6.2" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    image(&flash, &.{ nop, nop, nop, ebreak }, 5, &.{});
    var entries = boardOf(&flash, &ram);
    var memory = try Regions.adopt(&entries);
    var cpu = armedAs(.esp32c6, &memory, &.{});
    route(&cpu, intc.esp32c6.software_source, 5, 7, false);
    enable(&cpu, 5);
    assert(&cpu, 0);
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), ran.stop);
    try std.testing.expectEqual(vectors + 4 * 5, cpu.state.pc);
    try std.testing.expectEqual(csr.interrupt_flag | 5, cpu.state.csr.mcause);
    try std.testing.expectEqual(flash_base, cpu.state.csr.mepc);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.csr.mtval);
    try std.testing.expect(!cpu.state.csr.mstatus.mie);
    try std.testing.expect(cpu.state.csr.mstatus.mpie);
}

test "an interrupt the C6's controller lets through waits for its bit in mie, and arrives the instruction after software sets it, C6 TRM 1.6.2" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    image(&flash, &.{ nop, csrw_mie_t0, nop, ebreak }, 6, &.{});
    var entries = boardOf(&flash, &ram);
    var memory = try Regions.adopt(&entries);
    var cpu = armedAs(.esp32c6, &memory, &.{});
    route(&cpu, intc.esp32c6.software_source, 6, 7, false);
    cpu.state.csr.mstatus.mie = true;
    cpu.state.x[5] = @as(u32, 1) << 6;
    assert(&cpu, 0);
    _ = cpu.run(.{ .instructions = 1 });
    try std.testing.expectEqual(flash_base + 4, cpu.state.pc);
    _ = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(vectors + 4 * 6, cpu.state.pc);
    try std.testing.expectEqual(flash_base + 8, cpu.state.csr.mepc);
}

test "mip on the C6 reads what the controller says is pending, and reads zero again once the source is dropped, C6 TRM 1.6.2" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    image(&flash, &.{ebreak}, 5, &.{});
    var entries = boardOf(&flash, &ram);
    var memory = try Regions.adopt(&entries);
    var cpu = armedAs(.esp32c6, &memory, &.{});
    route(&cpu, intc.esp32c6.software_source, 5, 7, false);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.csr.mip);
    assert(&cpu, 0);
    try std.testing.expectEqual(@as(u32, 1) << 5, cpu.state.csr.mip);
    try std.testing.expectEqual(@as(u32, 1) << 5, cpu.peek(4, cpu.spec.intc.control_base + cpu.spec.intc.status).?);
    _ = cpu.poke(4, cpu.spec.intc.control_base + cpu.spec.intc.software, 0);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.csr.mip);
}

test "a WFI on the C6 ends at the interrupt its own software register raised, C6 TRM 10.4.2 and Privileged 3.3.3" {
    var flash: [0x200]u8 = @splat(0);
    var ram: [0x40]u8 = @splat(0);
    image(&flash, &.{ wfi, ebreak }, 5, &.{});
    var entries = boardOf(&flash, &ram);
    var memory = try Regions.adopt(&entries);
    var cpu = armedAs(.esp32c6, &memory, &.{});
    route(&cpu, intc.esp32c6.software_source, 5, 7, false);
    enable(&cpu, 5);
    assert(&cpu, 0);
    const before = cpu.cycles;
    _ = cpu.run(.{ .instructions = 2 });
    try std.testing.expectEqual(vectors + 4 * 5, cpu.state.pc);
    try std.testing.expect(cpu.cycles - before < 4);
}

test "a build that carries the ESP32-C3 alone decodes no atomic row, so the A extension is not in it" {
    const OnlyC3 = riscv.Processor(.{ .cores = &.{.esp32c3}, .Bus = Memory });
    const OnlyC6 = riscv.Processor(.{ .cores = &.{.esp32c6}, .Bus = Memory });
    const a = comptime riscv.decode.only(&.{.a});
    try std.testing.expectEqual(@as(riscv.decode.Groups, 0), OnlyC3.allowed & a);
    try std.testing.expectEqual(a, OnlyC6.allowed & a);
    var memory: Memory = .{};
    const c3 = OnlyC3.init(&memory, .esp32c3, .{});
    const c6 = OnlyC6.init(&memory, .esp32c6, .{});
    try std.testing.expectEqual(intc.esp32c3.control_base, c3.spec.intc.control_base);
    try std.testing.expectEqual(intc.esp32c6.control_base, c6.spec.intc.control_base);
    try std.testing.expect(!c3.spec.pmp_static_priority);
    try std.testing.expect(c6.spec.pmp_static_priority);
}
