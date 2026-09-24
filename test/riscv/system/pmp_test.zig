const std = @import("std");
const Word = @import("../../../src/contract.zig").Word;
const riscv = @import("../../../src/riscv/root.zig");
const every: []const riscv.Core = std.enums.values(riscv.Core);
const csr = @import("isa").riscv.csr;
const pmp = @import("../../../src/riscv/system/pmp.zig");
const regions = @import("../../../src/memory/regions.zig");

const machine = csr.Privilege.machine;
const user = csr.Privilege.user;

fn napot(base: u32, size: u32) u32 {
    return (base >> 2) | ((size >> 3) - 1);
}

fn napotEntry(unit: *pmp.Pmp, i: usize, base: u32, size: u32, config: pmp.Config) void {
    unit.addr[i] = napot(base, size);
    unit.cfg[i] = config;
    unit.cfg[i].mode = .napot;
}

test "an NA4 entry matches the four bytes at its own address and nothing else, Privileged Table 23" {
    var unit: pmp.Pmp = .{};
    unit.addr[0] = 0x3fc8_0100 >> 2;
    unit.cfg[0] = .{ .r = true, .mode = .na4 };
    try std.testing.expect(!unit.permits(0x3fc8_00fc, user, .read));
    try std.testing.expect(unit.permits(0x3fc8_0100, user, .read));
    try std.testing.expect(unit.permits(0x3fc8_0102, user, .read));
    try std.testing.expect(!unit.permits(0x3fc8_0104, user, .read));
}

test "a NAPOT entry is as large as its trailing ones say, from eight bytes up, Privileged Table 24" {
    const sizes = [_]u32{ 8, 16, 32, 4096, 1 << 20 };
    for (sizes) |size| {
        var unit: pmp.Pmp = .{};
        napotEntry(&unit, 0, 0x4200_0000, size, .{ .r = true });
        try std.testing.expect(!unit.permits(0x4200_0000 - 4, user, .read));
        try std.testing.expect(unit.permits(0x4200_0000, user, .read));
        try std.testing.expect(unit.permits(0x4200_0000 + size - 4, user, .read));
        try std.testing.expect(!unit.permits(0x4200_0000 + size, user, .read));
    }
}

test "a NAPOT entry of all ones covers the whole address space, since its range runs past what the hart addresses, Privileged Table 24" {
    var unit: pmp.Pmp = .{};
    unit.addr[0] = 0xffff_ffff;
    unit.cfg[0] = .{ .r = true, .mode = .napot };
    try std.testing.expect(unit.permits(0, user, .read));
    try std.testing.expect(unit.permits(0x4200_0000, user, .read));
    try std.testing.expect(unit.permits(0xffff_fffc, user, .read));
}

test "a top-of-range entry runs from the address register below it up to its own, Privileged 3.7.1.1" {
    var unit: pmp.Pmp = .{};
    unit.addr[0] = 0x3fc8_0000 >> 2;
    unit.cfg[0] = .{ .mode = .off };
    unit.addr[1] = 0x3fc8_1000 >> 2;
    unit.cfg[1] = .{ .r = true, .mode = .tor };
    try std.testing.expect(!unit.permits(0x3fc7_fffc, user, .read));
    try std.testing.expect(unit.permits(0x3fc8_0000, user, .read));
    try std.testing.expect(unit.permits(0x3fc8_0ffc, user, .read));
    try std.testing.expect(!unit.permits(0x3fc8_1000, user, .read));
}

test "a top-of-range entry 0 has zero for its bottom, and one whose bottom is not below its top matches nothing, Privileged 3.7.1.1" {
    var unit: pmp.Pmp = .{};
    unit.addr[0] = 0x0000_1000 >> 2;
    unit.cfg[0] = .{ .r = true, .mode = .tor };
    try std.testing.expect(unit.permits(0, user, .read));
    try std.testing.expect(unit.permits(0x0000_0ffc, user, .read));
    try std.testing.expect(!unit.permits(0x0000_1000, user, .read));

    var empty: pmp.Pmp = .{};
    empty.addr[0] = 0x3fc8_1000 >> 2;
    empty.addr[1] = 0x3fc8_1000 >> 2;
    empty.cfg[1] = .{ .r = true, .mode = .tor };
    try std.testing.expect(!empty.permits(0x3fc8_0ffc, user, .read));
    try std.testing.expect(!empty.permits(0x3fc8_1000, user, .read));
}

test "an entry whose mode is OFF matches nothing however its address register reads, Privileged Table 23" {
    var unit: pmp.Pmp = .{};
    unit.addr[0] = napot(0x3fc8_0000, 4096);
    unit.cfg[0] = .{ .r = true, .w = true, .x = true, .mode = .off };
    try std.testing.expect(!unit.permits(0x3fc8_0000, user, .read));
    try std.testing.expect(unit.permits(0x3fc8_0000, machine, .read));
}

test "machine mode reaches an address no entry matches and user mode does not, Privileged 3.7.1.3 and C3 TRM 1.8.3" {
    var unit: pmp.Pmp = .{};
    try std.testing.expect(unit.permits(0x4200_0000, machine, .fetch));
    try std.testing.expect(!unit.permits(0x4200_0000, user, .fetch));
    napotEntry(&unit, 3, 0x3fc8_0000, 4096, .{ .r = true });
    try std.testing.expect(unit.permits(0x4200_0000, machine, .read));
    try std.testing.expect(!unit.permits(0x4200_0000, user, .read));
}

test "read, write and execute are refused one at a time, C3 TRM 1.8.3" {
    var unit: pmp.Pmp = .{};
    napotEntry(&unit, 0, 0x3fc8_0000, 4096, .{ .r = true });
    try std.testing.expect(unit.permits(0x3fc8_0000, user, .read));
    try std.testing.expect(!unit.permits(0x3fc8_0000, user, .write));
    try std.testing.expect(!unit.permits(0x3fc8_0000, user, .fetch));
    unit.cfg[0].w = true;
    try std.testing.expect(unit.permits(0x3fc8_0000, user, .write));
    try std.testing.expect(!unit.permits(0x3fc8_0000, user, .fetch));
    unit.cfg[0].x = true;
    try std.testing.expect(unit.permits(0x3fc8_0000, user, .fetch));
}

test "an unlocked entry leaves machine mode alone and a locked one constrains it, Privileged 3.7.1.2 and C3 TRM 1.8.3" {
    var unit: pmp.Pmp = .{};
    napotEntry(&unit, 0, 0x3fc8_0000, 4096, .{ .r = true });
    try std.testing.expect(unit.permits(0x3fc8_0000, machine, .write));
    try std.testing.expect(!unit.restrictive());
    unit.cfg[0].l = true;
    try std.testing.expect(unit.restrictive());
    try std.testing.expect(unit.permits(0x3fc8_0000, machine, .read));
    try std.testing.expect(!unit.permits(0x3fc8_0000, machine, .write));
    try std.testing.expect(!unit.permits(0x3fc8_0000, machine, .fetch));
    try std.testing.expect(unit.permits(0x4200_0000, machine, .write));
}

test "a locked entry whose mode is OFF locks the entry without guarding anything, Privileged 3.7.1.2" {
    var unit: pmp.Pmp = .{};
    unit.addr[0] = napot(0x3fc8_0000, 4096);
    unit.cfg[0] = .{ .l = true, .mode = .off };
    try std.testing.expect(!unit.restrictive());
    try std.testing.expect(unit.permits(0x3fc8_0000, machine, .write));
    unit.write(.pmpcfg0, 0xffff_ffff);
    try std.testing.expectEqual(@as(u32, 0x9f9f_9f80), unit.read(.pmpcfg0));
}

test "any enabled entry that matches grants the access, because this part does not implement static priority, C3 TRM 1.8.2" {
    var unit: pmp.Pmp = .{};
    napotEntry(&unit, 0, 0x3fc8_0000, 4096, .{ .r = true });
    napotEntry(&unit, 1, 0x3fc8_0000, 4096, .{ .r = true, .w = true });
    try std.testing.expect(unit.permits(0x3fc8_0000, user, .write));

    var reversed: pmp.Pmp = .{};
    napotEntry(&reversed, 0, 0x3fc8_0000, 4096, .{ .r = true, .w = true });
    napotEntry(&reversed, 1, 0x3fc8_0000, 4096, .{ .r = true });
    try std.testing.expect(reversed.permits(0x3fc8_0000, user, .write));
}

test "the lowest-numbered matching entry decides on a unit with static priority, which is what the ESP32-C6 has and the ESP32-C3 has not, C6 TRM 1.8.1 and C3 TRM 1.8.2" {
    var unit: pmp.Pmp = .{ .static_priority = true };
    napotEntry(&unit, 0, 0x3fc8_0000, 4096, .{ .r = true });
    napotEntry(&unit, 1, 0x3fc8_0000, 4096, .{ .r = true, .w = true });
    try std.testing.expect(!unit.permits(0x3fc8_0000, user, .write));
    try std.testing.expect(unit.permits(0x3fc8_0000, user, .read));

    var reversed: pmp.Pmp = .{ .static_priority = true };
    napotEntry(&reversed, 0, 0x3fc8_0000, 4096, .{ .r = true, .w = true });
    napotEntry(&reversed, 1, 0x3fc8_0000, 4096, .{ .r = true });
    try std.testing.expect(reversed.permits(0x3fc8_0000, user, .write));
}

test "static priority leaves everything else alone: an address no entry matches, an entry that does not match, and machine mode under an unlocked entry, Privileged 3.7.1.3" {
    var unit: pmp.Pmp = .{ .static_priority = true };
    napotEntry(&unit, 0, 0x4200_0000, 4096, .{ .r = true });
    napotEntry(&unit, 1, 0x3fc8_0000, 4096, .{ .r = true, .w = true });
    try std.testing.expect(unit.permits(0x3fc8_0000, user, .write));
    try std.testing.expect(!unit.permits(0x5000_0000, user, .read));
    try std.testing.expect(unit.permits(0x5000_0000, machine, .read));
    try std.testing.expect(unit.permits(0x4200_0000, machine, .write));
}

test "an address that matches an entry only in part cannot arise, because every boundary is four-byte aligned and no access crosses one, C3 TRM 1.8.2 and C3 TRM 3.3.1" {
    var unit: pmp.Pmp = .{};
    unit.addr[0] = 0x3fc8_0100 >> 2;
    unit.cfg[0] = .{ .r = true, .mode = .na4 };
    try std.testing.expect(unit.permits(0x3fc8_0100, user, .read));
    try std.testing.expect(unit.permits(0x3fc8_0102, user, .read));
    try std.testing.expect(!unit.permits(0x3fc8_0104, user, .read));
    try std.testing.expect(!unit.permits(0x3fc8_00fe, user, .read));
}

test "the four configuration registers hold four entries each, Privileged Figure 30" {
    var unit: pmp.Pmp = .{};
    unit.write(.pmpcfg0, 0x0115_091f);
    try std.testing.expectEqual(@as(u32, 0x0115_091f), unit.read(.pmpcfg0));
    try std.testing.expectEqual(pmp.Mode.napot, unit.cfg[0].mode);
    try std.testing.expectEqual(pmp.Mode.tor, unit.cfg[1].mode);
    try std.testing.expectEqual(pmp.Mode.na4, unit.cfg[2].mode);
    try std.testing.expectEqual(pmp.Mode.off, unit.cfg[3].mode);
    unit.write(.pmpcfg3, 0x0000_0011);
    try std.testing.expectEqual(pmp.Mode.na4, unit.cfg[12].mode);
    try std.testing.expect(unit.cfg[12].r);
    unit.write(.pmpaddr7, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), unit.read(.pmpaddr7));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), unit.addr[7]);
}

test "a configuration byte keeps R, W, X, A and L and reads zero where the specification defines zero, Privileged Figure 34" {
    var unit: pmp.Pmp = .{};
    unit.write(.pmpcfg0, 0xffff_ffff);
    try std.testing.expectEqual(@as(u32, 0x9f9f_9f9f), unit.read(.pmpcfg0));
}

test "a configuration written with the write permission and not the read permission keeps neither, Privileged 3.7.1" {
    var unit: pmp.Pmp = .{};
    unit.write(.pmpcfg0, 0x0000_000a);
    try std.testing.expectEqual(@as(u32, 0x0000_0008), unit.read(.pmpcfg0));
    try std.testing.expect(!unit.cfg[0].w);
}

test "the granularity is four bytes, so all ones written to an address register read back as all ones, Privileged 3.7.1.1" {
    var unit: pmp.Pmp = .{};
    unit.write(.pmpcfg0, 0);
    unit.write(.pmpaddr0, 0xffff_ffff);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), unit.read(.pmpaddr0));
}

test "a locked entry ignores a write to its configuration and to its address register until the hart is reset, Privileged 3.7.1.2" {
    var unit: pmp.Pmp = .{};
    napotEntry(&unit, 1, 0x3fc8_0000, 4096, .{ .r = true, .l = true });
    const held = unit.addr[1];
    unit.write(.pmpcfg0, 0x0000_0000);
    unit.write(.pmpaddr1, 0);
    try std.testing.expectEqual(@as(u32, 0x0000_9900), unit.read(.pmpcfg0));
    try std.testing.expectEqual(held, unit.addr[1]);
    unit.write(.pmpcfg0, 0x0000_000b);
    try std.testing.expectEqual(@as(u32, 0x0000_990b), unit.read(.pmpcfg0));
}

test "a locked top-of-range entry freezes the address register below it as well, Privileged 3.7.1.2" {
    var unit: pmp.Pmp = .{};
    unit.addr[4] = 0x3fc8_0000 >> 2;
    unit.addr[5] = 0x3fc8_1000 >> 2;
    unit.cfg[5] = .{ .r = true, .mode = .tor, .l = true };
    unit.write(.pmpaddr4, 0);
    try std.testing.expectEqual(@as(u32, 0x3fc8_0000 >> 2), unit.addr[4]);
    unit.cfg[5].mode = .napot;
    unit.write(.pmpaddr4, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.addr[4]);
}

const flash_base = riscv.spec(.esp32c3).flat.flash_base;
const ram_base = riscv.spec(.esp32c3).flat.ram_base;

const Memory = struct {
    flash: [64]u8 = @splat(0),
    ram: [64]u8 = @splat(0),
    folded: regions.Folded = .{},

    pub fn lookup(self: *Memory, address: u32) regions.Found {
        if (address -% flash_base < self.flash.len) return .{ .base = flash_base, .len = self.flash.len, .host = &self.flash, .writable = true };
        if (address -% ram_base < self.ram.len) return .{ .base = ram_base, .len = self.ram.len, .host = &self.ram, .writable = true };
        return .{ .base = address, .len = 1 };
    }

    fn at(self: *Memory, address: u32, comptime n: usize) ?*[n]u8 {
        const flash = address -% flash_base;
        if (@as(u64, flash) + n <= self.flash.len) return self.flash[flash..][0..n];
        const ram = address -% ram_base;
        if (@as(u64, ram) + n <= self.ram.len) return self.ram[ram..][0..n];
        return null;
    }

    fn program(self: *Memory, words: []const u32) void {
        for (words, 0..) |word, i| std.mem.writeInt(u32, self.flash[i * 4 ..][0..4], word, .little);
    }

    pub fn peek(self: *Memory, comptime width: u8, address: u32) ?Word(width) {
        return std.mem.readInt(Word(width), self.at(address, width) orelse return null, .little);
    }

    pub fn poke(self: *Memory, comptime width: u8, address: u32, value: Word(width)) ?void {
        std.mem.writeInt(Word(width), self.at(address, width) orelse return null, value, .little);
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

const ebreak: u32 = 0x0010_0073;
const mret: u32 = 0x3020_0073;
const lw_a0_a1: u32 = 0x0005_a503;
const sw_a0_a1: u32 = 0x00a5_a023;

fn csrw(number: csr.Protection, source: u5) u32 {
    return @as(u32, @intFromEnum(number)) << 20 | @as(u32, source) << 15 | 1 << 12 | 0x73;
}

fn csrr(number: csr.Protection, destination: u5) u32 {
    return @as(u32, @intFromEnum(number)) << 20 | 2 << 12 | @as(u32, destination) << 7 | 0x73;
}

fn started(memory: *Memory) Cpu {
    var cpu = Cpu.init(memory, .esp32c3, .{});
    cpu.reset();
    std.mem.writeInt(u32, memory.ram[0..4], ebreak, .little);
    cpu.state.csr.mtvec = ram_base | 1;
    return cpu;
}

fn enters(cpu: *Cpu, at: u32) void {
    cpu.state.csr.mepc = at;
    cpu.state.csr.mstatus.mpp = .user;
}

test "a fetch from a region without execute permission is an instruction access fault with the address in mtval, C3 TRM 1.8.3" {
    var memory: Memory = .{};
    memory.program(&.{ mret, ebreak });
    var cpu = started(&memory);
    napotEntry(&cpu.pmp, 0, flash_base, 4096, .{ .r = true });
    cpu.reguard();
    enters(&cpu, flash_base + 4);
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 1), cpu.state.csr.mcause);
    try std.testing.expectEqual(flash_base + 4, cpu.state.csr.mtval);
    try std.testing.expectEqual(flash_base + 4, cpu.state.csr.mepc);
}

test "a load from a region without read permission is a load access fault, code 5, with the address in mtval, C3 TRM 1.8.3" {
    var memory: Memory = .{};
    memory.program(&.{ mret, lw_a0_a1 });
    var cpu = started(&memory);
    napotEntry(&cpu.pmp, 0, flash_base, 4096, .{ .r = true, .x = true });
    napotEntry(&cpu.pmp, 1, ram_base, 4096, .{ .w = true });
    cpu.reguard();
    cpu.state.x[11] = ram_base + 8;
    enters(&cpu, flash_base + 4);
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 5), cpu.state.csr.mcause);
    try std.testing.expectEqual(ram_base + 8, cpu.state.csr.mtval);
}

test "a store into a region without write permission is a store access fault, code 7, with the address in mtval, C3 TRM 1.8.3" {
    var memory: Memory = .{};
    memory.program(&.{ mret, sw_a0_a1 });
    var cpu = started(&memory);
    napotEntry(&cpu.pmp, 0, flash_base, 4096, .{ .r = true, .x = true });
    napotEntry(&cpu.pmp, 1, ram_base, 4096, .{ .r = true });
    cpu.reguard();
    cpu.state.x[10] = 0x1234_5678;
    cpu.state.x[11] = ram_base + 8;
    enters(&cpu, flash_base + 4);
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 7), cpu.state.csr.mcause);
    try std.testing.expectEqual(ram_base + 8, cpu.state.csr.mtval);
    try std.testing.expectEqual(@as(u32, 0), memory.peek(4, ram_base + 8).?);
}

test "a user-mode load inside a granted region reaches the memory, C3 TRM 1.8.3" {
    var memory: Memory = .{};
    memory.program(&.{ mret, lw_a0_a1, ebreak });
    var cpu = started(&memory);
    napotEntry(&cpu.pmp, 0, flash_base, 4096, .{ .r = true, .x = true });
    napotEntry(&cpu.pmp, 1, ram_base, 4096, .{ .r = true });
    cpu.reguard();
    _ = memory.poke(4, ram_base + 8, 0x0bad_c0de);
    cpu.state.x[11] = ram_base + 8;
    enters(&cpu, flash_base + 4);
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 0x0bad_c0de), cpu.state.x[10]);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.csr.mcause);
}

test "a CSR instruction reaches the unit's registers, and a store the entry it wrote refuses faults at once, C3 TRM 1.8.4" {
    var memory: Memory = .{};
    memory.program(&.{ csrw(.pmpaddr0, 5), csrw(.pmpcfg0, 6), sw_a0_a1, ebreak });
    var cpu = started(&memory);
    cpu.state.x[5] = (ram_base + 8) >> 2;
    cpu.state.x[6] = 0x91;
    cpu.state.x[10] = 0x1234_5678;
    cpu.state.x[11] = ram_base + 8;
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, (ram_base + 8) >> 2), cpu.pmp.addr[0]);
    try std.testing.expectEqual(pmp.Mode.na4, cpu.pmp.cfg[0].mode);
    try std.testing.expect(cpu.pmp.cfg[0].l);
    try std.testing.expectEqual(@as(u32, 7), cpu.state.csr.mcause);
    try std.testing.expectEqual(ram_base + 8, cpu.state.csr.mtval);
}

test "a locked entry is what puts machine mode under the unit, and the word the run loop tests follows it, Privileged 3.7.1.2" {
    var memory: Memory = .{};
    memory.program(&.{ csrw(.pmpaddr0, 5), csrw(.pmpcfg0, 6), sw_a0_a1, ebreak });
    var cpu = started(&memory);
    try std.testing.expect(cpu.unguarded);
    cpu.state.x[5] = napot(ram_base, 4096);
    cpu.state.x[6] = 0x1b;
    cpu.state.x[10] = 0x1234_5678;
    cpu.state.x[11] = ram_base + 8;
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expect(cpu.unguarded);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), memory.peek(4, ram_base + 8).?);
}

test "a PMP register is a machine-mode register, so a user-mode read of one is an illegal instruction, C3 TRM 1.8.4" {
    var memory: Memory = .{};
    memory.program(&.{ mret, csrr(.pmpcfg0, 5) });
    var cpu = started(&memory);
    napotEntry(&cpu.pmp, 0, flash_base, 4096, .{ .r = true, .x = true });
    cpu.reguard();
    enters(&cpu, flash_base + 4);
    try std.testing.expectEqual(@as(?riscv.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 2), cpu.state.csr.mcause);
    try std.testing.expectEqual(csrr(.pmpcfg0, 5), cpu.state.csr.mtval);
}

test "the word the run loop tests is put back by a trap entry and by MRET, since what the unit refuses depends on the privilege" {
    var memory: Memory = .{};
    memory.program(&.{ mret, ebreak });
    var cpu = started(&memory);
    napotEntry(&cpu.pmp, 0, flash_base, 4096, .{ .r = true, .x = true, .l = true });
    cpu.reguard();
    try std.testing.expect(!cpu.unguarded);
    cpu.pmp.cfg[0].l = false;
    cpu.reguard();
    try std.testing.expect(cpu.unguarded);
    enters(&cpu, flash_base + 4);
    _ = cpu.run(.{ .instructions = 1 });
    try std.testing.expectEqual(csr.Privilege.user, cpu.state.privilege);
    try std.testing.expect(!cpu.unguarded);
}
