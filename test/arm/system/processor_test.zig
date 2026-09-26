const std = @import("std");
const Word = @import("../../../src/contract.zig").Word;
const arm = @import("../../../src/arm/root.zig");
const every: []const arm.Core = std.enums.values(arm.Core);
const Regions = @import("../../../src/memory/regions.zig").Regions;
const Width = @import("../../../src/memory/regions.zig").Width;
const Lines = @import("../../../src/memory/regions.zig").Lines;
const Folded = @import("../../../src/memory/regions.zig").Folded;
const Found = @import("../../../src/memory/regions.zig").Found;
const State = @import("isa").arm.State;
const Class = @import("isa").arm.instruction.Class;
const scb_block = @import("../../../src/arm/system/scb.zig");
const mpu_block = @import("../../../src/arm/system/mpu.zig");

const golden =
    \\at      0  pc=00000008 code=2001 movs r0, #1 ; r0=00000001
    \\at      1  pc=0000000a code=1c81 adds r1, r0, #2 ; r1=00000003
    \\at      2  pc=0000000c code=e000 b 0x10
    \\at      4  pc=00000010 code=be00 bkpt #0
    \\
;

const Memory = struct {
    bytes: [4096]u8 = @splat(0),
    folded: Folded = .{},

    pub fn lookup(self: *Memory, address: u32) Found {
        if (address >= self.bytes.len) return .{ .base = address, .len = 1 };
        return .{ .base = 0, .len = self.bytes.len, .host = &self.bytes, .writable = true };
    }

    fn slice(self: *Memory, address: u32, comptime n: usize) ?*[n]u8 {
        if (@as(u64, address) + n > self.bytes.len) return null;
        return self.bytes[address..][0..n];
    }

    pub fn peek(self: *Memory, comptime width: u8, address: u32) ?Word(width) {
        return std.mem.readInt(Word(width), self.slice(address, width) orelse return null, .little);
    }

    pub fn poke(self: *Memory, comptime width: u8, address: u32, value: Word(width)) ?void {
        std.mem.writeInt(Word(width), self.slice(address, width) orelse return null, value, .little);
    }

    pub fn parcel(self: *Memory, address: u32) ?u16 {
        return self.peek(2, address);
    }

    pub fn interrupts(_: *Memory) ?Lines {
        return null;
    }

    pub fn asserted(_: *const Memory) Lines {
        return 0;
    }

    pub fn follow(_: *Memory, _: *const u64, _: *u64) void {}

    pub fn untilDue(_: *const Memory) u64 {
        return std.math.maxInt(u64);
    }
};

const Fetching = struct {
    inner: Memory = .{},
    folded: Folded = .{},

    pub fn lookup(self: *Fetching, address: u32) Found {
        return self.inner.lookup(address);
    }

    pub fn peek(self: *Fetching, comptime width: u8, address: u32) ?Word(width) {
        return self.inner.peek(width, address);
    }

    pub fn poke(self: *Fetching, comptime width: u8, address: u32, value: Word(width)) ?void {
        return self.inner.poke(width, address, value);
    }

    pub fn parcel(self: *Fetching, address: u32) ?u16 {
        return self.inner.peek(2, address);
    }

    pub fn interrupts(self: *Fetching) ?Lines {
        return self.inner.interrupts();
    }

    pub fn asserted(self: *const Fetching) Lines {
        return self.inner.asserted();
    }

    pub fn follow(self: *Fetching, clock: *const u64, attention: *u64) void {
        return self.inner.follow(clock, attention);
    }

    pub fn untilDue(self: *const Fetching) u64 {
        return self.inner.untilDue();
    }
};

const Cpu = arm.Processor(.{ .cores = every, .Bus = Memory });
const CpuFetching = arm.Processor(.{ .cores = every, .Bus = Fetching });

var ring: [256]arm.trace.Record = undefined;

fn fast(core: arm.Core, memory: *Memory) Cpu {
    return Cpu.init(memory, core, .{}, .{});
}

fn traced(core: arm.Core, memory: *Memory) Cpu {
    return Cpu.init(memory, core, .{}, arm.trace.Ring.init(&ring) catch unreachable);
}

fn loaded() Memory {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x2000_2000, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 0x9, .little);
    for ([_]u16{ 0x2001, 0x1c81, 0xe000, 0xbe01, 0xbe00 }, 0..) |code, i| std.mem.writeInt(u16, m.bytes[8 + 2 * i ..][0..2], code, .little);
    return m;
}

fn setControl() Memory {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x800, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 0x9, .little);
    for ([_]u16{ 0x2004, 0xf380, 0x8814, 0xbe00 }, 0..) |code, i| std.mem.writeInt(u16, m.bytes[8 + 2 * i ..][0..2], code, .little);
    return m;
}

fn storeAndLoad(target: u32) Memory {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x800, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 0x9, .little);
    for ([_]u16{ 0x2005, 0x4902, 0x6008, 0x680a, 0xbe00 }, 0..) |code, i| std.mem.writeInt(u16, m.bytes[8 + 2 * i ..][0..2], code, .little);
    std.mem.writeInt(u32, m.bytes[0x14..0x18], target, .little);
    return m;
}

fn callAndReturn() Memory {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x800, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 0x9, .little);
    for ([_]u16{ 0xf241, 0x2034, 0xf2c5, 0x6078, 0xf000, 0xf802, 0x2000, 0xbe00, 0xb500, 0xb109, 0x2101, 0x2202, 0xbd00 }, 0..) |code, i| std.mem.writeInt(u16, m.bytes[8 + 2 * i ..][0..2], code, .little);
    return m;
}

fn releaseAndAcquire() Memory {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x800, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 0x9, .little);
    for ([_]u16{ 0xe97f, 0xe97f, 0x2007, 0xf240, 0x1100, 0xe8c1, 0x0faf, 0xe8d1, 0x2faf, 0xe841, 0xf300, 0xbe00 }, 0..) |code, i| std.mem.writeInt(u16, m.bytes[8 + 2 * i ..][0..2], code, .little);
    return m;
}

test "reset takes the stack pointer and the entry from the vector table, B1.5.5" {
    var m = loaded();
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(u32, 0x2000_2000), cpu.state.msp);
    try std.testing.expectEqual(@as(u32, 0x8), cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), cpu.state.lr);
    try std.testing.expectEqual(State.flag_t, cpu.state.xpsr);
    try std.testing.expect(!cpu.state.lockup);
}

test "the fast processor runs the tiny program to its breakpoint: three instructions, four cycles of Table 3-1, r0 = 1 and r1 = 3" {
    var m = loaded();
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(arm.Run{ .instructions = 3, .cycles = 4, .latency = 0, .stop = .breakpoint, .ended = .stopped }, ran);
    try std.testing.expectEqual(@as(u32, 1), cpu.state.r[0]);
    try std.testing.expectEqual(@as(u32, 3), cpu.state.r[1]);
    try std.testing.expectEqual(@as(u32, 0x10), cpu.state.pc);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.stop);
}

test "a step reports the class, the address and the cost of the instruction it ran, and charges the core that cost" {
    var m = loaded();
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(arm.Step{ .address = 0x8, .class = .data_processing, .cost = 1, .charged = 1, .sequential = false, .asleep = false, .stop = null }, cpu.step());
    try std.testing.expectEqual(@as(u64, 1), cpu.instructions);
    try std.testing.expectEqual(@as(u64, 1), cpu.cycles);
}

test "a step whose fetch follows the instruction before it is sequential, and the one after a taken branch is not" {
    var m = loaded();
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expect(!cpu.step().sequential);
    try std.testing.expect(cpu.step().sequential);
    const branch = cpu.step();
    try std.testing.expectEqual(@as(?Class, .branch), branch.class);
    try std.testing.expect(branch.sequential);
    const target = cpu.step();
    try std.testing.expectEqual(@as(u32, 0x10), target.address);
    try std.testing.expect(!target.sequential);
}

test "the debug processor runs the same program, its trace matches the golden lines, and each record carries the cycle count at which its instruction began" {
    var m = loaded();
    var cpu = traced(.m0plus, &m);
    cpu.reset();
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    while (true) {
        const before = cpu.cycles;
        const s = cpu.run(.{ .instructions = 1 });
        try arm.trace.writeLine(&w, cpu.trace.last().?, cpu.groups());
        try std.testing.expectEqual(before, cpu.trace.last().?.cycles);
        if (s.stop != null) break;
    }
    try std.testing.expectEqualStrings(golden, w.buffered());
    try std.testing.expectEqual(@as(u64, 3), cpu.instructions);
    try std.testing.expectEqual(@as(u64, 4), cpu.cycles);
}

test "the debug processor explains its stop" {
    var m = loaded();
    var cpu = traced(.m0plus, &m);
    cpu.reset();
    _ = cpu.run(.{ .instructions = 100 });
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try cpu.explain(&w, 8);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "The core stopped at BKPT #0 at pc=00000010.\n"));
}

test "a store and a load through the bus cost two cycles each, Table 3-1" {
    var m = storeAndLoad(0x400);
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(arm.Run{ .instructions = 4, .cycles = 7, .latency = 0, .stop = .breakpoint, .ended = .stopped }, ran);
    try std.testing.expectEqual(@as(u32, 5), cpu.state.r[2]);
    try std.testing.expectEqual(@as(?u32, 5), m.peek(4, 0x400));
}

test "the debug trace of a data access carries the address it touched" {
    var m = storeAndLoad(0x400);
    var cpu = traced(.m0plus, &m);
    cpu.reset();
    _ = cpu.run(.{ .instructions = 100 });
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try arm.trace.writeLast(&w, &cpu.trace, 8, cpu.groups());
    try std.testing.expectEqualStrings(
        \\at      0  pc=00000008 code=2005 movs r0, #5 ; r0=00000005
        \\at      1  pc=0000000a code=4902 ldr r1, [pc, #8] ; r1=00000400 mem=00000014
        \\at      3  pc=0000000c code=6008 str r0, [r1, #0] ; mem=00000400
        \\at      5  pc=0000000e code=680a ldr r2, [r1, #0] ; r2=00000005 mem=00000400
        \\at      7  pc=00000010 code=be00 bkpt #0
        \\
    , w.buffered());
}

test "a load from an address no memory answers locks the core up and the explanation names the address" {
    var m = storeAndLoad(0xffff_0000);
    var cpu = traced(.m0plus, &m);
    cpu.reset();
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(arm.Run{ .instructions = 2, .cycles = 3, .latency = 0, .stop = .data_fault, .ended = .stopped }, ran);
    try std.testing.expect(cpu.state.lockup);
    try std.testing.expectEqual(@as(u32, 0xc), cpu.state.pc);
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try cpu.explain(&w, 0);
    try std.testing.expectEqualStrings("No memory answered the data access to ffff0000 by the code 6008 at pc=0000000c. The core locked up.\n", w.buffered());
}

test "a word access to an address that is not a multiple of four locks the core up, A3.2.1" {
    var m = storeAndLoad(0x401);
    var cpu = traced(.m0plus, &m);
    cpu.reset();
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(arm.Run{ .instructions = 2, .cycles = 3, .latency = 0, .stop = .unaligned_access, .ended = .stopped }, ran);
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try cpu.explain(&w, 0);
    try std.testing.expectEqualStrings("The code 6008 at pc=0000000c accessed 00000401, which is not aligned to the size of the access. The core locked up.\n", w.buffered());
}

test "a load multiple that runs off the end of memory names the word that faulted and keeps the words before it, A6.7.25" {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x800, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 0x9, .little);
    for ([_]u16{ 0x4801, 0xc80e, 0xbe00, 0 }, 0..) |code, i| std.mem.writeInt(u16, m.bytes[8 + 2 * i ..][0..2], code, .little);
    std.mem.writeInt(u32, m.bytes[0x10..0x14], 0xff8, .little);
    std.mem.writeInt(u32, m.bytes[0xff8..0xffc], 7, .little);
    std.mem.writeInt(u32, m.bytes[0xffc..0x1000], 8, .little);
    var cpu = traced(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 1, .cycles = 2, .latency = 0, .stop = .data_fault, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
    try std.testing.expectEqual(@as(u32, 7), cpu.state.r[1]);
    try std.testing.expectEqual(@as(u32, 8), cpu.state.r[2]);
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try arm.trace.writeLine(&w, cpu.trace.last().?, cpu.groups());
    try cpu.explain(&w, 0);
    try std.testing.expectEqualStrings(
        \\at      2  pc=0000000a code=c80e ldm r0!, {r1, r2, r3} ; r1=00000007 r2=00000008 mem=00001000 refused=no_memory
        \\No memory answered the data access to 00001000 by the code c80e at pc=0000000a. The core locked up.
        \\
    , w.buffered());
}

test "a push that runs off the end of memory names the word that faulted and keeps the word before it, A6.7.50" {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x1004, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 0x9, .little);
    for ([_]u16{ 0x2001, 0xb403, 0xbe00 }, 0..) |code, i| std.mem.writeInt(u16, m.bytes[8 + 2 * i ..][0..2], code, .little);
    var cpu = traced(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 1, .cycles = 1, .latency = 0, .stop = .data_fault, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
    try std.testing.expectEqual(@as(?u32, 1), m.peek(4, 0xffc));
    try std.testing.expectEqual(@as(u32, 0x1004), cpu.state.msp);
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try arm.trace.writeLine(&w, cpu.trace.last().?, cpu.groups());
    try cpu.explain(&w, 0);
    try std.testing.expectEqualStrings(
        \\at      1  pc=0000000a code=b403 push {r0, r1} ; mem=00001000 refused=no_memory
        \\No memory answered the data access to 00001000 by the code b403 at pc=0000000a. The core locked up.
        \\
    , w.buffered());
}

test "a POP that loads an even address into PC locks the core up at the next step, A2.3.1" {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x800, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 0x9, .little);
    std.mem.writeInt(u16, m.bytes[8..10], 0xbd00, .little);
    std.mem.writeInt(u16, m.bytes[0x10..0x12], 0xbe00, .little);
    std.mem.writeInt(u32, m.bytes[0x800..0x804], 0x10, .little);
    var cpu = traced(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 1, .cycles = 4, .latency = 0, .stop = .not_t32_state, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
    try std.testing.expect(cpu.state.lockup);
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try arm.trace.writeLast(&w, &cpu.trace, 2, cpu.groups());
    try cpu.explain(&w, 0);
    try std.testing.expectEqualStrings(
        \\at      0  pc=00000008 code=bd00 pop {pc} ; sp=00000804 xpsr=00000000 mem=00000800
        \\at      4  pc=00000010 code=----
        \\The core reached pc=00000010 outside T32 state, because the address loaded into pc was even. The core locked up.
        \\
    , w.buffered());
}

test "a reset vector with an even entry never executes an instruction, B1.5.5" {
    var m = loaded();
    std.mem.writeInt(u32, m.bytes[4..8], 0x8, .little);
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(u32, 0), cpu.state.xpsr);
    try std.testing.expectEqual(arm.Run{ .instructions = 0, .cycles = 0, .latency = 0, .stop = .not_t32_state, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
    try std.testing.expectEqual(@as(u32, 0), cpu.state.r[0]);
}

test "a program reaches SysTick through its own loads and stores" {
    var m = storeAndLoad(0xe000_e014);
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(arm.Run{ .instructions = 4, .cycles = 7, .latency = 0, .stop = .breakpoint, .ended = .stopped }, ran);
    try std.testing.expectEqual(@as(u32, 5), cpu.systick.rvr);
    try std.testing.expectEqual(@as(u32, 5), cpu.state.r[2]);
}

test "the trace records belong to the caller, so a processor costs the same whether it traces and however deep" {
    var m: Memory = .{};
    var quiet = fast(.m0plus, &m);
    var deep: [1024]arm.trace.Record = undefined;
    var loud = Cpu.init(&m, .m0plus, .{}, try .init(&deep));
    try std.testing.expectEqual(@sizeOf(Cpu), @sizeOf(@TypeOf(quiet)));
    try std.testing.expectEqual(@sizeOf(Cpu), @sizeOf(@TypeOf(loud)));
    try std.testing.expect(!quiet.trace.recording());
    try std.testing.expect(loud.trace.recording());
    try std.testing.expect(@sizeOf(Cpu) < @sizeOf(arm.trace.Record) * deep.len);
}

test "a run stops at its instruction limit with no stop reason" {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x2000_2000, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 0x9, .little);
    std.mem.writeInt(u16, m.bytes[8..10], 0xe7fe, .little);
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    const ran = cpu.run(.{ .instructions = 1000 });
    try std.testing.expectEqual(arm.Run{ .instructions = 1000, .cycles = 2000, .latency = 0, .stop = null, .ended = .budget }, ran);
    try std.testing.expectEqual(@as(u32, 8), cpu.state.pc);
}

test "a run stops at the chip's deadline, one with no cycles to spend retires nothing, and the span after it carries on from there" {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x2000_2000, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 0x9, .little);
    std.mem.writeInt(u16, m.bytes[8..10], 0xe7fe, .little);
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 0, .cycles = 0, .latency = 0, .stop = null, .ended = .deadline }, cpu.run(.{ .instructions = 1000, .cycles = 0 }));
    try std.testing.expectEqual(arm.Run{ .instructions = 2, .cycles = 4, .latency = 0, .stop = null, .ended = .deadline }, cpu.run(.{ .instructions = 1000, .cycles = 4 }));
    try std.testing.expectEqual(arm.Run{ .instructions = 3, .cycles = 6, .latency = 0, .stop = null, .ended = .budget }, cpu.run(.{ .instructions = 3 }));
    try std.testing.expectEqual(@as(u64, 5), cpu.instructions);
}

test "an undefined instruction locks the core up and later steps do nothing" {
    var m = loaded();
    std.mem.writeInt(u16, m.bytes[8..10], 0xde00, .little);
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 0, .cycles = 0, .latency = 0, .stop = .undefined_instruction, .ended = .stopped }, cpu.run(.{ .instructions = 1 }));
    try std.testing.expect(cpu.state.lockup);
    try std.testing.expectEqual(arm.Run{ .instructions = 0, .cycles = 0, .latency = 0, .stop = .undefined_instruction, .ended = .stopped }, cpu.run(.{ .instructions = 1 }));
    try std.testing.expectEqual(@as(u64, 0), cpu.instructions);
}

test "a reset with no memory at the vector table locks the core up with a fetch fault" {
    const Nothing = struct {
        folded: Folded = .{},

        pub fn lookup(_: *@This(), address: u32) Found {
            return .{ .base = address, .len = 1 };
        }

        pub fn peek(_: *@This(), comptime width: u8, _: u32) ?Word(width) {
            return null;
        }
        pub fn poke(_: *@This(), comptime width: u8, _: u32, _: Word(width)) ?void {
            return null;
        }
        pub fn parcel(_: *@This(), _: u32) ?u16 {
            return null;
        }
        pub fn interrupts(_: *@This()) ?Lines {
            return null;
        }
        pub fn asserted(_: *const @This()) Lines {
            return 0;
        }
        pub fn follow(_: *@This(), _: *const u64, _: *u64) void {}

        pub fn untilDue(_: *const @This()) u64 {
            return std.math.maxInt(u64);
        }
    };
    var nothing: Nothing = .{};
    var cpu = arm.Processor(.{ .cores = every, .Bus = Nothing }).init(&nothing, .m0plus, .{}, try .init(&ring));
    try std.testing.expect(cpu.state.lockup);
    try std.testing.expectEqual(@as(?arm.Stop, .fetch_fault), cpu.stop);
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try cpu.explain(&w, 8);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "No memory answered the vector fetch from 00000000."));
}

test "two M7 parts of one processor type carry the caches each was built with, and keep them through a reset, M7 TRM 3.3.3 3.3.4 Table 3-7" {
    var m = loaded();
    var h723 = Cpu.init(&m, .m7, .{ .data = .kb32, .instruction = .kb32 }, .{});
    var f750 = Cpu.init(&m, .m7, .{ .data = .kb4, .instruction = .kb4 }, .{});
    var bare = Cpu.init(&m, .m7, .{}, .{});
    try std.testing.expectEqual(@as(?u32, 0xf01f_e019), h723.peek(4, 0xe000_ed80));
    try std.testing.expectEqual(@as(?u32, 0xf003_e019), f750.peek(4, 0xe000_ed80));
    try std.testing.expectEqual(@as(?u32, 0), bare.peek(4, 0xe000_ed80));
    try std.testing.expectEqual(@as(?u32, 0x0900_0003), f750.peek(4, 0xe000_ed78));
    try std.testing.expectEqual(@as(?u32, 0), bare.peek(4, 0xe000_ed78));
    try std.testing.expectEqual(@as(?void, {}), f750.poke(4, 0xe000_ed84, 1));
    try std.testing.expectEqual(@as(?u32, 0xf007_e009), f750.peek(4, 0xe000_ed80));
    try std.testing.expectEqual(@as(?void, {}), f750.poke(4, 0xe000_ed14, 0x0007_0200));
    try std.testing.expectEqual(@as(?void, {}), bare.poke(4, 0xe000_ed14, 0x0007_0200));
    try std.testing.expectEqual(@as(?u32, 0x0007_0200), f750.peek(4, 0xe000_ed14));
    try std.testing.expectEqual(@as(?u32, 0x0004_0200), bare.peek(4, 0xe000_ed14));
    try std.testing.expectEqual(@as(?void, {}), bare.poke(4, 0xe000_ef50, 0));
    f750.reset();
    try std.testing.expectEqual(@as(?u32, 0xf003_e019), f750.peek(4, 0xe000_ed80));
    try std.testing.expectEqual(@as(?u32, 0xf01f_e019), h723.peek(4, 0xe000_ed80));
    var four = Cpu.init(&m, .m4, .{ .data = .kb32, .instruction = .kb32 }, .{});
    try std.testing.expectEqual(@as(?u32, null), four.peek(4, 0xe000_ed78));
    try std.testing.expectEqual(@as(?void, null), four.poke(4, 0xe000_ef50, 0));
}

test "two M7 parts of one processor type read the TCM and AHBP sizes and enables each was wired with, keep them through a reset, and an M4 part refuses the addresses, M7 TRM 3.3.6 3.3.7 Table 3-1" {
    var m = loaded();
    var wide = Cpu.init(&m, .m7, .{ .itcm = .{ .size = .kb64, .enabled = true }, .dtcm = .{ .size = .kb128, .enabled = true }, .ahbp = .{ .size = .mb512, .enabled = true } }, .{});
    var small = Cpu.init(&m, .m7, .{ .itcm = .{ .size = .kb4 }, .dtcm = .{ .size = .kb8, .read_modify_write = true } }, .{});
    try std.testing.expectEqual(@as(?u32, 0x39), wide.peek(4, 0xe000_ef90));
    try std.testing.expectEqual(@as(?u32, 0x41), wide.peek(4, 0xe000_ef94));
    try std.testing.expectEqual(@as(?u32, 0x9), wide.peek(4, 0xe000_ef98));
    try std.testing.expectEqual(@as(?u32, 0x18), small.peek(4, 0xe000_ef90));
    try std.testing.expectEqual(@as(?u32, 0x22), small.peek(4, 0xe000_ef94));
    try std.testing.expectEqual(@as(?u32, 0), small.peek(4, 0xe000_ef98));
    try std.testing.expectEqual(@as(?void, {}), wide.poke(4, 0xe000_ef90, 0));
    try std.testing.expectEqual(@as(?u32, 0x38), wide.peek(4, 0xe000_ef90));
    wide.reset();
    try std.testing.expectEqual(@as(?u32, 0x39), wide.peek(4, 0xe000_ef90));
    var four = Cpu.init(&m, .m4, .{ .itcm = .{ .size = .kb64, .enabled = true } }, .{});
    try std.testing.expectEqual(@as(?u32, null), four.peek(4, 0xe000_ef90));
    try std.testing.expectEqual(@as(?void, null), four.poke(4, 0xe000_ef90, 0));
}

test "only the M7 answers 0xE000EF90 to 0xE000EFBC, the M7 refusing the words Table 3-1 reserves, and a processor type that lists no M7 holds no M7 control block, M7 TRM Table 3-1" {
    var m = loaded();
    const part: arm.Part = .{ .data = .kb32, .instruction = .kb32, .itcm = .{ .size = .kb64, .enabled = true }, .dtcm = .{ .size = .kb64, .enabled = true }, .ahbp = .{ .size = .mb64, .enabled = true }, .ecc = true };
    var seven = Cpu.init(&m, .m7, part, .{});
    for ([_]u32{ 0xe000_ef7c, 0xe000_ef80, 0xe000_ef84, 0xe000_ef88, 0xe000_ef8c, 0xe000_efa4, 0xe000_efac }) |address| {
        try std.testing.expectEqual(@as(?u32, null), seven.peek(4, address));
        try std.testing.expectEqual(@as(?void, null), seven.poke(4, address, 0));
    }
    for (every) |core| {
        if (core == .m7) continue;
        var cpu = Cpu.init(&m, core, part, .{});
        var address: u32 = 0xe000_ef90;
        while (address < 0xe000_efc0) : (address += 4) {
            try std.testing.expectEqual(@as(?u32, null), cpu.peek(4, address));
            try std.testing.expectEqual(@as(?void, null), cpu.poke(4, address, 0));
        }
    }
    try std.testing.expect(@FieldType(arm.Processor(.{ .cores = &.{.m4}, .Bus = Memory }), "m7") == void);
}

test "the M55 and M85 bank CSSELR, CCSIDR and CCR IC and DC between the Security states and read one CLIDR, CTR and maintenance range through either, M55 and M85 TRM 5.6.1 5.6.2 5.6.3 6.5, v8-M D1.2.12 D1.2.18 D1.1.29" {
    var m = loaded();
    inline for (.{ .m55, .m85 }) |core| {
        var cpu = Cpu.init(&m, core, .{ .data = .kb32, .instruction = .kb16 }, .{});
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed84, 1));
        try std.testing.expectEqual(@as(?u32, 0xf01f_e009), cpu.peek(4, 0xe000_ed80));
        try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe002_ed84));
        try std.testing.expectEqual(@as(?u32, 0xf01f_e019), cpu.peek(4, 0xe002_ed80));
        try std.testing.expectEqual(@as(?u32, 0x0920_0003), cpu.peek(4, 0xe002_ed78));
        try std.testing.expectEqual(@as(?u32, 0x8303_c003), cpu.peek(4, 0xe002_ed7c));
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed14, 0x0003_0201));
        try std.testing.expectEqual(@as(?u32, 0x0003_0201), cpu.peek(4, 0xe000_ed14));
        try std.testing.expectEqual(@as(?u32, 0x0000_0201), cpu.peek(4, 0xe002_ed14));
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe002_ef50, 0));
        cpu.reset();
        try std.testing.expectEqual(@as(?u32, 0xf01f_e019), cpu.peek(4, 0xe000_ed80));
    }
}

test "the processor answers SysTick at 0xE000E010 itself and faults the rest of the private peripheral bus" {
    var m = loaded();
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e014, 0x1234_5678));
    try std.testing.expectEqual(@as(?u32, 0x0034_5678), cpu.peek(4, 0xe000_e014));
    try std.testing.expectEqual(@as(?u32, 0x8000_0000), cpu.peek(4, 0xe000_e01c));
    try std.testing.expectEqual(@as(?u32, null), cpu.peek(4, 0xe000_e000));
    try std.testing.expectEqual(@as(?u32, 0xfa05_0000), cpu.peek(4, 0xe000_ed0c));
    try std.testing.expectEqual(@as(?void, null), cpu.poke(4, 0xe000_ed10, 0));
    try std.testing.expectEqual(@as(?u32, null), cpu.peek(4, 0xe000_e600));
    try std.testing.expectEqual(@as(?u16, null), cpu.peek(2, 0xe000_e010));
    try std.testing.expectEqual(@as(?u8, null), cpu.peek(1, 0xe000_e010));
    try std.testing.expectEqual(@as(?void, null), cpu.poke(2, 0xe000_e014, 1));
    try std.testing.expectEqual(@as(?void, null), cpu.poke(1, 0xe000_e014, 1));
    try std.testing.expectEqual(@as(?u16, null), cpu.parcel(0xe000_e010));
    try std.testing.expectEqual(@as(?u32, 0x2000_2000), cpu.peek(4, 0));
}

test "the whole NVIC window answers, so the start-up loop that clears every ICER and ICPR word runs to the end, B3.4.1" {
    var m = loaded();
    var cpu = fast(.m4, &m);
    cpu.reset();
    for (0..8) |i| {
        const step: u32 = @intCast(4 * i);
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e180 + step, 0xffff_ffff));
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e280 + step, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_e100 + step));
        try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_e200 + step));
    }
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_e5ec));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(1, 0xe000_e4a3, 0xff));
    try std.testing.expectEqual(@as(?u8, 0xf0), cpu.peek(1, 0xe000_e4a3));
    try std.testing.expectEqual(@as(u8, 0xf0), cpu.nvic.priority(163));
}

test "SysTick counts the four cycles of the program, wraps once with a reload of 2, and pends with TICKINT set" {
    var m = loaded();
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    _ = cpu.poke(4, 0xe000_e014, 2);
    _ = cpu.poke(4, 0xe000_e010, 0x3);
    _ = cpu.run(.{ .instructions = 100 });
    try std.testing.expect(cpu.pending & (1 << 15) != 0);
    try std.testing.expectEqual(@as(u32, 2), cpu.systick.cvr);
    try std.testing.expectEqual(@as(?u32, 0x7 | 0x1_0000), cpu.peek(4, 0xe000_e010));
}

test "arbitrary guest bytes never crash the host" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    for (0..256) |_| {
        var m: Memory = .{};
        random.bytes(&m.bytes);
        std.mem.writeInt(u32, m.bytes[4..8], (random.int(u32) & 0xffe) | 1, .little);
        var cpu = traced(.m0plus, &m);
        cpu.reset();
        _ = cpu.run(.{ .instructions = 10_000 });
        var buffer: [128]u8 = undefined;
        var discarding: std.Io.Writer.Discarding = .init(&buffer);
        try arm.trace.writeLast(&discarding.writer, &cpu.trace, 256, cpu.groups());
        try cpu.explain(&discarding.writer, 8);
    }
}

test "the M4 runs MOVW, MOVT, BL, PUSH, CBZ, and POP with the cycles of its Table 3-1" {
    var m = callAndReturn();
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 7, .cycles = 15, .latency = 0, .stop = .breakpoint, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
    try std.testing.expectEqual(@as(u32, 0x16), cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 0x15), cpu.state.lr);
    try std.testing.expectEqual(@as(u32, 0x800), cpu.state.msp);
}

test "MSR CONTROL sets FPCA on the M4, which has a floating-point unit, and leaves it reserved on the M0+, B1.4.4" {
    var m = setControl();
    var m4 = fast(.m4, &m);
    m4.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), m4.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(State.control_fpca, m4.state.control);
    var m0 = fast(.m0plus, &m);
    m0.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), m0.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 0), m0.state.control);
}

test "the M4 debug trace shows 32-bit codes with eight digits and the call through the stack" {
    var m = callAndReturn();
    var cpu = traced(.m4, &m);
    cpu.reset();
    _ = cpu.run(.{ .instructions = 100 });
    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try arm.trace.writeLast(&w, &cpu.trace, 8, cpu.groups());
    try std.testing.expectEqualStrings(
        \\at      0  pc=00000008 code=f2412034 movw r0, #4660 ; r0=00001234
        \\at      1  pc=0000000c code=f2c56078 movt r0, #22136 ; r0=56781234
        \\at      2  pc=00000010 code=f000f802 bl 0x18 ; lr=00000015
        \\at      5  pc=00000018 code=b500 push {lr} ; sp=000007fc mem=000007fc
        \\at      7  pc=0000001a code=b109 cbz r1, 0x20
        \\at     10  pc=00000020 code=bd00 pop {pc} ; sp=00000800 mem=000007fc
        \\at     14  pc=00000014 code=2000 movs r0, #0 ; r0=00000000 xpsr=41000000
        \\at     15  pc=00000016 code=be00 bkpt #0
        \\
    , w.buffered());
}

test "the M0+ locks up at the first ARMv7-M-only instruction of the same program, which ARMv6-M leaves undefined" {
    var m = callAndReturn();
    std.mem.writeInt(u32, m.bytes[12..16], 0, .little);
    var cpu = traced(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 0, .cycles = 0, .latency = 0, .stop = .undefined_instruction, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try cpu.explain(&w, 0);
    try std.testing.expectEqualStrings("The code f2412034 at pc=00000008 is not an instruction of this architecture. The core locked up.\n", w.buffered());
}

test "the M33 charges one cycle an instruction, because its own manual publishes no table" {
    var m = releaseAndAcquire();
    var cpu = fast(.m33, &m);
    cpu.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 6, .cycles = 6, .latency = 0, .stop = .breakpoint, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
    try std.testing.expectEqual(@as(u32, 0x1e), cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 7), cpu.state.r[2]);
    try std.testing.expectEqual(@as(u32, 0x004c_0000), cpu.state.r[3]);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, m.bytes[0x100..0x104], .little));
}

test "a step of the M4 reports the cycles its Table 3-1 publishes, and a step of the M33 reports none, because no table of its own exists" {
    var m = storeAndLoad(0x100);
    var cpu = fast(.m4, &m);
    cpu.reset();
    _ = cpu.step();
    const load = cpu.step();
    try std.testing.expectEqual(@as(?Class, .load), load.class);
    try std.testing.expectEqual(@as(?u8, 2), load.cost);
    var other = storeAndLoad(0x100);
    var m33 = fast(.m33, &other);
    m33.reset();
    _ = m33.step();
    const same = m33.step();
    try std.testing.expectEqual(@as(?Class, .load), same.class);
    try std.testing.expectEqual(@as(?u8, null), same.cost);
}

test "the M33 debug trace shows the ARMv8-M rows with their assembly text" {
    var m = releaseAndAcquire();
    var cpu = traced(.m33, &m);
    cpu.reset();
    _ = cpu.run(.{ .instructions = 100 });
    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try arm.trace.writeLast(&w, &cpu.trace, 8, cpu.groups());
    try std.testing.expectEqualStrings(
        \\at      0  pc=00000008 code=e97fe97f sg
        \\at      1  pc=0000000c code=2007 movs r0, #7 ; r0=00000007
        \\at      2  pc=0000000e code=f2401100 movw r1, #256 ; r1=00000100
        \\at      3  pc=00000012 code=e8c10faf stl r0, [r1] ; mem=00000100
        \\at      4  pc=00000016 code=e8d12faf lda r2, [r1] ; r2=00000007 mem=00000100
        \\at      5  pc=0000001a code=e841f300 tt r3, r1 ; r3=004c0000
        \\at      6  pc=0000001e code=be00 bkpt #0
        \\
    , w.buffered());
}

test "with no HardFault handler the M4 locks up on the first ARMv8-M-only instruction of the same program, which ARMv7-M leaves undefined, A5.3" {
    var m = releaseAndAcquire();
    std.mem.writeInt(u32, m.bytes[12..16], 0, .little);
    var cpu = traced(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 0, .cycles = 0, .latency = 0, .stop = .undefined_instruction, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try cpu.explain(&w, 0);
    try std.testing.expectEqualStrings(
        \\The code e97fe97f at pc=00000008 is not an instruction of this architecture. The core locked up.
        \\CFSR=00010000 (UNDEFINSTR) HFSR=00000000 MMFAR=00000000 BFAR=00000000
        \\
    , w.buffered());
}

test "an undefined wide encoding on the M4 escalates to HardFault and locks up fetching the handler from an execute-never region, B1.5.14 B3.1" {
    var m = releaseAndAcquire();
    var cpu = traced(.m4, &m);
    cpu.reset();
    const ran = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?arm.Stop, .fetch_violation), ran.stop);
    try std.testing.expectEqual(@as(u64, 0), ran.instructions);
    try std.testing.expectEqual(@as(u64, 12), ran.cycles);
    try std.testing.expectEqual(@as(u32, 0xf240_2006), cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 0xffff_fff9), cpu.state.lr);
    try std.testing.expectEqual(@as(u32, 0x0100_0003), cpu.state.xpsr);
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try cpu.explain(&w, 0);
    try std.testing.expectEqualStrings(
        \\The instruction fetch from pc=f2402006 reached memory the Memory Protection Unit does not let this code execute. The core locked up.
        \\The core took a UsageFault at pc=00000008 as HardFault: the code e97fe97f is not an instruction of this architecture.
        \\CFSR=00010001 (IACCVIOL UNDEFINSTR) HFSR=40000000 MMFAR=00000000 BFAR=00000000
        \\
    , w.buffered());
}

fn readsMspLimit() Memory {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x800, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 0x9, .little);
    for ([_]u16{ 0xf3ef, 0x800a, 0xbe00 }, 0..) |code, i| std.mem.writeInt(u16, m.bytes[8 + 2 * i ..][0..2], code, .little);
    return m;
}

test "MRS from MSPLIM on the M33 reads the Secure stack limit, which resets to zero, D1.2.177" {
    var m = readsMspLimit();
    var cpu = fast(.m33, &m);
    cpu.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 1, .cycles = 1, .latency = 0, .stop = .breakpoint, .ended = .stopped }, cpu.run(.{ .instructions = 20 }));
    try std.testing.expectEqual(@as(u32, 0), cpu.state.r[0]);
    try std.testing.expectEqual(@as(u32, 0xc), cpu.state.pc);
}

fn callAndExchange() Memory {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x800, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 0x9, .little);
    for ([_]u16{ 0xf000, 0xf801, 0xbe00, 0x4770 }, 0..) |code, i| std.mem.writeInt(u16, m.bytes[8 + 2 * i ..][0..2], code, .little);
    return m;
}

test "the M0+ charges BL three cycles and BX two, Table 3-1, while the M4 charges BL like B" {
    var m = callAndExchange();
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 2, .cycles = 5, .latency = 0, .stop = .breakpoint, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
    m = callAndExchange();
    var cpu4 = fast(.m4, &m);
    cpu4.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 2, .cycles = 6, .latency = 0, .stop = .breakpoint, .ended = .stopped }, cpu4.run(.{ .instructions = 100 }));
}

test "the core does not fetch from the execute-never regions of the default memory map and locks up with a MemManage violation, B3.1 B3.5.2" {
    for ([_]u32{ 0x4000_0000, 0xa000_0000, 0xe000_0000, 0xf000_0000 }) |base| {
        var vectors: [8]u8 = undefined;
        std.mem.writeInt(u32, vectors[0..4], 0x2000_1000, .little);
        std.mem.writeInt(u32, vectors[4..8], base + 1, .little);
        var code: [4]u8 = .{ 0x2a, 0x20, 0x00, 0xbe };
        var entries = [_]Regions.Entry{
            .{ .memory = .{ .base = 0, .bytes = &vectors, .writable = false } },
            .{ .memory = .{ .base = base, .bytes = &code, .writable = false } },
        };
        var regions = try Regions.adopt(&entries);
        var cpu = arm.Processor(.{ .cores = every, .Bus = Regions }).init(&regions, .m0plus, .{}, .{});
        cpu.reset();
        const ran = cpu.run(.{ .instructions = 10 });
        try std.testing.expectEqual(@as(u64, 0), ran.instructions);
        try std.testing.expectEqual(@as(?arm.Stop, .fetch_violation), ran.stop);
        try std.testing.expect(cpu.state.lockup);
        try std.testing.expectEqual(base, cpu.state.pc);
    }
}

test "a run or a step after a breakpoint continues past it instead of hitting it again" {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x1000, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 9, .little);
    for ([_]u16{ 0x2001, 0xbe00, 0x2002, 0xbe01, 0x2003, 0xbe02 }, 0..) |code, i| std.mem.writeInt(u16, m.bytes[8 + i * 2 ..][0..2], code, .little);
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 1, .cycles = 1, .latency = 0, .stop = .breakpoint, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
    try std.testing.expectEqual(@as(u32, 0xa), cpu.state.pc);
    try std.testing.expectEqual(arm.Run{ .instructions = 1, .cycles = 1, .latency = 0, .stop = .breakpoint, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
    try std.testing.expectEqual(@as(u32, 0xe), cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 2), cpu.state.r[0]);
    try std.testing.expectEqual(arm.Run{ .instructions = 1, .cycles = 1, .latency = 0, .stop = null, .ended = .budget }, cpu.run(.{ .instructions = 1 }));
    try std.testing.expectEqual(@as(u32, 3), cpu.state.r[0]);
    try std.testing.expectEqual(arm.Run{ .instructions = 0, .cycles = 0, .latency = 0, .stop = .breakpoint, .ended = .stopped }, cpu.run(.{ .instructions = 1 }));
    try std.testing.expectEqual(@as(u32, 0x12), cpu.state.pc);
}

test "a run that continues past a BKPT inside an IT block advances ITSTATE with the program counter, C1.6 A7.3.3" {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x1000, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 9, .little);
    for ([_]u16{ 0x2000, 0xbf0c, 0xbe00, 0x2001, 0xbe01 }, 0..) |code, i| std.mem.writeInt(u16, m.bytes[8 + i * 2 ..][0..2], code, .little);
    var cpu = arm.Processor(.{ .cores = every, .Bus = Memory }).init(&m, .m3, .{}, .{});
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 0xc), cpu.state.pc);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 0x10), cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.r[0]);
}

test "MRS, MSR, and a barrier cost three cycles each on the M0+ and one each on the M4, the M0+ TRM 3.3 and the M4 TRM 3.3" {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x1000, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 9, .little);
    for ([_]u16{ 0xf3ef, 0x8008, 0xf380, 0x8808, 0xf3bf, 0x8f4f, 0xbe00 }, 0..) |code, i| std.mem.writeInt(u16, m.bytes[8 + i * 2 ..][0..2], code, .little);
    var m0 = fast(.m0plus, &m);
    m0.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 3, .cycles = 9, .latency = 0, .stop = .breakpoint, .ended = .stopped }, m0.run(.{ .instructions = 100 }));
    try std.testing.expectEqual(@as(u32, 0x1000), m0.state.r[0]);
    var m4 = arm.Processor(.{ .cores = every, .Bus = Memory }).init(&m, .m4, .{}, .{});
    m4.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 3, .cycles = 3, .latency = 0, .stop = .breakpoint, .ended = .stopped }, m4.run(.{ .instructions = 100 }));
}

fn placed(vectors: []const u32, at: []const u32, code: []const []const u16) Memory {
    var m: Memory = .{};
    for (vectors, 0..) |v, i| std.mem.writeInt(u32, m.bytes[i * 4 ..][0..4], v, .little);
    for (at, code) |base, halfwords| {
        for (halfwords, 0..) |h, i| std.mem.writeInt(u16, m.bytes[base + i * 2 ..][0..2], h, .little);
    }
    return m;
}

const svc_vectors = [_]u32{ 0x1000, 0x41, 0, 0xa1, 0, 0, 0, 0, 0, 0, 0, 0x61, 0, 0, 0, 0x81 };

test "SVCall stacks eight words, enters the handler with EXC_RETURN in lr and 11 in IPSR, and returns to the next instruction with the registers and stack restored, B1.5.6 B1.5.8" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
        &.{ 0x2001, 0x2102, 0x2203, 0x2304, 0xdf07, 0x2109, 0xbe00 },
        &.{ 0xf3ef, 0x8408, 0x69a7, 0x69e4, 0x4675, 0xf3ef, 0x8605, 0x2000, 0x4770 },
    });
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 13, .cycles = 45, .latency = 25, .stop = .breakpoint, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
    try std.testing.expectEqual([_]u32{ 1, 9, 3, 4, 0x0100_0000, 0xffff_fff9, 11, 0x4a }, cpu.state.r[0..8].*);
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.state.msp);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), cpu.state.lr);
    try std.testing.expectEqual(@as(u32, 0x0100_0000), cpu.state.xpsr);
    try std.testing.expectEqual(@as(u32, 0x4c), cpu.state.pc);
    try std.testing.expectEqual(@as(u64, 0), cpu.active);
}

test "SysTick preempts Thread mode when its counter wraps, and PRIMASK holds it pending until cleared, B1.5.4" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x80 }, &.{
        &.{ 0xb672, 0xbf00, 0xbf00, 0xbf00, 0xbf00, 0xb662, 0xe7fe },
        &.{ 0x3401, 0x4770 },
    });
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    cpu.systick.csr = cortex_systick.enable | cortex_systick.tickint;
    cpu.systick.rvr = 3;
    try std.testing.expectEqual(arm.Run{ .instructions = 6, .cycles = 6, .latency = 0, .stop = null, .ended = .budget }, cpu.run(.{ .instructions = 6 }));
    try std.testing.expectEqual(@as(u32, 0), cpu.state.r[4]);
    try std.testing.expectEqual(@as(u64, 1 << 15), cpu.pending);
    try std.testing.expectEqual(arm.Run{ .instructions = 2, .cycles = 15 + 1 + 2 + 10, .latency = 15 + 10, .stop = null, .ended = .budget }, cpu.run(.{ .instructions = 2 }));
    try std.testing.expectEqual(@as(u32, 1), cpu.state.r[4]);
    try std.testing.expectEqual(@as(u32, 0x4c), cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), cpu.state.lr);
    try std.testing.expectEqual(@as(u32, 0x0100_0000), cpu.state.xpsr);
    _ = cpu.run(.{ .instructions = 60 });
    try std.testing.expect(cpu.state.r[4] > 5);
}

test "a Thread on the process stack keeps its frame there, runs the handler on the main stack, and returns with EXC_RETURN 0xFFFFFFFD, B1.5.6" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
        &.{ 0x2002, 0xf380, 0x8814, 0xdf00, 0xbe00 },
        &.{ 0x4675, 0xf3ef, 0x8608, 0xf3ef, 0x8709, 0x4770 },
    });
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    cpu.state.psp = 0x800;
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual([_]u32{ 0xffff_fffd, 0x1000, 0x7e0 }, cpu.state.r[5..8].*);
    try std.testing.expectEqual(@as(u32, 0x800), cpu.state.psp);
    try std.testing.expectEqual(State.control_spsel, cpu.state.control);
    try std.testing.expectEqual(@as(u32, 0x800), cpu.state.sp());
}

test "a higher priority SysTick preempts the SVCall handler with EXC_RETURN 0xFFFFFFF1, and an equal priority one waits for it to return, B1.5.4" {
    for ([_]u32{ 0xc000_0000, 0 }, [_]u32{ 0xffff_fff1, 0xffff_fff9 }) |shpr2, lr| {
        var m = placed(&svc_vectors, &.{ 0x40, 0x60, 0x80 }, &.{
            &.{ 0xdf00, 0xbe00 },
            &.{ 0xbf00, 0xbf00, 0xbf00, 0xbf00, 0xf3ef, 0x8705, 0x4770 },
            &.{ 0x4675, 0xf3ef, 0x8605, 0xb672, 0x4770 },
        });
        var cpu = fast(.m0plus, &m);
        cpu.reset();
        _ = cpu.scb.writeRegister(cortex_scb.shpr2, shpr2);
        cpu.systick.csr = cortex_systick.enable | cortex_systick.tickint;
        cpu.systick.rvr = 19;
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        try std.testing.expectEqual(lr, cpu.state.r[5]);
        try std.testing.expectEqual(@as(u32, 15), cpu.state.r[6]);
        try std.testing.expectEqual(@as(u32, 11), cpu.state.r[7]);
        try std.testing.expectEqual(@as(u32, 0x0100_0000), cpu.state.xpsr);
    }
}

test "an SVC that cannot preempt escalates to HardFault, which enters with EXC_RETURN 0xFFFFFFF1 and 3 in IPSR, B1.5.4" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60, 0xa0 }, &.{
        &.{ 0xdf00, 0xbe00 },
        &.{ 0xdf01, 0x4770 },
        &.{ 0x4675, 0xf3ef, 0x8605, 0xbe00 },
    });
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual([_]u32{ 0xffff_fff1, 3 }, cpu.state.r[5..7].*);
    try std.testing.expectEqual(@as(u64, (1 << 3) | (1 << 11)), cpu.active);
    try std.testing.expectEqual(@as(u64, 0), cpu.pending >> 1);
}

test "entry aligns the frame to eight bytes, records the padding in bit 9 of the stacked xPSR, and return restores the unaligned stack pointer, B1.5.6 B1.5.8" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
        &.{ 0xb081, 0xdf00, 0xf3ef, 0x8708, 0xbe00 },
        &.{ 0xf3ef, 0x8408, 0x69e5, 0x4770 },
    });
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual([_]u32{ 0xfd8, 0x0100_0200 }, cpu.state.r[4..6].*);
    try std.testing.expectEqual(@as(u32, 0xffc), cpu.state.r[7]);
}

test "an EXC_RETURN that does not match the active exceptions locks the core up, B1.5.8" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
        &.{ 0xdf00, 0xbe00 },
        &.{ 0x2010, 0x4240, 0x4700 },
    });
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .exception_return), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expect(cpu.state.lockup);
    try std.testing.expectEqual(arm.Run{ .instructions = 0, .cycles = 0, .latency = 0, .stop = .exception_return, .ended = .stopped }, cpu.run(.{ .instructions = 1 }));
}

test "the M4 charges 12 cycles to enter an exception and 10 to return, M4 TRM 3.9.2" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
        &.{ 0xdf00, 0xbe00 },
        &.{0x4770},
    });
    var cpu = arm.Processor(.{ .cores = every, .Bus = Memory }).init(&m, .m4, .{}, .{});
    cpu.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 2, .cycles = 1 + 12 + 3 + 10, .latency = 12 + 10, .stop = .breakpoint, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
}

test "the M3 charges 12 cycles to enter an exception and 12 to return, M3 TRM 3.9.2" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
        &.{ 0xdf00, 0xbe00 },
        &.{0x4770},
    });
    var cpu = arm.Processor(.{ .cores = every, .Bus = Memory }).init(&m, .m3, .{}, .{});
    cpu.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 2, .cycles = 1 + 12 + 3 + 12, .latency = 12 + 12, .stop = .breakpoint, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
}

test "the step that enters an exception retires no instruction and reports the entry latency it charged, M4 TRM 3.9.2" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
        &.{ 0xdf00, 0xbe00 },
        &.{0x4770},
    });
    var cpu = arm.Processor(.{ .cores = every, .Bus = Memory }).init(&m, .m4, .{}, .{});
    cpu.reset();
    const call = cpu.step();
    try std.testing.expectEqual(@as(?Class, .system), call.class);
    try std.testing.expectEqual(@as(u8, 1), call.charged);
    const entry = cpu.step();
    try std.testing.expectEqual(@as(?Class, null), entry.class);
    try std.testing.expectEqual(@as(?u8, null), entry.cost);
    try std.testing.expectEqual(@as(u8, 12), entry.charged);
    try std.testing.expectEqual(@as(u64, 1), cpu.instructions);
    try std.testing.expectEqual(@as(u64, 13), cpu.cycles);
    try std.testing.expectEqual(@as(u32, 0x60), cpu.state.pc);
}

test "the trace shows an exception entry and return as lines without a code that carry the registers they changed" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
        &.{ 0xdf00, 0xbe00 },
        &.{0x4770},
    });
    var cpu = traced(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try arm.trace.writeLast(&w, &cpu.trace, 5, cpu.groups());
    try std.testing.expectEqualStrings(
        \\at      0  pc=00000040 code=df00 svc #0
        \\at      1  pc=00000060 code=---- ; sp=00000fe0 lr=fffffff9 xpsr=0100000b entry=11 latency=15
        \\at     16  pc=00000060 code=4770 bx lr
        \\at     18  pc=00000042 code=---- ; sp=00001000 lr=ffffffff xpsr=01000000 return latency=10
        \\at     28  pc=00000042 code=be00 bkpt #0
        \\
    , w.buffered());
}

const cortex_systick = @import("../../../src/arm/system/systick.zig").SysTick;
const cortex_scb = @import("../../../src/arm/system/scb.zig");

test "an SVCall escalated to HardFault records HFSR.FORCED, B3.2.16" {
    var m = placed(&svc_vectors, &.{ 0x40, 0xa0 }, &.{
        &.{ 0xb672, 0xdf00, 0xbe00 },
        &.{0xbe00},
    });
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 3), cpu.state.xpsr & State.ipsr_mask);
    try std.testing.expectEqual(@as(?u32, scb_block.forced), cpu.peek(4, 0xe000_ed2c));
}

test "an SVC inside the HardFault handler cannot escalate any further and locks the core up, B1.5.14" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60, 0xa0 }, &.{
        &.{ 0xdf00, 0xbe00 },
        &.{ 0xdf01, 0x4770 },
        &.{ 0xdf02, 0xbe00 },
    });
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .unrecoverable_exception), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expect(cpu.state.lockup);
    try std.testing.expectEqual(@as(u32, 0xa2), cpu.state.pc);
    try std.testing.expectEqual(@as(u64, (1 << 3) | (1 << 11)), cpu.active);
    const again = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(u64, 0), again.instructions);
    try std.testing.expectEqual(@as(?arm.Stop, .unrecoverable_exception), again.stop);
}

test "the M4 and M33 accept aligned byte and halfword accesses to SHPR2, SHPR3, and the IPR words only, and the M0+ answers only words, v7-M B3.2.2 B3.2.11 B3.4.9, v8-M D1.2.235 D1.2.236 D1.2.185" {
    inline for (.{ .m4, .m33 }) |core| {
        var m: Memory = .{};
        var cpu = fast(core, &m);
        cpu.reset();
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(1, 0xe000_ed23, 0xf0));
        try std.testing.expectEqual(@as(?u32, 0xf000_0000), cpu.peek(4, 0xe000_ed20));
        try std.testing.expectEqual(@as(?u8, 0xf0), cpu.peek(1, 0xe000_ed23));
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(2, 0xe000_ed22, 0xc0c0));
        try std.testing.expectEqual(@as(?u16, 0xc0c0), cpu.peek(2, 0xe000_ed22));
        try std.testing.expectEqual(@as(?void, null), cpu.poke(2, 0xe000_ed23, 0x0f0f));
        try std.testing.expectEqual(@as(?u16, null), cpu.peek(2, 0xe000_ed23));
        try std.testing.expectEqual(@as(?u32, 0xc0c0_0000), cpu.peek(4, 0xe000_ed20));
        try std.testing.expectEqual(@as(?u8, null), cpu.peek(1, 0xe000_ed00));
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(1, 0xe000_e401, 0xf0));
        try std.testing.expectEqual(@as(?u32, 0xf000), cpu.peek(4, 0xe000_e400));
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e100, 0x101));
        try std.testing.expectEqual(@as(?void, null), cpu.poke(1, 0xe000_e180, 0x01));
        try std.testing.expectEqual(@as(?u32, 0x101), cpu.peek(4, 0xe000_e100));
        try std.testing.expectEqual(@as(?void, null), cpu.poke(1, 0xe000_e200, 0x01));
        try std.testing.expectEqual(@as(?void, null), cpu.poke(1, 0xe000_ed04, 0));
        try std.testing.expectEqual(@as(?u8, null), cpu.peek(1, 0xe000_ed08));
    }
    var m: Memory = .{};
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, null), cpu.poke(1, 0xe000_ed23, 0xf0));
    try std.testing.expectEqual(@as(?u8, null), cpu.peek(1, 0xe000_ed23));
}

test "CFSR answers a byte or halfword access to each of the three fault status registers it holds, and a narrow write clears only the lane it names, B3.2.14 B3.2.15" {
    var m: Memory = .{};
    var cpu = fast(.m4, &m);
    cpu.reset();
    cpu.scb.fault(.undefined_instruction, 0);
    cpu.scb.fault(.data_violation, 0x20);
    try std.testing.expectEqual(@as(?u16, 1), cpu.peek(2, 0xe000_ed2a));
    try std.testing.expectEqual(@as(?u8, 0), cpu.peek(1, 0xe000_ed29));
    try std.testing.expectEqual(@as(?u8, 0x82), cpu.peek(1, 0xe000_ed28));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(2, 0xe000_ed2a, 1));
    try std.testing.expectEqual(@as(?u32, 0x0000_0082), cpu.peek(4, 0xe000_ed28));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(1, 0xe000_ed28, 0x82));
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ed28));
}

test "the M4 keeps four priority bits, so a SysTick at 0x10 preempts an SVCall handler at 0x20 and one at 0x20 waits for a handler at 0x10, B1.5.4" {
    for ([_]u32{ 0x20, 0x10 }, [_]u32{ 0x10, 0x20 }, [_]u32{ 0xffff_fff1, 0xffff_fff9 }) |svc_priority, tick_priority, lr| {
        var m = placed(&svc_vectors, &.{ 0x40, 0x60, 0x80 }, &.{
            &.{ 0xdf00, 0xbe00 },
            &.{ 0xbf00, 0xbf00, 0xbf00, 0xbf00, 0xf3ef, 0x8705, 0x4770 },
            &.{ 0x4675, 0xf3ef, 0x8605, 0xb672, 0x4770 },
        });
        var cpu = fast(.m4, &m);
        cpu.reset();
        _ = cpu.poke(4, 0xe000_ed1c, svc_priority << 24);
        _ = cpu.poke(4, 0xe000_ed20, tick_priority << 24);
        cpu.systick.csr = cortex_systick.enable | cortex_systick.tickint;
        cpu.systick.rvr = 14;
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        try std.testing.expectEqual(lr, cpu.state.r[5]);
        try std.testing.expectEqual(@as(u32, 15), cpu.state.r[6]);
        try std.testing.expectEqual(@as(u32, 11), cpu.state.r[7]);
    }
}

test "BASEPRI holds a lower priority SysTick pending on the M4 until it is cleared, B1.5.4" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x80 }, &.{
        &.{ 0x2040, 0xf380, 0x8811, 0xf3ef, 0x8111, 0x2220, 0x3a01, 0xd1fd, 0x2000, 0xf380, 0x8811, 0xbe00 },
        &.{ 0x4675, 0xb672, 0x4770 },
    });
    var cpu = fast(.m4, &m);
    cpu.reset();
    _ = cpu.poke(4, 0xe000_ed20, 0xc000_0000);
    cpu.systick.csr = cortex_systick.enable | cortex_systick.tickint;
    cpu.systick.rvr = 9;
    try std.testing.expectEqual(@as(?arm.Stop, null), cpu.run(.{ .instructions = 8 }).stop);
    try std.testing.expectEqual(@as(u32, 0x40), cpu.state.r[1]);
    try std.testing.expect(cpu.pending & (1 << 15) != 0);
    try std.testing.expectEqual(@as(u64, 0), cpu.active);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 200 }).stop);
    try std.testing.expectEqual(@as(u32, 0xffff_fff9), cpu.state.r[5]);
}

test "a return with a reserved EXC_RETURN records UFSR.INVPC and is taken as UsageFault where that handler is enabled, and as a forced HardFault where it is not, B1.5.8" {
    for ([_]bool{ false, true }) |enabled| {
        var m = placed(&.{ 0x1000, 0x41, 0, 0xa1, 0, 0, 0x81, 0, 0, 0, 0, 0x61 }, &.{ 0x40, 0x60, 0x80, 0xa0 }, &.{
            &.{ 0xdf00, 0xbe00 },
            &.{ 0x200a, 0x43c0, 0x4700 },
            &.{ 0x4675, 0xf3ef, 0x8605, 0xbe00 },
            &.{ 0xf3ef, 0x8705, 0xbe00 },
        });
        var cpu = fast(.m4, &m);
        cpu.reset();
        if (enabled) _ = cpu.poke(4, 0xe000_ed24, scb_block.usgfaultena);
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        try std.testing.expectEqual(@as(?u32, 0x0004_0000), cpu.peek(4, 0xe000_ed28));
        if (enabled) {
            try std.testing.expectEqual(@as(u32, 6), cpu.state.r[6]);
            try std.testing.expectEqual(@as(u32, 0xffff_fff5), cpu.state.r[5]);
            try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ed2c));
        } else {
            try std.testing.expectEqual(@as(u32, 3), cpu.state.r[7]);
            try std.testing.expectEqual(scb_block.forced, cpu.peek(4, 0xe000_ed2c).? & scb_block.forced);
        }
    }
}

test "an exception return to Thread mode with a nonzero IPSR in the frame is INVPC, which the M4 escalates to HardFault with the failed EXC_RETURN in lr and the M0+ treats as a lockup, B1.5.8" {
    const code = [_][]const u16{
        &.{ 0xdf00, 0xbe00 },
        &.{ 0x9807, 0x3003, 0x9007, 0x4770 },
        &.{ 0x4675, 0x9807, 0x0a40, 0x0240, 0x9007, 0x4770 },
    };
    var m = placed(&svc_vectors, &.{ 0x40, 0x60, 0xa0 }, &code);
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 0x42), cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 0xffff_fff9), cpu.state.r[5]);
    try std.testing.expectEqual(@as(u64, 0), cpu.active);
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.state.msp);
    var m0 = placed(&svc_vectors, &.{ 0x40, 0x60, 0xa0 }, &code);
    var cpu0 = fast(.m0plus, &m0);
    cpu0.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .exception_return), cpu0.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 0x42), cpu0.state.pc);
}

test "a return to Thread mode with another exception still active needs CCR.NONBASETHRDENA on the M4 and is allowed outright on the M33, B1.5.8 E2.1.420" {
    for ([_]struct { core: arm.Core, allowed: bool }{
        .{ .core = .m4, .allowed = false },
        .{ .core = .m4, .allowed = true },
        .{ .core = .m33, .allowed = true },
    }) |case| {
        var m = placed(&.{ 0x1000, 0x41, 0, 0xa1, 0, 0, 0, 0, 0, 0, 0, 0x61, 0, 0, 0x81, 0 }, &.{ 0x40, 0x60, 0x80, 0xa0 }, &.{
            &.{ 0xdf00, 0xbe00 },
            &.{ 0x4b04, 0x2201, 0x0712, 0x601a, 0xf3ef, 0x8705, 0xbe00, 0x0000, 0x0000, 0x0000, 0xed04, 0xe000 },
            &.{ 0x9807, 0x0a40, 0x0240, 0x9007, 0x2006, 0x43c0, 0x4700 },
            &.{ 0x4675, 0xf3ef, 0x8605, 0xbe00 },
        });
        var cpu = fast(case.core, &m);
        cpu.reset();
        _ = cpu.poke(4, 0xe000_ed1c, 0xc000_0000);
        if (case.allowed and case.core == .m4) _ = cpu.poke(4, 0xe000_ed14, cortex_scb.stkalign | cortex_scb.nonbasethrdena);
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        if (case.allowed) {
            try std.testing.expectEqual(@as(u32, 0), cpu.state.r[7]);
            try std.testing.expectEqual(@as(u64, 1) << 11, cpu.active);
        } else {
            try std.testing.expectEqual(@as(u32, 3), cpu.state.r[6]);
        }
    }
}

test "a run of zero instructions executes nothing, reports no stop of its own and leaves the standing breakpoint in place" {
    var m = placed(&.{ 0x1000, 0x9 }, &.{0x8}, &.{&.{ 0xbe00, 0x2001, 0xbe01 }});
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    const nothing = cpu.run(.{ .instructions = 0 });
    try std.testing.expectEqual(arm.Run{ .instructions = 0, .cycles = 0, .latency = 0, .stop = null, .ended = .budget }, nothing);
    try std.testing.expectEqual(@as(u32, 0x8), cpu.state.pc);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.stop);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 0xc), cpu.state.pc);
}

test "a run whose cycle deadline is already reached executes nothing and leaves the standing breakpoint in place" {
    var m = placed(&.{ 0x1000, 0x9 }, &.{0x8}, &.{&.{ 0xbe00, 0x2001, 0xbe01 }});
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    const nothing = cpu.run(.{ .instructions = 100, .cycles = 0 });
    try std.testing.expectEqual(arm.Run{ .instructions = 0, .cycles = 0, .latency = 0, .stop = null, .ended = .deadline }, nothing);
    try std.testing.expectEqual(@as(u32, 0x8), cpu.state.pc);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.stop);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 0xc), cpu.state.pc);
}

test "a fault while stacking the exception frame is recorded without a code at the stacking address, and one derived again inside the HardFault entry locks the core up, B1.5.11" {
    var m = placed(&.{ 0x2000, 0x41, 0, 0xa1, 0, 0, 0, 0, 0, 0, 0, 0x61 }, &.{ 0x40, 0x60 }, &.{ &.{ 0xdf00, 0xbe00 }, &.{0x4770} });
    var cpu = traced(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .unrecoverable_exception), cpu.run(.{ .instructions = 100 }).stop);
    const stacking = cpu.trace.at(3).?;
    try std.testing.expectEqual(@as(u32, 0x42), stacking.pc);
    try std.testing.expectEqual(@as(?u32, null), stacking.codeOf());
    try std.testing.expectEqual(@as(?u32, 0x1fe0), stacking.access);
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try cpu.explain(&w, 0);
    try std.testing.expectEqualStrings(
        \\The code 0000 at pc=000000a0 raised an exception the core could not take at HardFault priority. The core locked up.
        \\The core took a BusFault at pc=00000060 as HardFault: no memory answered the access to 00001fc0.
        \\
    , w.buffered());
}

test "a MemManage on an exception entry's own stacking writes is the MSTKERR class, and the HardFault it escalates to takes the entry already started with the original left pending, armv8m B3.24 RMRTR" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60, 0xa0 }, &.{ &.{ 0xdf00, 0xbe00 }, &.{0xbe01}, &.{0xbe03} });
    var cpu = fast(.m33, &m);
    cpu.reset();
    protect(&cpu, 0, 0x7e0, 0, 0);
    cpu.state.msp = 0x820;
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(u32, 3), cpu.state.xpsr & State.ipsr_mask);
    try std.testing.expectEqual(@as(?u32, 0x10), cpu.peek(4, 0xe000_ed28));
    try std.testing.expectEqual(@as(?u32, scb_block.forced), cpu.peek(4, 0xe000_ed2c));
    try std.testing.expectEqual(@as(u32, 0x800), cpu.state.msp);
    try std.testing.expectEqual(@as(u32, 1 << 15), cpu.peek(4, 0xe000_ed24).? & (1 << 15));
}

test "a Secure fault derived while stacking for a Non-secure interrupt preempts it, keeps the callee frame it pushed and leaves the interrupt pending, B3.24 RMRTR RWYWW" {
    var m = placed(&svc_vectors, &.{ 0x40, 0xa0, 0x440, 0x460 }, &.{ &.{ 0xbf00, 0xbe00 }, &.{0xbe03}, &.{ 0x0461, 0x0000 }, &.{0xbe01} });
    var cpu = fast(.m33, &m);
    cpu.reset();
    protect(&cpu, 0, 0x7e0, 0, 0);
    _ = cpu.poke(4, 0xe002_ed08, 0x400);
    _ = cpu.poke(4, 0xe000_e380, 1);
    _ = cpu.poke(4, 0xe000_e100, 1);
    cpu.state.msp = 0x820;
    cpu.pend(0);
    try std.testing.expectEqual(@as(?arm.Stop, null), cpu.step().stop);
    try std.testing.expectEqual(@as(u32, 3), cpu.state.xpsr & State.ipsr_mask);
    try std.testing.expect(cpu.state.secure);
    try std.testing.expectEqual(@as(u32, 0xffff_ffd9), cpu.state.lr);
    try std.testing.expectEqual(@as(u32, 0x7d8), cpu.state.msp);
    try std.testing.expectEqual(@as(?u32, 0xfefa_125b), cpu.peek(4, 0x7d8));
    try std.testing.expectEqual(@as(?u32, 0x10), cpu.peek(4, 0xe000_ed28));
    try std.testing.expectEqual(@as(?u32, 1), cpu.peek(4, 0xe000_e200));
}

test "ICTR is reserved on Armv6-M and reads zero, D3.6.4" {
    var m = placed(&irq_vectors, &.{0x100}, &.{&nops_then_break});
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_e004));
}

const irq_vectors = [_]u32{ 0x1000, 0x101, 0x1c1, 0x1a1, 0, 0, 0, 0, 0, 0, 0, 0x121, 0, 0, 0x181, 0x161, 0, 0x1e1, 0x1e1, 0, 0, 0x1e1 };
const irq_record = [_]u16{ 0xf3ef, 0x8005, 0x0224, 0x4304, 0x4675, 0x4770 };
const nops_then_break = [_]u16{ 0xbf00, 0xbf00, 0xbf00, 0xbf00, 0xbe00 };

test "an interrupt pended through ISPR waits until ISER enables it, then enters with its number in IPSR, and ICPR clears a pending interrupt, B3.4.3 to B3.4.6" {
    var m = placed(&irq_vectors, &.{ 0x100, 0x1e0 }, &.{ &nops_then_break, &irq_record });
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e200, 0xe0));
    try std.testing.expectEqual(@as(?arm.Stop, null), cpu.run(.{ .instructions = 2 }).stop);
    try std.testing.expectEqual(@as(u64, 0), cpu.active);
    try std.testing.expectEqual(@as(?u32, 0xe0), cpu.peek(4, 0xe000_e280));
    try std.testing.expectEqual(@as(?u32, 1 << 22), cpu.peek(4, 0xe000_ed04));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e280, 0xc0));
    try std.testing.expectEqual(@as(?u32, 0x20), cpu.peek(4, 0xe000_e200));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e100, 0x20));
    try std.testing.expectEqual(@as(?u32, 21 << 12 | 1 << 22), cpu.peek(4, 0xe000_ed04));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 21), cpu.state.r[4]);
    try std.testing.expectEqual(@as(u32, 0xffff_fff9), cpu.state.r[5]);
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_e200));
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ed04));
}

test "a line the chip pends reaches the handler the NVIC vector names, with its number in IPSR, B1.5.6 B3.4.1" {
    var m = placed(&irq_vectors, &.{ 0x100, 0x1e0 }, &.{ &nops_then_break, &irq_record });
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e100, 0x2));
    cpu.pend(1);
    try std.testing.expectEqual(@as(?u32, 1 << 1), cpu.peek(4, 0xe000_e200));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 17), cpu.state.r[4]);
    try std.testing.expectEqual(@as(u32, 0xffff_fff9), cpu.state.r[5]);
}

test "enabled answers false for a line whose ISER bit is clear and true once firmware sets it, B3.4.4" {
    var m = loaded();
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expect(!cpu.enabled(1));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e100, 0x2));
    try std.testing.expect(cpu.enabled(1));
    try std.testing.expect(!cpu.enabled(2));
}

test "a line past the last the NVIC implements is not enabled and pending it does nothing, B3.4.1" {
    var m = loaded();
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expect(!cpu.enabled(240));
    cpu.pend(240);
    try std.testing.expect(cpu.pending == 0);
}

test "a WFI halts the core where it stands and a line the chip pends resumes it at the instruction after the WFI, B1.5.19 B3.4.4" {
    var m = placed(&irq_vectors, &.{0x100}, &.{&.{ 0xb672, 0xbf30, 0x2415, 0xbe00 }});
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e100, 0x2));
    try std.testing.expectEqual(@as(?Class, .system), cpu.step().class);
    const halting = cpu.step();
    try std.testing.expectEqual(@as(?Class, .sleep), halting.class);
    try std.testing.expect(halting.asleep);
    const standing = cpu.step();
    try std.testing.expectEqual(@as(?Class, null), standing.class);
    try std.testing.expectEqual(@as(u8, 0), standing.charged);
    try std.testing.expect(standing.asleep);
    try std.testing.expectEqual(@as(u64, 2), cpu.instructions);
    cpu.pend(1);
    const resumed = cpu.step();
    try std.testing.expect(!resumed.asleep);
    try std.testing.expectEqual(@as(u32, 0x104), resumed.address);
    try std.testing.expectEqual(@as(u32, 0x15), cpu.state.r[4]);
}

test "a line the NVIC has not enabled leaves the core standing in its WFI, and the same line wakes it once firmware enables it, B1.5.19 B3.4.4" {
    var m = placed(&irq_vectors, &.{0x100}, &.{&.{ 0xb672, 0xbf30, 0x2415, 0xbe00 }});
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    _ = cpu.step();
    try std.testing.expect(cpu.step().asleep);
    cpu.pend(1);
    try std.testing.expect(cpu.step().asleep);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.r[4]);
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e100, 0x2));
    cpu.pend(1);
    try std.testing.expect(!cpu.step().asleep);
    try std.testing.expectEqual(@as(u32, 0x15), cpu.state.r[4]);
}

test "a WFE after a SEV consumes the event register and retires without halting, and the next WFE halts, B1.5.18" {
    var m = placed(&irq_vectors, &.{0x100}, &.{&.{ 0xbf40, 0xbf20, 0x2415, 0xbf20, 0xbe00 }});
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?Class, .system), cpu.step().class);
    const consuming = cpu.step();
    try std.testing.expectEqual(@as(?Class, .sleep), consuming.class);
    try std.testing.expect(!consuming.asleep);
    try std.testing.expect(!cpu.step().asleep);
    try std.testing.expectEqual(@as(u32, 0x15), cpu.state.r[4]);
    try std.testing.expect(cpu.step().asleep);
}

test "an exception return sets the event register, so a WFE that comes after one retires rather than halting, B1.5.18" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
        &.{ 0xdf00, 0x2501, 0xbf20, 0x2415, 0xbe00 },
        &.{0x4770},
    });
    var cpu = fast(.m4, &m);
    cpu.reset();
    for (0..10) |_| {
        if (cpu.state.r[5] == 1) break;
        _ = cpu.step();
    }
    try std.testing.expectEqual(@as(u32, 1), cpu.state.r[5]);
    const waiting = cpu.step();
    try std.testing.expectEqual(@as(?Class, .sleep), waiting.class);
    try std.testing.expect(!waiting.asleep);
}

test "an exception pending before a WFE leaves the event register set where SCR.SEVONPEND asks, so the WFE retires, B1.5.18" {
    for ([_]u32{ 0, scb_block.sevonpend }) |scr| {
        var m = placed(&irq_vectors, &.{0x100}, &.{&.{ 0xb672, 0xbf20, 0x2415, 0xbe00 }});
        var cpu = fast(.m4, &m);
        cpu.reset();
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed10, scr));
        _ = cpu.step();
        cpu.pend(1);
        try std.testing.expectEqual(scr == 0, cpu.step().asleep);
    }
}

test "an interrupt the NVIC has not enabled ends a WFE only where SCR.SEVONPEND is set, B1.5.18 B3.2.7" {
    for ([_]u32{ 0, scb_block.sevonpend }) |scr| {
        var m = placed(&irq_vectors, &.{0x100}, &.{&.{ 0xb672, 0xbf20, 0x2415, 0xbe00 }});
        var cpu = fast(.m4, &m);
        cpu.reset();
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed10, scr));
        _ = cpu.step();
        try std.testing.expect(cpu.step().asleep);
        cpu.pend(1);
        try std.testing.expectEqual(scr == 0, cpu.step().asleep);
    }
}

test "an interrupt pended by a write to NVIC_ISPR ends a WFE only where SCR.SEVONPEND is set, B1.5.18 B3.2.7" {
    for ([_]u32{ 0, scb_block.sevonpend }) |scr| {
        var m = placed(&irq_vectors, &.{0x100}, &.{&.{ 0xbf20, 0x2415, 0xbe00 }});
        var cpu = fast(.m4, &m);
        cpu.reset();
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed10, scr));
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e200, 1));
        try std.testing.expectEqual(scr == 0, cpu.step().asleep);
    }
}

test "a WFI no device can end gives up at the sleep limit and the run goes on, B1.5.19" {
    var m = placed(&irq_vectors, &.{0x100}, &.{&.{ 0xbf30, 0x2415, 0xbe00 }});
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 2, .cycles = 65539, .latency = 0, .stop = .breakpoint, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
    try std.testing.expectEqual(@as(u32, 0x15), cpu.state.r[4]);
}

test "IPR orders two pending interrupts by priority, and equal priorities take the lower number first, B1.5.4 B3.4.7" {
    for ([_]u32{ 0x0040_8000, 0 }, [_]u32{ 0x1211, 0x1112 }) |ipr0, order| {
        var m = placed(&irq_vectors, &.{ 0x100, 0x1e0 }, &.{ &nops_then_break, &irq_record });
        var cpu = fast(.m0plus, &m);
        cpu.reset();
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e400, ipr0));
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e100, 0x6));
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e200, 0x6));
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        try std.testing.expectEqual(order, cpu.state.r[4]);
    }
}

test "PENDSVSET pends PendSV and PENDSVCLR clears it, and the pending bits of SysTick and PendSV read back in ICSR, B3.2.4" {
    var m = placed(&irq_vectors, &.{ 0x100, 0x180 }, &.{ &nops_then_break, &.{ 0xf3ef, 0x8705, 0x4770 } });
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed04, 1 << 28 | 1 << 26));
    try std.testing.expectEqual(@as(?u32, 14 << 12 | 1 << 26 | 1 << 28), cpu.peek(4, 0xe000_ed04));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed04, 1 << 27 | 1 << 25));
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ed04));
    try std.testing.expectEqual(@as(?arm.Stop, null), cpu.run(.{ .instructions = 2 }).stop);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.r[7]);
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed04, 1 << 28));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 14), cpu.state.r[7]);
}

test "NMIPENDSET takes NMI through PRIMASK with 2 in IPSR, B3.2.4 B1.5.4" {
    var m = placed(&irq_vectors, &.{ 0x100, 0x1c0 }, &.{ &.{ 0xb672, 0xbf00, 0xbf00, 0xbe00 }, &.{ 0xf3ef, 0x8605, 0x4770 } });
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, null), cpu.run(.{ .instructions = 1 }).stop);
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed04, 1 << 31));
    try std.testing.expectEqual(@as(?u32, 2 << 12 | 1 << 31), cpu.peek(4, 0xe000_ed04));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 2), cpu.state.r[6]);
    try std.testing.expect(cpu.state.primask);
}

test "VTOR relocates the vector table and keeps only bits 31 to 7, B3.2.5" {
    var m = placed(&irq_vectors, &.{ 0x100, 0x120, 0x140 }, &.{ &.{ 0xdf00, 0xbe00 }, &.{ 0x2601, 0x4770 }, &.{ 0x2602, 0x4770 } });
    for (irq_vectors, 0..) |v, i| std.mem.writeInt(u32, m.bytes[0x200 + i * 4 ..][0..4], if (i == 11) 0x141 else v, .little);
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed08, 0x27f));
    try std.testing.expectEqual(@as(?u32, 0x200), cpu.peek(4, 0xe000_ed08));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 2), cpu.state.r[6]);
}

test "a data fault or an undefined instruction enters HardFault with the faulting address stacked, and the handler can step past it, B1.5.6" {
    for ([_]u16{ 0x6808, 0xde00 }) |faulting| {
        var m = placed(&irq_vectors, &.{ 0x100, 0x1a0 }, &.{
            &.{ 0x2180, 0x0609, faulting, 0xbe00 },
            &.{ 0xf3ef, 0x8605, 0x9d06, 0x3502, 0x9506, 0x4770 },
        });
        var cpu = fast(.m0plus, &m);
        cpu.reset();
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        try std.testing.expectEqual(@as(u32, 3), cpu.state.r[6]);
        try std.testing.expectEqual(@as(u32, 0x106), cpu.state.r[5]);
        try std.testing.expectEqual(@as(u32, 0x106), cpu.state.pc);
        try std.testing.expectEqual(@as(u64, 0), cpu.active);
        try std.testing.expect(!cpu.state.lockup);
    }
}

test "a fault inside the HardFault handler locks the core up with the fault's own reason, and a HardFault vector without the T bit locks up in place, B1.5.14" {
    var m = placed(&irq_vectors, &.{ 0x100, 0x1a0 }, &.{ &.{ 0x2180, 0x0609, 0x6808, 0xbe00 }, &.{ 0x6808, 0xbe00 } });
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .data_fault), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expect(cpu.state.lockup);
    try std.testing.expectEqual(@as(u32, 0x1a0), cpu.state.pc);
    try std.testing.expectEqual(@as(u64, 1 << 3), cpu.active);
    var bare = placed(&irq_vectors, &.{0x100}, &.{&.{ 0x2180, 0x0609, 0x6808, 0xbe00 }});
    std.mem.writeInt(u32, bare.bytes[12..16], 0x1a0, .little);
    var cpu2 = fast(.m0plus, &bare);
    cpu2.reset();
    try std.testing.expectEqual(arm.Run{ .instructions = 2, .cycles = 2, .latency = 0, .stop = .data_fault, .ended = .stopped }, cpu2.run(.{ .instructions = 100 }));
    try std.testing.expectEqual(@as(u32, 0x104), cpu2.state.pc);
    try std.testing.expectEqual(@as(u64, 0), cpu2.active);
}

test "an SVC under PRIMASK escalates to HardFault at the instruction, ahead of a pending interrupt that outranks SVCall, B1.5.4" {
    var m = placed(&irq_vectors, &.{ 0x100, 0x1a0 }, &.{
        &.{ 0xb672, 0x4803, 0x2101, 0x6001, 0xdf00, 0xb662, 0xbe00, 0xbf00, 0xe200, 0xe000 },
        &.{ 0x4675, 0xf3ef, 0x8605, 0x9f06, 0xbe00 },
    });
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e100, 1));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed1c, 0x4000_0000));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual([_]u32{ 0xffff_fff9, 3, 0x10a }, cpu.state.r[5..8].*);
    try std.testing.expectEqual(@as(u64, 1 << 3), cpu.active);
    try std.testing.expectEqual(@as(u64, 1 << 16), cpu.pending >> 1 << 1);
}

test "an EXC_RETURN with bit 0 clear is not a valid return, so the M4 enters HardFault with it in lr and the M0+ locks up, B1.5.8" {
    const code = [_][]const u16{
        &.{ 0xdf00, 0xbe00 },
        &.{ 0x4670, 0x3801, 0x4700 },
        &.{ 0xf3ef, 0x8705, 0x4675, 0xbe00 },
    };
    var m = placed(&svc_vectors, &.{ 0x40, 0x60, 0xa0 }, &code);
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual([_]u32{ 0xffff_fff8, 0, 3 }, cpu.state.r[5..8].*);
    try std.testing.expectEqual(@as(u64, 1 << 3), cpu.active);
    var m0 = placed(&svc_vectors, &.{ 0x40, 0x60, 0xa0 }, &code);
    var cpu0 = fast(.m0plus, &m0);
    cpu0.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .exception_return), cpu0.run(.{ .instructions = 100 }).stop);
}

fn modernImage() Memory {
    var m = loaded();
    for ([_]u16{ 0xfec1, 0x0a21, 0xbe00 }, 0..) |code, i| std.mem.writeInt(u16, m.bytes[8 + 2 * i ..][0..2], code, .little);
    return m;
}

test "VMAXNM runs on the M7, which carries FPv5, and is undefined on the M4, which carries FPv4, A2.5.1" {
    var seven = modernImage();
    var cpu = fast(.m7, &seven);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed88, 0x00f0_0000));
    cpu.state.fp[2] = 0x3f80_0000;
    cpu.state.fp[3] = 0x4000_0000;
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 4 }).stop);
    try std.testing.expectEqual(@as(u32, 0x4000_0000), cpu.state.fp[1]);
    var four = modernImage();
    var single = fast(.m4, &four);
    single.reset();
    try std.testing.expectEqual(@as(?void, {}), single.poke(4, 0xe000_ed88, 0x00f0_0000));
    try std.testing.expectEqual(@as(?arm.Stop, .undefined_instruction), single.run(.{ .instructions = 4 }).stop);
}

fn doubleImage() Memory {
    var m = loaded();
    for ([_]u16{ 0xee31, 0x2b03, 0xbe00 }, 0..) |code, i| std.mem.writeInt(u16, m.bytes[8 + 2 * i ..][0..2], code, .little);
    return m;
}

test "double-precision arithmetic runs on the M7 and is undefined on the M4, which carries the single-precision unit only, A2.5.1" {
    var seven = doubleImage();
    var cpu = fast(.m7, &seven);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed88, 0x00f0_0000));
    cpu.state.fp[2] = 0;
    cpu.state.fp[3] = 0x4000_0000;
    cpu.state.fp[6] = 0;
    cpu.state.fp[7] = 0x4008_0000;
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 4 }).stop);
    try std.testing.expectEqual(@as(u32, 0x4014_0000), cpu.state.fp[5]);
    var four = doubleImage();
    var single = fast(.m4, &four);
    single.reset();
    try std.testing.expectEqual(@as(?void, {}), single.poke(4, 0xe000_ed88, 0x00f0_0000));
    try std.testing.expectEqual(@as(?arm.Stop, .undefined_instruction), single.run(.{ .instructions = 4 }).stop);
}

test "a keyed write of AIRCR.SYSRESETREQ resets the core out of the vector table and leaves memory alone, B3.2.6" {
    var m = loaded();
    var cpu = fast(.m4, &m);
    cpu.reset();
    const entry = cpu.state.pc;
    _ = cpu.run(.{ .instructions = 2 });
    const ran = cpu.instructions;
    _ = cpu.poke(4, 0x100, 0x600d_600d);
    try std.testing.expect(cpu.state.r[0] != 0);
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed0c, 0x05fa_0004));
    _ = cpu.step();
    try std.testing.expectEqual(entry, cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.r[0]);
    try std.testing.expectEqual(@as(?u32, 0x600d_600d), cpu.peek(4, 0x100));
    try std.testing.expectEqual(ran, cpu.instructions);
}

test "a write of AIRCR without VECTKEY requests no reset, B3.2.6" {
    var m = loaded();
    var cpu = fast(.m4, &m);
    cpu.reset();
    _ = cpu.run(.{ .instructions = 2 });
    const r0 = cpu.state.r[0];
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed0c, 0x0000_0004));
    _ = cpu.step();
    try std.testing.expectEqual(r0, cpu.state.r[0]);
}

test "the SCB registers a CMSIS SystemInit touches all answer on the M4, CPACR holds the FPU access bits, and SHCSR holds the three fault enables, B3.2.2 B3.2.13 B3.2.20" {
    var m = loaded();
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?u32, 0x410f_c240), cpu.peek(4, 0xe000_ed00));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed88, 0x00f0_0000));
    try std.testing.expectEqual(@as(?u32, 0x00f0_0000), cpu.peek(4, 0xe000_ed88));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed0c, 0x05fa_0300));
    try std.testing.expectEqual(@as(?u32, 0xfa05_0300), cpu.peek(4, 0xe000_ed0c));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed14, 0x0000_0210));
    try std.testing.expectEqual(@as(?u32, 0x0000_0210), cpu.peek(4, 0xe000_ed14));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed10, 0x0000_0004));
    try std.testing.expectEqual(@as(?u32, 0x0000_0004), cpu.peek(4, 0xe000_ed10));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed24, 0x0007_0000));
    try std.testing.expectEqual(@as(?u32, 0x0007_0000), cpu.peek(4, 0xe000_ed24));
    for ([_]u32{ 0xe000_ed28, 0xe000_ed2c, 0xe000_ed30, 0xe000_ed34, 0xe000_ed38, 0xe000_ed3c }) |at| {
        try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, at));
    }
}

test "SHPR1 takes the priority of a system handler one byte at a time, B3.2.10" {
    var m = loaded();
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(1, 0xe000_ed1a, 0xff));
    try std.testing.expectEqual(@as(?u32, 0x00f0_0000), cpu.peek(4, 0xe000_ed18));
    try std.testing.expectEqual(@as(?u8, 0xf0), cpu.peek(1, 0xe000_ed1a));
}

test "SHCSR shows SVCall active while its handler runs, and the ARMv6-M core keeps those bits reserved, v7-M B3.2.13 and v6-M C1.6.1" {
    const code = [_][]const u16{ &.{ 0xdf00, 0xbe00 }, &.{ 0xbf00, 0x4770 } };
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &code);
    var cpu = fast(.m4, &m);
    cpu.reset();
    _ = cpu.run(.{ .instructions = 2 });
    try std.testing.expectEqual(@as(u64, 1 << 11), cpu.active);
    try std.testing.expectEqual(@as(?u32, 1 << 7), cpu.peek(4, 0xe000_ed24));
    var m0 = placed(&svc_vectors, &.{ 0x40, 0x60 }, &code);
    var cpu0 = fast(.m0plus, &m0);
    cpu0.reset();
    _ = cpu0.run(.{ .instructions = 2 });
    try std.testing.expectEqual(@as(u64, 1 << 11), cpu0.active);
    try std.testing.expectEqual(@as(?u32, 0), cpu0.peek(4, 0xe000_ed24));
}

test "an undefined instruction escalated to HardFault sets UFSR.UNDEFINSTR and HFSR.FORCED, B3.2.15 B3.2.16" {
    var m = placed(&svc_vectors, &.{ 0x40, 0xa0 }, &.{ &.{0xde00}, &.{0xbe00} });
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u64, 1 << 3), cpu.active);
    try std.testing.expectEqual(@as(?u32, 1 << 16), cpu.peek(4, 0xe000_ed28));
    try std.testing.expectEqual(@as(?u32, 1 << 30), cpu.peek(4, 0xe000_ed2c));
}

test "an authentication that fails sets UFSR.INVSTATE and takes the UsageFault the same way an undefined instruction does, C2.4.17 D1.2.270" {
    var m = placed(&svc_vectors, &.{ 0x40, 0xa0 }, &.{
        &.{ 0x2040, 0xf380, 0x8814, 0xf241, 0x2e35, 0xf3af, 0x801d, 0xf04e, 0x0e40, 0xf3af, 0x802d },
        &.{0xbe00},
    });
    var cpu = fast(.m85, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u64, 1 << 3), cpu.active);
    try std.testing.expectEqual(@as(?u32, 1 << 17), cpu.peek(4, 0xe000_ed28));
    try std.testing.expectEqual(@as(?u32, 1 << 30), cpu.peek(4, 0xe000_ed2c));
}

test "a vector table the memory does not answer sets HFSR.VECTTBL, B3.2.16" {
    var m = placed(&svc_vectors, &.{0x40}, &.{&.{ 0xdf00, 0xbe00 }});
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed08, 0x0000_1000));
    try std.testing.expectEqual(@as(?arm.Stop, .fetch_fault), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(?u32, 1 << 1), cpu.peek(4, 0xe000_ed2c));
}

test "a vector the memory does not answer is taken as HardFault, which leaves the exception that asked for it inactive, B1.5.11" {
    var m = placed(&.{ 0x1000, 0x101 }, &.{ 0x100, 0x200 }, &.{
        &.{ 0xbf00, 0xbf00, 0xbe00 },
        &.{0xbe01},
    });
    std.mem.writeInt(u32, m.bytes[0xf8c..][0..4], 0x201, .little);
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed08, 0x0000_0f80));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e100, 1 << 16));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e200, 1 << 16));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expect(!cpu.state.lockup);
    try std.testing.expectEqual(@as(u32, 0x200), cpu.state.pc);
    try std.testing.expectEqual(@as(u32, 3), cpu.state.xpsr & State.ipsr_mask);
    try std.testing.expectEqual(@as(u64, 1 << 3), cpu.active);
    try std.testing.expectEqual(@as(?u32, 1 << 1), cpu.peek(4, 0xe000_ed2c));
}

test "an exception taken inside an IT block runs the handler with ITSTATE cleared and its frame restores the block, B1.4.2 B1.5.6" {
    var m = placed(&irq_vectors, &.{ 0x100, 0x180 }, &.{
        &.{ 0x2000, 0xbf0c, 0x2001, 0x2102, 0xbe00 },
        &.{ 0x2301, 0x4770 },
    });
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, null), cpu.run(.{ .instructions = 2 }).stop);
    try std.testing.expectEqual(@as(u8, 0x0c), cpu.state.itState());
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed04, 1 << 28));
    try std.testing.expectEqual(@as(?arm.Stop, null), cpu.run(.{ .instructions = 1 }).stop);
    try std.testing.expectEqual(@as(u32, 14), cpu.state.xpsr & State.ipsr_mask);
    try std.testing.expectEqual(@as(u8, 0), cpu.state.itState());
    try std.testing.expectEqual(@as(u32, 1), cpu.state.r[3]);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual([_]u32{ 1, 0 }, cpu.state.r[0..2].*);
    try std.testing.expectEqual(@as(u8, 0), cpu.state.itState());
    try std.testing.expect(cpu.state.xpsr & State.flag_z != 0);
}

test "CCR.UNALIGN_TRP makes an unaligned word or halfword access fault, and a byte access is never unaligned, B3.2.8 A3.2.1" {
    for ([_]u32{ 0, scb_block.unalign_trp }) |trap| {
        var m = placed(&svc_vectors, &.{ 0x40, 0xa0 }, &.{ &.{ 0x2055, 0x2103, 0x7008, 0x6008, 0xbe00 }, &.{0xbe00} });
        var cpu = fast(.m4, &m);
        cpu.reset();
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed14, 0x200 | trap));
        try std.testing.expectEqual(@as(?u32, 0x200 | trap), cpu.peek(4, 0xe000_ed14));
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        try std.testing.expectEqual(@as(?u8, 0x55), cpu.peek(1, 3));
        if (trap == 0) {
            try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ed28));
            try std.testing.expectEqual(@as(u64, 0), cpu.active);
        } else {
            try std.testing.expectEqual(@as(?u32, 1 << 24), cpu.peek(4, 0xe000_ed28));
            try std.testing.expectEqual(@as(u64, 1 << 3), cpu.active);
        }
    }
}

test "LDRD requires alignment whatever CCR.UNALIGN_TRP says, because the encoding does, A7.7.49" {
    var m = placed(&svc_vectors, &.{ 0x40, 0xa0 }, &.{ &.{ 0x2103, 0xe9d1, 0x2300, 0xbe00 }, &.{0xbe00} });
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed14, 0x200));
    try std.testing.expectEqual(@as(?u32, 0x200), cpu.peek(4, 0xe000_ed14));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(?u32, 1 << 24), cpu.peek(4, 0xe000_ed28));
}

test "CCR.DIV_0_TRP makes a divide by zero fault and leaves Rd alone, and without it the quotient is zero, B3.2.8 A7.7.127" {
    for ([_]u32{ 0, scb_block.div_0_trp }) |trap| {
        var m = placed(&svc_vectors, &.{ 0x40, 0xa0 }, &.{ &.{ 0x2007, 0x2100, 0x2299, 0xfbb0, 0xf2f1, 0xbe00 }, &.{0xbe00} });
        var cpu = fast(.m4, &m);
        cpu.reset();
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed14, 0x200 | trap));
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        if (trap == 0) {
            try std.testing.expectEqual(@as(u32, 0), cpu.state.r[2]);
            try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ed28));
            try std.testing.expectEqual(@as(u64, 0), cpu.active);
        } else {
            try std.testing.expectEqual(@as(u32, 0x99), cpu.state.r[2]);
            try std.testing.expectEqual(@as(?u32, 1 << 25), cpu.peek(4, 0xe000_ed28));
            try std.testing.expectEqual(@as(u64, 1 << 3), cpu.active);
        }
    }
}

test "ARMv6-M reads CCR.UNALIGN_TRP as one and cannot clear it, so every unaligned access still faults, B3.2.8" {
    var m = placed(&svc_vectors, &.{ 0x40, 0xa0 }, &.{ &.{ 0x2055, 0x2103, 0x6008, 0xbe00 }, &.{0xbe00} });
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?u32, 0x208), cpu.peek(4, 0xe000_ed14));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed14, 0x200));
    try std.testing.expectEqual(@as(?u32, 0x208), cpu.peek(4, 0xe000_ed14));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u64, 1 << 3), cpu.active);
}

const fault_vectors = [_]u32{ 0x1000, 0x41, 0, 0xa1, 0, 0xc1, 0xe1 };

test "SHCSR.USGFAULTENA sends a UsageFault to its own handler and reports it active, and without it the fault is forced to HardFault, B1.5.4 B3.2.13" {
    for ([_]u32{ 0, scb_block.usgfaultena }) |enable| {
        var m = placed(&fault_vectors, &.{ 0x40, 0xa0, 0xe0 }, &.{ &.{ 0x2007, 0x2100, 0x2299, 0xfbb0, 0xf2f1, 0xbe00 }, &.{0xbe00}, &.{0xbe00} });
        var cpu = fast(.m4, &m);
        cpu.reset();
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed14, 0x200 | scb_block.div_0_trp));
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed24, enable));
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        try std.testing.expectEqual(@as(?u32, 1 << 25), cpu.peek(4, 0xe000_ed28));
        if (enable == 0) {
            try std.testing.expectEqual(@as(u64, 1 << 3), cpu.active);
            try std.testing.expectEqual(@as(?u32, 1 << 30), cpu.peek(4, 0xe000_ed2c));
        } else {
            try std.testing.expectEqual(@as(u64, 1 << 6), cpu.active);
            try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ed2c));
            try std.testing.expectEqual(@as(?u32, enable | 1 << 3), cpu.peek(4, 0xe000_ed24));
        }
    }
}

test "a fault taken in Secure state reads the Secure SHCSR, not the Non-secure one, D1.2.233" {
    for ([_]u32{ 0, scb_block.busfaultena }) |enable| {
        var m = placed(&fault_vectors, &.{ 0x40, 0xa0, 0xc0 }, &.{ &.{ 0x21ff, 0x0609, 0x6008, 0xbe00 }, &.{0xbe00}, &.{0xbe00} });
        var cpu = fast(.m33, &m);
        cpu.reset();
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed24, enable));
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe002_ed24, scb_block.busfaultena ^ enable));
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        try std.testing.expectEqual(@as(u64, if (enable == 0) 1 << 3 else 1 << 5), cpu.active);
    }
}

test "SHCSR.BUSFAULTENA sends a BusFault to its own handler and reports it active, and without it the fault is forced to HardFault, B1.5.4 B3.2.13" {
    for ([_]u32{ 0, scb_block.busfaultena }) |enable| {
        var m = placed(&fault_vectors, &.{ 0x40, 0xa0, 0xc0 }, &.{ &.{ 0x21ff, 0x0609, 0x6008, 0xbe00 }, &.{0xbe00}, &.{0xbe00} });
        var cpu = fast(.m4, &m);
        cpu.reset();
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed24, enable));
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        try std.testing.expectEqual(@as(?u32, 1 << 15 | 1 << 9), cpu.peek(4, 0xe000_ed28));
        try std.testing.expectEqual(@as(?u32, 0xff00_0000), cpu.peek(4, 0xe000_ed38));
        if (enable == 0) {
            try std.testing.expectEqual(@as(u64, 1 << 3), cpu.active);
            try std.testing.expectEqual(@as(?u32, 1 << 30), cpu.peek(4, 0xe000_ed2c));
        } else {
            try std.testing.expectEqual(@as(u64, 1 << 5), cpu.active);
            try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ed2c));
            try std.testing.expectEqual(@as(?u32, enable | 1 << 1), cpu.peek(4, 0xe000_ed24));
        }
    }
}

test "an enabled UsageFault that cannot preempt the current execution priority is forced to HardFault, B1.5.4 B3.2.10" {
    for ([_]u32{ 0x00, 0x20 }) |handler| {
        var m = placed(&fault_vectors, &.{ 0x40, 0xa0, 0xe0 }, &.{ &.{ 0x2010, 0xf380, 0x8811, 0x2007, 0x2100, 0x2299, 0xfbb0, 0xf2f1, 0xbe00 }, &.{0xbe00}, &.{0xbe00} });
        var cpu = fast(.m4, &m);
        cpu.reset();
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed14, 0x200 | scb_block.div_0_trp));
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed24, scb_block.usgfaultena));
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(1, 0xe000_ed1a, @intCast(handler)));
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        if (handler == 0) {
            try std.testing.expectEqual(@as(u64, 1 << 6), cpu.active);
            try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ed2c));
        } else {
            try std.testing.expectEqual(@as(u64, 1 << 3), cpu.active);
            try std.testing.expectEqual(@as(?u32, 1 << 30), cpu.peek(4, 0xe000_ed2c));
        }
    }
}

test "the core fetches through the memory's own fetch path, so code and data end up remembered separately" {
    var flash: [0x30]u8 = @splat(0);
    std.mem.writeInt(u32, flash[0..4], 0x2000_0020, .little);
    std.mem.writeInt(u32, flash[4..8], 0x21, .little);
    for ([_]u16{ 0x2001, 0xb082, 0x9000, 0xbe00 }, 0..) |code, i| {
        std.mem.writeInt(u16, flash[0x20 + i * 2 ..][0..2], code, .little);
    }
    var ram: [0x20]u8 = @splat(0);
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = 0, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = 0x2000_0000, .bytes = &ram, .writable = true } },
    };
    var regions = try Regions.adopt(&entries);
    var cpu = arm.Processor(.{ .cores = every, .Bus = Regions }).init(&regions, .m4, .{}, .{});
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 10 }).stop);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, ram[0x18..][0..4], .little));
    try std.testing.expectEqual(@as(u64, flash.len), regions.folded.span(0, 1, .fetch).len);
    try std.testing.expectEqual(@as(u64, ram.len), regions.folded.span(0x2000_0000, 1, .write).len);
}

test "an exception between LDREX and STREX clears the local monitor, so the store fails and the software retries, A3.4.4" {
    for ([_]bool{ false, true }) |interrupted| {
        var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
            &.{ 0x2120, 0xe851, 0x0f00, if (interrupted) 0xdf00 else 0xbf00, 0xe841, 0x0200, 0xbe00 },
            &.{0x4770},
        });
        var cpu = fast(.m4, &m);
        cpu.reset();
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        try std.testing.expectEqual(@as(u32, if (interrupted) 1 else 0), cpu.state.r[2]);
        try std.testing.expectEqual(@as(?u32, null), cpu.state.exclusive);
    }
}

test "an exception return restores APSR.Q and APSR.GE, which the frame carried all along, B1.5.8" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{ &.{ 0xdf00, 0xbe00 }, &.{0x4770} });
    var cpu = fast(.m4, &m);
    cpu.reset();
    cpu.state.xpsr |= State.flag_q | (0xa << 16);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(State.flag_q, cpu.state.xpsr & State.flag_q);
    try std.testing.expectEqual(@as(u32, 0xa << 16), cpu.state.xpsr & State.flag_ge);
}

test "a handler entered from an unprivileged thread is privileged, so MSR, MRS and CPS take effect, B1.4.1" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
        &.{ 0x2001, 0xf380, 0x8814, 0xdf00, 0xbe00 },
        &.{ 0xf3ef, 0x8508, 0xb672, 0x4770 },
    });
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(u32, 0xfe0), cpu.state.r[5]);
    try std.testing.expect(cpu.state.primask);
}

test "a coprocessor block transfer with an out of range register count retires instead of overflowing the cycle count" {
    var m = placed(&irq_vectors, &.{0x100}, &.{&.{ 0xec91, 0x0aff, 0xbe00 }});
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed88, 0x00f0_0000));
    const run = cpu.run(.{ .instructions = 20 });
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), run.stop);
    try std.testing.expectEqual(@as(u64, 33), run.cycles);
}

test "an undefined encoding whose IT condition fails is skipped rather than taken, in both widths, A7.7.194" {
    for ([_][]const u16{
        &.{ 0x2001, 0x2800, 0xbf08, 0xde00, 0xbe00 },
        &.{ 0x2001, 0x2800, 0xbf08, 0xf7f0, 0xa000, 0xbe00 },
    }) |program| {
        var m = placed(&irq_vectors, &.{0x100}, &.{program});
        var cpu = fast(.m4, &m);
        cpu.reset();
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    }
}

test "the floating-point context survives an exception whose handler uses the FPU, and the frame grows to 0x68, B1.5.7 B1.5.8" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
        &.{ 0xee00, 0x0a10, 0xdf00, 0xbe00 },
        &.{ 0xee00, 0x1a10, 0x4770 },
    });
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed88, 0x00f0_0000));
    cpu.state.r[0] = 0x1111_1111;
    cpu.state.r[1] = 0x2222_2222;
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(u32, 0x1111_1111), cpu.state.fp[0]);
    try std.testing.expectEqual(@as(u32, 0x1111_1111), m.peek(4, 0x1000 - 0x68 + 0x20).?);
    try std.testing.expectEqual(State.control_fpca, cpu.state.control & State.control_fpca);
}

test "treatAsSecure is FPCCR_S.TS, whether the floating-point context is treated as Secure, E2.1.335" {
    var m = loaded();
    var cpu = fast(.m33, &m);
    cpu.reset();
    try std.testing.expect(!cpu.treatAsSecure());
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ef34, cpu.peek(4, 0xe000_ef34).? | scb_block.treat_as_secure));
    try std.testing.expect(cpu.treatAsSecure());
    var plain = loaded();
    var without = fast(.m4, &plain);
    without.reset();
    try std.testing.expect(!without.treatAsSecure());
}

test "a Secure frame pushed with FPCCR_S.TS set is 0xa8 bytes and carries s16 to s31 inside itself, E2.1.335 E2.1.330" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
        &.{ 0xdf00, 0xbe00 },
        &.{ 0xee00, 0x0a10, 0x4770 },
    });
    var cpu = fast(.m55, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed88, 0x00f0_0000));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ef34, cpu.peek(4, 0xe000_ef34).? | scb_block.treat_as_secure));
    cpu.state.msp = 0xf00;
    for (0..16) |i| _ = cpu.poke(4, 0xf00 + 4 * @as(u32, @intCast(i)), 0xc0de_0000 + @as(u32, @intCast(i)));
    cpu.state.control |= State.control_fpca;
    cpu.state.fp[16] = 0x1616_1616;
    cpu.state.fp[31] = 0x3131_3131;
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(u32, 0x1616_1616), cpu.state.fp[16]);
    try std.testing.expectEqual(@as(u32, 0x3131_3131), cpu.state.fp[31]);
    for (0..16) |i| try std.testing.expectEqual(@as(?u32, 0xc0de_0000 + @as(u32, @intCast(i))), m.peek(4, 0xf00 + 4 * @as(u32, @intCast(i))));
    try std.testing.expectEqual(@as(u32, 0xf00), cpu.state.msp);
}

test "a basic-frame return leaves CONTROL.FPCA clear however the handler left it, B1.5.8" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
        &.{ 0xdf00, 0xf3ef, 0x8514, 0xbe00 },
        &.{ 0xee00, 0x0a10, 0xf3ef, 0x8414, 0x4770 },
    });
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed88, 0x00f0_0000));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(State.control_fpca, cpu.state.r[4] & State.control_fpca);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.r[5] & State.control_fpca);
}

test "the frame is the extended one whenever CONTROL.FPCA is set, whatever CPACR says of CP10, B1.5.6" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
        &.{ 0xdf00, 0xbe00 },
        &.{ 0x4675, 0xf3ef, 0x8608, 0x4770 },
    });
    var cpu = fast(.m4, &m);
    cpu.reset();
    cpu.state.control |= State.control_fpca;
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(u32, 0xffff_ffe9), cpu.state.r[5]);
    try std.testing.expectEqual(@as(u32, 0x1000 - 0x68), cpu.state.r[6]);
}

test "CONTROL_S.SFPA is cleared for the handler, rides bit 20 of the stacked xPSR and comes back with the frame, E2.1.16 E2.1.335" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
        &.{ 0xee00, 0x0a10, 0xdf00, 0xf3ef, 0x8514, 0xbe00 },
        &.{ 0xf3ef, 0x8414, 0x4770 },
    });
    var cpu = fast(.m33, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed88, 0x00f0_0000));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.r[4] & (State.control_fpca | State.control_sfpa));
    try std.testing.expectEqual(State.control_fpca | State.control_sfpa, cpu.state.r[5] & (State.control_fpca | State.control_sfpa));
    try std.testing.expectEqual(@as(?u32, 1 << 20), m.peek(4, 0x1000 - 0x68 + 0x1c).? & (1 << 20));
}

test "an exception taken without the floating-point context keeps the basic frame and EXC_RETURN bit 4, B1.5.7" {
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
        &.{ 0xdf00, 0xbe00 },
        &.{ 0xf3ef, 0x8508, 0x4770 },
    });
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed88, 0x00f0_0000));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(u32, 0x1000 - 0x20), cpu.state.r[5]);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.control & State.control_fpca);
}

test "unprivileged code takes a BusFault on the private peripheral bus, except at STIR once CCR.USERSETMPEND opens it, B3.1.1" {
    var m: Memory = .{};
    var cpu = fast(.m4, &m);
    cpu.reset();
    cpu.state.control |= State.control_npriv;
    try std.testing.expectEqual(@as(?u32, null), cpu.peek(4, 0xe000_e100));
    try std.testing.expectEqual(@as(?void, null), cpu.poke(4, 0xe000_e100, 1));
    try std.testing.expectEqual(@as(?u32, null), cpu.peek(4, 0xe000_e014));
    try std.testing.expectEqual(@as(?void, null), cpu.poke(4, 0xe000_ef00, 3));
    try std.testing.expectEqual(@as(u64, 0), cpu.pending);
    cpu.state.control &= ~State.control_npriv;
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed14, scb_block.stkalign | scb_block.usersetmpend));
    cpu.state.control |= State.control_npriv;
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ef00, 3));
    try std.testing.expectEqual(arm.one(arm.first_interrupt + 3), cpu.pending);
    try std.testing.expectEqual(@as(?u32, null), cpu.peek(4, 0xe000_ed14));
}

test "STIR raises the interrupt it names and IABR shows which interrupts are active, B3.2.26 B3.4.8" {
    var m = placed(&irq_vectors, &.{ 0x100, 0x1e0 }, &.{ &nops_then_break, &irq_record });
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_e300));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e100, 0x20));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ef00, 5));
    try std.testing.expectEqual(@as(?u32, 0x20), cpu.peek(4, 0xe000_e200));
    try std.testing.expectEqual(@as(?arm.Stop, null), cpu.run(.{ .instructions = 1 }).stop);
    try std.testing.expectEqual(@as(?u32, 0x20), cpu.peek(4, 0xe000_e300));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 21), cpu.state.r[4]);
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_e300));
}

test "a line number STIR cannot reach leaves the pending set alone, B3.2.26" {
    var m: Memory = .{};
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ef00, 0x1ff));
    try std.testing.expectEqual(@as(u64, 0), cpu.pending);
}

test "ICTR reports the 240 lines the NVIC implements in groups of 32 and ACTLR answers a read instead of taking a BusFault, B3.2.24 B3.2.25" {
    var m: Memory = .{};
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?u32, 7), cpu.peek(4, 0xe000_e004));
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_e008));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e008, 7));
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_e008));
    try std.testing.expectEqual(@as(?u32, null), cpu.peek(4, 0xe000_e00c));
}

test "ICSR.RETTOBASE tells a handler whether it is the only active exception, and ARMv6-M reserves the bit, B3.2.4" {
    var m = placed(&irq_vectors, &.{ 0x100, 0x1e0 }, &.{ &nops_then_break, &irq_record });
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?u32, 1 << 11), cpu.peek(4, 0xe000_ed04));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e400, 0x0000_4000));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e100, 0x6));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ef00, 1));
    try std.testing.expectEqual(@as(?arm.Stop, null), cpu.run(.{ .instructions = 1 }).stop);
    try std.testing.expectEqual(@as(u64, 1 << 17), cpu.active);
    try std.testing.expectEqual(@as(?u32, 17 | 1 << 11), cpu.peek(4, 0xe000_ed04));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ef00, 2));
    try std.testing.expectEqual(@as(?arm.Stop, null), cpu.run(.{ .instructions = 1 }).stop);
    try std.testing.expectEqual(@as(u64, 1 << 17 | 1 << 18), cpu.active);
    try std.testing.expectEqual(@as(?u32, 18), cpu.peek(4, 0xe000_ed04));

    var narrow = fast(.m0plus, &m);
    narrow.reset();
    try std.testing.expectEqual(@as(?u32, 0), narrow.peek(4, 0xe000_ed04));
    try std.testing.expectEqual(@as(?void, {}), narrow.poke(4, 0xe000_e100, 0x2));
    try std.testing.expectEqual(@as(?void, {}), narrow.poke(4, 0xe000_e200, 0x2));
    try std.testing.expectEqual(@as(?arm.Stop, null), narrow.run(.{ .instructions = 1 }).stop);
    try std.testing.expectEqual(@as(u64, 1 << 17), narrow.active);
    try std.testing.expectEqual(@as(?u32, 17), narrow.peek(4, 0xe000_ed04));
}

test "an exception return whose IPSR names no exception is refused rather than truncated into one, B1.5.8" {
    for ([_]u32{ 0x105, 0x40 }) |number| {
        var m = placed(&svc_vectors, &.{ 0x40, 0xa0 }, &.{ &.{ 0x4770, 0xbe00 }, &.{0xbe00} });
        var cpu = fast(.m4, &m);
        cpu.reset();
        cpu.state.xpsr = (cpu.state.xpsr & ~State.ipsr_mask) | number;
        cpu.state.lr = 0xffff_fff9;
        cpu.active = 1 << 11;
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        try std.testing.expectEqual(@as(u64, 1 << 3 | 1 << 11), cpu.active);
    }
}

test "IPSR is the nine bits the architecture defines, and MRS reads the same field the processor writes, B1.4.2" {
    try std.testing.expectEqual(@as(u32, 0x1ff), State.ipsr_mask);
    var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{ &.{ 0xdf00, 0xbe00 }, &.{ 0xf3ef, 0x8405, 0x4770 } });
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 11), cpu.state.r[4]);
}

test "clearing CCR.STKALIGN leaves a four-byte aligned stack pointer alone on exception entry, and the frame records that, B1.5.7" {
    for ([_]u32{ 0, scb_block.stkalign }) |align_stack| {
        var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{ &.{ 0xdf00, 0xbe00 }, &.{ 0x466c, 0xf3ef, 0x8505, 0x4770 } });
        var cpu = fast(.m4, &m);
        cpu.reset();
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed14, align_stack));
        cpu.state.msp -= 4;
        const entry = cpu.state.msp;
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        const frame = entry - 0x20 - (if (align_stack == 0) @as(u32, 0) else 4);
        try std.testing.expectEqual(frame, cpu.state.r[4]);
        try std.testing.expectEqual(@as(u32, if (align_stack == 0) 0 else 1 << 9), m.peek(4, frame + 0x1c).? & 1 << 9);
        try std.testing.expectEqual(entry, cpu.state.msp);
    }
}

const Doorbell = struct {
    var lines: u32 = 0;

    fn read(_: *anyopaque, _: u32, _: Width, _: *Lines) ?u32 {
        return lines;
    }

    fn write(_: *anyopaque, offset: u32, _: Width, value: u32, raise: *Lines) ?void {
        if (offset != 0) return null;
        lines = value;
        raise.* |= value;
    }
};

test "a device model raises an interrupt through the word it is handed, and the core takes it" {
    var flash: [0x70]u8 = @splat(0);
    std.mem.writeInt(u32, flash[0..4], 0x2000_0020, .little);
    std.mem.writeInt(u32, flash[4..8], 0x21, .little);
    std.mem.writeInt(u32, flash[0x40..][0..4], 0x61, .little);
    for ([_]u16{ 0x2040, 0x0600, 0x2101, 0x6001, 0xbf00, 0xbe00 }, 0..) |code, i| {
        std.mem.writeInt(u16, flash[0x20 + i * 2 ..][0..2], code, .little);
    }
    for ([_]u16{ 0xf3ef, 0x8405, 0x4770 }, 0..) |code, i| {
        std.mem.writeInt(u16, flash[0x60 + i * 2 ..][0..2], code, .little);
    }
    var ram: [0x20]u8 = @splat(0);
    var doorbell: u32 = 0;
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = 0, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = 0x2000_0000, .bytes = &ram, .writable = true } },
        .{ .device = .{ .base = 0x4000_0000, .size = 0x10, .device = .{ .context = @ptrCast(&doorbell), .read = Doorbell.read, .write = Doorbell.write } } },
    };
    var regions = try Regions.adopt(&entries);
    var cpu = arm.Processor(.{ .cores = every, .Bus = Regions }).init(&regions, .m4, .{}, .{});
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e100, 1));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(u32, 16), cpu.state.r[4]);
    try std.testing.expectEqual(@as(u32, 0), regions.raised);
}

const HighDoorbell = struct {
    fn read(_: *anyopaque, _: u32, _: Width, _: *Lines) ?u32 {
        return 0;
    }

    fn write(_: *anyopaque, _: u32, _: Width, value: u32, raise: *Lines) ?void {
        raise.* |= @as(Lines, 1) << @intCast(value);
    }
};

test "a line in the top enable word reaches its handler with its number in IPSR, so a device on line 200 is as reachable as one on line 0" {
    var flash: [0x440]u8 = @splat(0);
    std.mem.writeInt(u32, flash[0..4], 0x2000_0020, .little);
    std.mem.writeInt(u32, flash[4..8], 0x401, .little);
    std.mem.writeInt(u32, flash[(16 + 200) * 4 ..][0..4], 0x421, .little);
    for ([_]u16{ 0x2040, 0x0600, 0x21c8, 0x6001, 0xbf00, 0xbe00 }, 0..) |code, i| {
        std.mem.writeInt(u16, flash[0x400 + i * 2 ..][0..2], code, .little);
    }
    for ([_]u16{ 0xf3ef, 0x8405, 0x4770 }, 0..) |code, i| {
        std.mem.writeInt(u16, flash[0x420 + i * 2 ..][0..2], code, .little);
    }
    var ram: [0x20]u8 = @splat(0);
    var context: u32 = 0;
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = 0, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = 0x2000_0000, .bytes = &ram, .writable = true } },
        .{ .device = .{ .base = 0x4000_0000, .size = 0x10, .device = .{ .context = @ptrCast(&context), .read = HighDoorbell.read, .write = HighDoorbell.write } } },
    };
    var regions = try Regions.adopt(&entries);
    var cpu = arm.Processor(.{ .cores = every, .Bus = Regions }).init(&regions, .m4, .{}, .{});
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e118, 1 << 8));
    try std.testing.expectEqual(@as(?u32, 1 << 8), cpu.peek(4, 0xe000_e118));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(u32, 216), cpu.state.r[4]);
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_e218));
}

const Metronome = struct {
    var ticks: u32 = 0;

    fn read(_: *anyopaque, _: u32, _: Width, _: *Lines) ?u32 {
        return ticks;
    }

    fn write(_: *anyopaque, _: u32, _: Width, _: u32, _: *Lines) ?void {
        return null;
    }

    fn tick(_: *anyopaque, _: u32, raise: *Lines) ?u32 {
        ticks += 1;
        raise.* |= 1;
        return 1000;
    }
};

test "a device that keeps time raises an interrupt the core takes without ever being addressed, B3.4" {
    Metronome.ticks = 0;
    var flash: [0x70]u8 = @splat(0);
    std.mem.writeInt(u32, flash[0..4], 0x2000_0020, .little);
    std.mem.writeInt(u32, flash[4..8], 0x21, .little);
    std.mem.writeInt(u32, flash[0x40..][0..4], 0x61, .little);
    for ([_]u16{ 0xbf00, 0xbf00, 0xbf00, 0xbf00, 0xbe00 }, 0..) |code, i| {
        std.mem.writeInt(u16, flash[0x20 + i * 2 ..][0..2], code, .little);
    }
    for ([_]u16{ 0xf3ef, 0x8405, 0x4770 }, 0..) |code, i| {
        std.mem.writeInt(u16, flash[0x60 + i * 2 ..][0..2], code, .little);
    }
    var ram: [0x20]u8 = @splat(0);
    var context: u32 = 0;
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = 0, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = 0x2000_0000, .bytes = &ram, .writable = true } },
        .{ .device = .{ .base = 0x4000_0000, .size = 0x10, .device = .{ .context = @ptrCast(&context), .read = Metronome.read, .write = Metronome.write, .tick = Metronome.tick } } },
    };
    var regions = try Regions.adopt(&entries);
    var cpu = arm.Processor(.{ .cores = every, .Bus = Regions }).init(&regions, .m4, .{}, .{});
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e100, 1));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(u32, 16), cpu.state.r[4]);
    try std.testing.expect(Metronome.ticks > 0);
}

const Latch = struct {
    held: bool = false,
    fired: bool = false,

    fn read(_: *anyopaque, _: u32, _: Width, _: *Lines) ?u32 {
        return 0;
    }

    fn write(context: *anyopaque, _: u32, _: Width, _: u32, _: *Lines) ?void {
        const self: *Latch = @ptrCast(@alignCast(context));
        self.held = false;
    }

    fn tick(context: *anyopaque, _: u32, raise: *Lines) ?u32 {
        const self: *Latch = @ptrCast(@alignCast(context));
        if (self.fired) return null;
        self.fired = true;
        self.held = true;
        raise.* |= 1;
        return null;
    }

    fn asserted(context: *anyopaque) Lines {
        const self: *Latch = @ptrCast(@alignCast(context));
        return @intFromBool(self.held);
    }
};

test "an interrupt line a device still holds high at exception return is pended again, so a handler that does not clear its flag re-enters, B3.4.1" {
    var flash: [0x84]u8 = @splat(0);
    std.mem.writeInt(u32, flash[0..4], 0x2000_0040, .little);
    std.mem.writeInt(u32, flash[4..8], 0x21, .little);
    std.mem.writeInt(u32, flash[0x40..][0..4], 0x61, .little);
    for ([_]u16{ 0xbf00, 0xbf00, 0xbf00, 0xbf00, 0xbe00 }, 0..) |code, i| {
        std.mem.writeInt(u16, flash[0x20 + i * 2 ..][0..2], code, .little);
    }
    for ([_]u16{ 0x4806, 0x6801, 0x3101, 0x6001, 0x2903, 0xd101, 0x4a04, 0x6011, 0x4770 }, 0..) |code, i| {
        std.mem.writeInt(u16, flash[0x60 + i * 2 ..][0..2], code, .little);
    }
    std.mem.writeInt(u32, flash[0x7c..][0..4], 0x2000_0000, .little);
    std.mem.writeInt(u32, flash[0x80..][0..4], 0x4000_0000, .little);
    var ram: [0x40]u8 = @splat(0);
    var latch: Latch = .{};
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = 0, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = 0x2000_0000, .bytes = &ram, .writable = true } },
        .{ .device = .{ .base = 0x4000_0000, .size = 0x10, .device = .{ .context = &latch, .read = Latch.read, .write = Latch.write, .tick = Latch.tick, .asserted = Latch.asserted } } },
    };
    var regions = try Regions.adopt(&entries);
    var cpu = arm.Processor(.{ .cores = every, .Bus = Regions }).init(&regions, .m0plus, .{}, .{});
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_e100, 1));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 60 }).stop);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, ram[0..4], .little));
    try std.testing.expect(!latch.held);
}

test "the MPU and debug words a core without an MPU still answers read zero over the bus, B3.5.1 C1.6.2" {
    var m = loaded();
    var cpu = fast(.m0, &m);
    cpu.reset();
    for ([_]u32{ 0xe000_ed90, 0xe000_ed94, 0xe000_eda0, 0xe000_edb8, 0xe000_edc4 }) |address| {
        try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, address));
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, address, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, address));
    }
    var m4 = loaded();
    var main_profile = fast(.m4, &m4);
    main_profile.reset();
    for ([_]u32{ 0xe000_edf0, 0xe000_edf8 }) |address| {
        try std.testing.expectEqual(@as(?u32, 0), main_profile.peek(4, address));
        try std.testing.expectEqual(@as(?void, {}), main_profile.poke(4, address, 0xffff_ffff));
        try std.testing.expectEqual(@as(?u32, 0), main_profile.peek(4, address));
    }
    try std.testing.expectEqual(@as(?u32, null), main_profile.peek(4, 0xe000_edc8));
}

test "the ITM accepts what firmware writes to it and reads back nothing, C1.7" {
    var m = loaded();
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_0e80));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_0000, 'x'));
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_0000));
}

test "DWT_CYCCNT reports the cycles the run charged once TRCENA and CYCCNTENA are set, C1.8.3" {
    var m = loaded();
    var cpu = fast(.m4, &m);
    cpu.reset();
    _ = cpu.poke(4, 0xe000_edfc, scb_block.trcena);
    _ = cpu.poke(4, 0xe000_1000, 1);
    const before = cpu.peek(4, 0xe000_1004).?;
    const ran = cpu.run(.{ .instructions = 100 });
    const after = cpu.peek(4, 0xe000_1004).?;
    try std.testing.expectEqual(@as(u32, 0), before);
    try std.testing.expectEqual(@as(u32, @truncate(ran.cycles)), after);
}

test "a core without a cycle counter reads DWT_CYCCNT as zero however long it runs, C1.7" {
    var m = loaded();
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    _ = cpu.poke(4, 0xe000_edfc, scb_block.trcena);
    _ = cpu.poke(4, 0xe000_1000, 1);
    _ = cpu.run(.{ .instructions = 100 });
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_1004));
}

test "the blocks the private peripheral bus does not carry still fault" {
    var m = loaded();
    var cpu = fast(.m4, &m);
    cpu.reset();
    for ([_]u32{ 0xe000_2000, 0xe004_0000, 0xe00f_f000, 0xe000_ef90 }) |address| {
        try std.testing.expectEqual(@as(?u32, null), cpu.peek(4, address));
        try std.testing.expectEqual(@as(?void, null), cpu.poke(4, address, 0));
    }
}

test "the stack pointers and the masks are banked between the two Security states, B3.7" {
    var m = loaded();
    var cpu = fast(.m33, &m);
    cpu.reset();
    cpu.state.msp = 0x1000;
    cpu.state.psp = 0x2000;
    cpu.state.basepri = 0x20;
    cpu.state.primask = true;
    cpu.banked = .{ .msp = 0x3000, .psp = 0x4000, .basepri = 0x40 };
    cpu.bank();
    try std.testing.expectEqual(@as(u32, 0x3000), cpu.state.msp);
    try std.testing.expectEqual(@as(u32, 0x4000), cpu.state.psp);
    try std.testing.expectEqual(@as(u8, 0x40), cpu.state.basepri);
    try std.testing.expect(!cpu.state.primask);
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.banked.msp);
    try std.testing.expect(cpu.banked.primask);
    cpu.bank();
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.state.msp);
    try std.testing.expectEqual(@as(u8, 0x20), cpu.state.basepri);
    try std.testing.expect(cpu.state.primask);
}

test "the pointer authentication keys bank with the Security state, and only the M85 carries the extension, B6.1.1" {
    var m = loaded();
    var cpu = fast(.m85, &m);
    cpu.reset();
    try std.testing.expect(cpu.pacbti());
    cpu.state.pac_key = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    cpu.banked.pac_key = .{ 9, 10, 11, 12, 13, 14, 15, 16 };
    cpu.bank();
    try std.testing.expectEqual([8]u32{ 9, 10, 11, 12, 13, 14, 15, 16 }, cpu.state.pac_key);
    try std.testing.expectEqual([8]u32{ 1, 2, 3, 4, 5, 6, 7, 8 }, cpu.banked.pac_key);
    cpu.bank();
    try std.testing.expectEqual([8]u32{ 1, 2, 3, 4, 5, 6, 7, 8 }, cpu.state.pac_key);
    var m55 = loaded();
    var other = fast(.m55, &m55);
    try std.testing.expect(!other.pacbti());
}

test "a core without the Security Extension has nothing to bank, B3.7" {
    var m = loaded();
    var cpu = fast(.m4, &m);
    cpu.reset();
    cpu.state.msp = 0x1000;
    cpu.bank();
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.state.msp);
    try std.testing.expectEqual(@as(u32, 0), cpu.banked.msp);
}

fn callable(m: *Memory, address: u32) void {
    std.mem.writeInt(u32, m.bytes[address..][0..4], 0xe97f_e97f, .little);
}

fn nonSecureCallable(cpu: anytype) void {
    _ = cpu.poke(4, 0xe000_eddc, 0x0000_0800);
    _ = cpu.poke(4, 0xe000_ede0, 0x0000_0fe3);
    _ = cpu.poke(4, 0xe000_edd0, 1);
    cpu.state.secure = false;
    cpu.reguard();
}

fn nonSecure(cpu: anytype) void {
    _ = cpu.poke(4, 0xe000_eddc, 0x0000_0000);
    _ = cpu.poke(4, 0xe000_ede0, 0x0000_07e1);
    _ = cpu.poke(4, 0xe000_edd0, 1);
    cpu.state.secure = false;
    cpu.reguard();
    cpu.bank();
}

test "a Non-secure access to Secure memory is refused and recorded in SFSR and SFAR, while a debugger's refused access records nothing, D1.2.232" {
    var m = placed(&.{ 0x2000_2000, 0x9 }, &.{0x8}, &.{&.{ 0x2101, 0x02c9, 0x6808, 0xbe00 }});
    var cpu = fast(.m33, &m);
    cpu.reset();
    nonSecure(&cpu);
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0x40));
    try std.testing.expectEqual(@as(?u32, null), cpu.peek(4, 0x800));
    try std.testing.expectEqual(@as(?void, null), cpu.poke(4, 0x800, 1));
    cpu.state.secure = true;
    cpu.reguard();
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ede4));
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ede8));
    cpu.state.secure = false;
    cpu.reguard();
    try std.testing.expectEqual(@as(?arm.Stop, .secure_fault), cpu.run(.{ .instructions = 10 }).stop);
    cpu.state.secure = true;
    cpu.reguard();
    try std.testing.expectEqual(@as(?u32, 0x48), cpu.peek(4, 0xe000_ede4));
    try std.testing.expectEqual(@as(?u32, 0x800), cpu.peek(4, 0xe000_ede8));
}

test "a Non-secure instruction fetch from Secure memory is refused and sets INVEP, D1.2.232" {
    var m = loaded();
    var cpu = fast(.m33, &m);
    cpu.reset();
    nonSecure(&cpu);
    try std.testing.expectEqual(@as(?u16, 0), cpu.parcel(0x40));
    try std.testing.expectEqual(@as(?u16, null), cpu.parcel(0x800));
    cpu.state.secure = true;
    cpu.reguard();
    try std.testing.expectEqual(@as(?u32, 1), cpu.peek(4, 0xe000_ede4));
}

test "a bus that supplies its own fetch is still checked by the SAU, D1.2.232" {
    var m: Fetching = .{ .inner = loaded() };
    var cpu = CpuFetching.init(&m, .m33, .{}, .{});
    cpu.reset();
    nonSecure(&cpu);
    try std.testing.expectEqual(@as(?u16, 0), cpu.parcel(0x40));
    try std.testing.expectEqual(@as(?u16, null), cpu.parcel(0x800));
    cpu.state.secure = true;
    cpu.reguard();
    try std.testing.expectEqual(@as(?u32, 1), cpu.peek(4, 0xe000_ede4));
}

test "a Non-secure fetch from a Non-secure callable region is allowed, because that is what the gateway is for, E2.1.366" {
    var m = loaded();
    callable(&m, 0x800);
    var cpu = fast(.m33, &m);
    cpu.reset();
    nonSecureCallable(&cpu);
    try std.testing.expectEqual(@as(?u16, 0xe97f), cpu.parcel(0x800));
    try std.testing.expectEqual(@as(?u16, 0xe97f), cpu.parcel(0x802));
    try std.testing.expectEqual(@as(?u32, null), cpu.peek(4, 0x800));
}

test "a Non-secure fetch from a Non-secure callable region that is not an SG is refused and sets INVEP, E2.1.137" {
    var m = loaded();
    callable(&m, 0x800);
    std.mem.writeInt(u16, m.bytes[0x810..][0..2], 0x4770, .little);
    var cpu = fast(.m33, &m);
    cpu.reset();
    nonSecureCallable(&cpu);
    try std.testing.expectEqual(@as(?u16, null), cpu.parcel(0x810));
    cpu.state.secure = true;
    cpu.reguard();
    try std.testing.expectEqual(@as(?u32, 1), cpu.peek(4, 0xe000_ede4));
}

test "a Non-secure fetch of the second half of a would-be gateway is refused and sets INVEP, E2.1.137" {
    var m = loaded();
    callable(&m, 0x800);
    std.mem.writeInt(u16, m.bytes[0x802..][0..2], 0x4770, .little);
    var cpu = fast(.m33, &m);
    cpu.reset();
    nonSecureCallable(&cpu);
    try std.testing.expectEqual(@as(?u16, 0xe97f), cpu.parcel(0x800));
    try std.testing.expectEqual(@as(?u16, null), cpu.parcel(0x802));
    cpu.state.secure = true;
    cpu.reguard();
    try std.testing.expectEqual(@as(?u32, 1), cpu.peek(4, 0xe000_ede4));
}

test "Secure code reaches Non-secure memory freely, E2.1.366" {
    var m = loaded();
    var cpu = fast(.m33, &m);
    cpu.reset();
    _ = cpu.poke(4, 0xe000_eddc, 0x0000_0000);
    _ = cpu.poke(4, 0xe000_ede0, 0x0000_07e1);
    _ = cpu.poke(4, 0xe000_edd0, 1);
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0x40));
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0x800));
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ede4));
}

test "SFSR clears the bits written to it and a core without the extension has none, D1.2.232" {
    var m = placed(&.{ 0x2000_2000, 0x9 }, &.{0x8}, &.{&.{ 0x2101, 0x02c9, 0x6808, 0xbe00 }});
    var cpu = fast(.m33, &m);
    cpu.reset();
    nonSecure(&cpu);
    try std.testing.expectEqual(@as(?arm.Stop, .secure_fault), cpu.run(.{ .instructions = 10 }).stop);
    cpu.state.secure = true;
    cpu.reguard();
    try std.testing.expectEqual(@as(?u32, 0x48), cpu.peek(4, 0xe000_ede4));
    _ = cpu.poke(4, 0xe000_ede4, 0x08);
    try std.testing.expectEqual(@as(?u32, 0x40), cpu.peek(4, 0xe000_ede4));
    var m4 = loaded();
    var four = fast(.m4, &m4);
    four.reset();
    try std.testing.expectEqual(@as(?u32, null), four.peek(4, 0xe000_ede4));
}

const secure_vectors = [_]u32{ 0xc00, 0x41, 0, 0, 0, 0, 0, 0x801 };

fn nonSecureThread(cpu: anytype) void {
    _ = cpu.poke(4, 0xe000_eddc, 0x0000_0000);
    _ = cpu.poke(4, 0xe000_ede0, 0x0000_07e1);
    _ = cpu.poke(4, 0xe000_edd0, 1);
    _ = cpu.poke(4, 0xe000_ed24, scb_block.secureflt_ena);
    cpu.state.secure = false;
    cpu.reguard();
    cpu.bank();
    cpu.state.msp = 0x400;
}

test "a refused Non-secure access takes SecureFault, stacks on the Non-secure stack and runs the handler Secure, B3.18" {
    var m = placed(&secure_vectors, &.{ 0x40, 0x800 }, &.{
        &.{ 0x4901, 0x6808, 0xbe00, 0x0000, 0x0900, 0x0000 },
        &.{ 0x4674, 0x466d, 0xbe00 },
    });
    var cpu = fast(.m33, &m);
    cpu.reset();
    nonSecureThread(&cpu);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expect(cpu.state.secure);
    try std.testing.expectEqual(@as(u32, 0xffff_ffb9), cpu.state.r[4]);
    try std.testing.expectEqual(@as(u32, 0xc00), cpu.state.r[5]);
    try std.testing.expectEqual(@as(u32, 7), cpu.state.xpsr & State.ipsr_mask);
    try std.testing.expectEqual(@as(?u32, 0x42), cpu.peek(4, 0x3e0 + 0x18));
    try std.testing.expectEqual(@as(?u32, 0x48), cpu.peek(4, 0xe000_ede4));
    try std.testing.expectEqual(@as(?u32, 0x900), cpu.peek(4, 0xe000_ede8));
}

test "returning from a Secure exception to a Non-secure background restores the Non-secure banked registers, B3.22" {
    var m = placed(&secure_vectors, &.{ 0x40, 0x800 }, &.{
        &.{ 0x4901, 0x6808, 0xbe00, 0x0000, 0x0900, 0x0000 },
        &.{ 0x4674, 0x4802, 0x2102, 0x6001, 0x4770, 0x0000, 0xedd0, 0xe000 },
    });
    var cpu = fast(.m33, &m);
    cpu.reset();
    nonSecureThread(&cpu);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expect(!cpu.state.secure);
    try std.testing.expectEqual(@as(u32, 0xffff_ffb9), cpu.state.r[4]);
    try std.testing.expectEqual(@as(u32, 0x400), cpu.state.msp);
    try std.testing.expectEqual(@as(u32, 0x44), cpu.state.pc);
    try std.testing.expectEqual(@as(u64, 0), cpu.active);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.xpsr & State.ipsr_mask);
}

test "an interrupt NVIC_ITNS gives to Non-secure state is taken there, with the callee registers stacked below the state context and cleared behind it, B3.19 B3.23 E2.1.334" {
    var m = placed(&.{ 0x1000, 0x41 }, &.{ 0x40, 0x440, 0x480 }, &.{
        &.{ 0x2411, 0x2522, 0x2633, 0x2744, 0x4804, 0x2101, 0x6001, 0xbf00, 0xbe00, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xe200, 0xe000 },
        &.{ 0x0481, 0x0000 },
        &.{ 0x4803, 0x2155, 0x6001, 0x4671, 0x6041, 0x4770, 0x0000, 0x0000, 0x0600, 0x0000 },
    });
    var cpu = fast(.m33, &m);
    cpu.reset();
    _ = cpu.poke(4, 0xe000_eddc, 0x0000_0400);
    _ = cpu.poke(4, 0xe000_ede0, 0x0000_07e1);
    _ = cpu.poke(4, 0xe000_edd0, 1);
    _ = cpu.poke(4, 0xe002_ed08, 0x0000_0400);
    _ = cpu.poke(4, 0xe000_e380, 1);
    _ = cpu.poke(4, 0xe000_e100, 1);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(?u32, 0x55), cpu.peek(4, 0x600));
    try std.testing.expectEqual(@as(?u32, 0xffff_fff8), cpu.peek(4, 0x604));
    try std.testing.expectEqual(@as(?u32, 0xfefa_125b), cpu.peek(4, 0xfb8));
    try std.testing.expectEqual(@as(?u32, 0x11), cpu.peek(4, 0xfc0));
    try std.testing.expectEqual(@as(?u32, 0xe000_e200), cpu.peek(4, 0xfe0));
    try std.testing.expectEqual([_]u32{ 0x11, 0x22, 0x33, 0x44 }, cpu.state.r[4..8].*);
    try std.testing.expect(cpu.state.secure);
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.state.msp);
    try std.testing.expectEqual(@as(u64, 0), cpu.active);
}

test "clearing PRIMASK_NS from Secure state lets in at once the interrupt it was holding off, B3.32" {
    var m = placed(&.{ 0x1000, 0x41 }, &.{ 0x40, 0x440, 0x480 }, &.{
        &.{ 0x2001, 0xf380, 0x8890, 0x4805, 0x2101, 0x6001, 0x2000, 0xf380, 0x8890, 0x2555, 0xbe00, 0, 0, 0, 0xe200, 0xe000 },
        &.{ 0x0481, 0x0000 },
        &.{ 0x4802, 0x2166, 0x6001, 0x4770, 0x0000, 0x0000, 0x0600, 0x0000 },
    });
    var cpu = fast(.m33, &m);
    cpu.reset();
    launched(&cpu);
    _ = cpu.poke(4, 0xe000_e380, 1);
    _ = cpu.poke(4, 0xe000_e100, 1);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(?u32, 0x66), cpu.peek(4, 0x600));
    try std.testing.expectEqual(@as(u32, 0x55), cpu.state.r[5]);
}

test "an exception taken to Non-secure state carries CONTROL_NS.SPSEL in EXC_RETURN, and the return puts it back there, E2.1.122 E2.1.121" {
    var m = placed(&.{ 0x1000, 0x41 }, &.{ 0x40, 0x440, 0x480 }, &.{
        &.{ 0x2411, 0x2522, 0x2633, 0x2744, 0x4804, 0x2101, 0x6001, 0xbf00, 0xbe00, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xe200, 0xe000 },
        &.{ 0x0481, 0x0000 },
        &.{ 0x4803, 0x2155, 0x6001, 0x4671, 0x6041, 0x4770, 0x0000, 0x0000, 0x0600, 0x0000 },
    });
    var cpu = fast(.m33, &m);
    cpu.reset();
    launched(&cpu);
    cpu.banked.control |= State.control_spsel;
    _ = cpu.poke(4, 0xe000_e380, 1);
    _ = cpu.poke(4, 0xe000_e100, 1);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expect(cpu.state.secure);
    try std.testing.expectEqual(@as(?u32, 0xffff_fffc), cpu.peek(4, 0x604));
    try std.testing.expectEqual(State.control_spsel, cpu.banked.control & State.control_spsel);
    try std.testing.expectEqual(@as(u32, 0), cpu.state.control & State.control_spsel);
}

test "an exception return clears the FAULTMASK of the Security state the returning exception targeted, not the background's, E2.1.91" {
    var m = placed(&.{ 0x1000, 0x41 }, &.{ 0x40, 0x440, 0x480 }, &.{
        &.{ 0x2411, 0x2522, 0x2633, 0x2744, 0x4804, 0x2101, 0x6001, 0xbf00, 0xbe00, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xe200, 0xe000 },
        &.{ 0x0481, 0x0000 },
        &.{ 0xb671, 0x4770 },
    });
    var cpu = fast(.m33, &m);
    cpu.reset();
    launched(&cpu);
    _ = cpu.poke(4, 0xe000_e380, 1);
    _ = cpu.poke(4, 0xe000_e100, 1);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expect(cpu.state.secure);
    try std.testing.expect(!cpu.banked.faultmask);
    try std.testing.expect(!cpu.state.faultmask);
}

test "a return from HardFault keeps FAULTMASK on ARMv8-M and clears it on ARMv7-M, E2.1.91 B1.5.8" {
    inline for (.{ .m33, .m4 }, .{ true, false }) |core, kept| {
        var m = placed(&.{ 0x1000, 0x41, 0, 0x441 }, &.{ 0x40, 0x440 }, &.{
            &.{ 0xde00, 0xbe00 },
            &.{ 0x9806, 0x3002, 0x9006, 0x4770 },
        });
        var cpu = fast(core, &m);
        cpu.reset();
        _ = cpu.run(.{ .instructions = 3 });
        try std.testing.expectEqual(@as(u32, 0x446), cpu.state.pc);
        cpu.state.faultmask = true;
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        try std.testing.expectEqual(@as(u32, 0x42), cpu.state.pc);
        try std.testing.expectEqual(kept, cpu.state.faultmask);
    }
}

test "a Non-secure exception return with a broken integrity signature does not restore the Secure callee registers, B3.23" {
    var m = placed(&.{ 0x1000, 0x41, 0, 0x101 }, &.{ 0x40, 0x100, 0x440, 0x480 }, &.{
        &.{ 0x2411, 0x2522, 0x2633, 0x2744, 0x4804, 0x2101, 0x6001, 0xbf00, 0xbe00, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xe200, 0xe000 },
        &.{0xbe00},
        &.{ 0x0481, 0x0000 },
        &.{ 0x4803, 0x2155, 0x6001, 0x4671, 0x6041, 0x4770, 0x0000, 0x0000, 0x0600, 0x0000 },
    });
    var cpu = fast(.m33, &m);
    cpu.reset();
    _ = cpu.poke(4, 0xe000_eddc, 0x0000_0400);
    _ = cpu.poke(4, 0xe000_ede0, 0x0000_07e1);
    _ = cpu.poke(4, 0xe000_edd0, 1);
    _ = cpu.poke(4, 0xe002_ed08, 0x0000_0400);
    _ = cpu.poke(4, 0xe000_e380, 1);
    _ = cpu.poke(4, 0xe000_e100, 1);
    _ = cpu.run(.{ .instructions = 8 });
    try std.testing.expect(!cpu.state.secure);
    cpu.state.secure = true;
    cpu.reguard();
    try std.testing.expectEqual(@as(?u32, 0xfefa_125b), cpu.peek(4, 0xfb8));
    _ = cpu.poke(4, 0xfb8, 0xfefa_1200);
    cpu.state.secure = false;
    cpu.reguard();
    const stop = cpu.run(.{ .instructions = 100 }).stop;
    cpu.state.secure = true;
    cpu.reguard();
    try std.testing.expectEqual(@as(?u32, 2), cpu.peek(4, 0xe000_ede4));
    try std.testing.expectEqual([_]u32{ 0, 0, 0, 0 }, cpu.state.r[4..8].*);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), stop);
    try std.testing.expectEqual(@as(u32, 3), cpu.state.xpsr & State.ipsr_mask);
}

fn launched(cpu: anytype) void {
    _ = cpu.poke(4, 0xe000_eddc, 0x0000_0400);
    _ = cpu.poke(4, 0xe000_ede0, 0x0000_07e1);
    _ = cpu.poke(4, 0xe000_edd0, 1);
    _ = cpu.poke(4, 0xe002_ed08, 0x0000_0400);
}

test "SVCall is banked, so a supervisor call from Non-secure state runs the Non-secure handler off its own vector table, B3.11" {
    var m = placed(&.{ 0x1000, 0x481 }, &.{ 0x42c, 0x480, 0x4a0 }, &.{
        &.{ 0x04a1, 0x0000 },
        &.{ 0xdf00, 0xbe00 },
        &.{ 0xf3ef, 0x8405, 0x4770 },
    });
    var cpu = fast(.m33, &m);
    cpu.reset();
    launched(&cpu);
    cpu.state.secure = false;
    cpu.reguard();
    cpu.bank();
    cpu.state.msp = 0x700;
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 11), cpu.state.r[4]);
    try std.testing.expect(!cpu.state.secure);
    try std.testing.expectEqual(@as(u32, 0x700), cpu.state.msp);
    try std.testing.expectEqual(@as(u32, 0x482), cpu.state.pc);
    try std.testing.expectEqual(@as(u64, 0), cpu.active);
}

test "AIRCR.PRIS maps Non-secure priorities into the bottom half of the range, so BASEPRI_S holds off an interrupt it would otherwise lose to, B3.13" {
    for ([_]u32{ 0, scb_block.pris }) |shift| {
        var m = placed(&.{ 0x1000, 0x41 }, &.{ 0x40, 0x440, 0x480 }, &.{
            &.{ 0x2080, 0xf380, 0x8811, 0x4804, 0x2101, 0x6001, 0xbf00, 0xbe00, 0x0000, 0x0000, 0x0000, 0x0000, 0xe200, 0xe000 },
            &.{ 0x0481, 0x0000 },
            &.{ 0x4802, 0x2155, 0x6001, 0x4770, 0x0000, 0x0000, 0x0600, 0x0000 },
        });
        var cpu = fast(.m33, &m);
        cpu.reset();
        launched(&cpu);
        _ = cpu.poke(4, 0xe000_ed0c, @as(u32, scb_block.vectkey) << 16 | shift);
        _ = cpu.poke(4, 0xe000_e380, 1);
        _ = cpu.poke(4, 0xe000_e100, 1);
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        try std.testing.expectEqual(@as(?u32, if (shift == 0) 0x55 else 0), cpu.peek(4, 0x600));
    }
}

test "AIRCR.BFHFNMINS gives a Non-secure fault the Non-secure HardFault, and without it the escalation stays Secure, B3.11" {
    for ([_]u32{ 0, scb_block.bfhfnmins }) |route| {
        var m = placed(&.{ 0x1000, 0x481, 0, 0x101 }, &.{ 0x100, 0x40c, 0x480, 0x4c0 }, &.{
            &.{0xbe00},
            &.{ 0x04c1, 0x0000 },
            &.{0xde00},
            &.{0xbe00},
        });
        var cpu = fast(.m33, &m);
        cpu.reset();
        launched(&cpu);
        _ = cpu.poke(4, 0xe000_ed0c, @as(u32, scb_block.vectkey) << 16 | route);
        cpu.state.secure = false;
        cpu.reguard();
        cpu.bank();
        cpu.state.msp = 0x700;
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        try std.testing.expectEqual(route == 0, cpu.state.secure);
        try std.testing.expectEqual(@as(u32, if (route == 0) 0x100 else 0x4c0), cpu.state.pc);
        try std.testing.expectEqual(@as(u32, 3), cpu.state.xpsr & State.ipsr_mask);
    }
}

test "the NVIC bits of an interrupt that targets Secure state are RAZ/WI from Non-secure state, D1.2.185 D1.2.186" {
    var m: Memory = .{};
    var cpu = fast(.m33, &m);
    cpu.reset();
    _ = cpu.poke(4, 0xe000_e380, 2);
    _ = cpu.poke(4, 0xe000_e400, 0x0000_2000);
    nonSecure(&cpu);
    _ = cpu.poke(4, 0xe000_e100, 3);
    _ = cpu.poke(4, 0xe000_e400, 0x0000_e0e0);
    _ = cpu.poke(4, 0xe000_e200, 3);
    try std.testing.expectEqual(@as(u32, 2), @as(u32, @truncate(cpu.nvic.enabled)));
    try std.testing.expectEqual(@as(u32, 2), @as(u32, @truncate(cpu.pending >> arm.first_interrupt)));
    try std.testing.expectEqual(@as(u8, 0), cpu.nvic.priority(0));
    try std.testing.expectEqual(@as(u8, 0xe0), cpu.nvic.priority(1));
    try std.testing.expectEqual(@as(?u32, 2), cpu.peek(4, 0xe000_e100));
    try std.testing.expectEqual(@as(?u32, 0x0000_e000), cpu.peek(4, 0xe000_e400));
}

test "with one SysTick and ICSR.STTNS clear, a Non-secure access to it is RAZ/WI, D1.2.241" {
    var m: Memory = .{};
    var cpu = fast(.m33, &m);
    cpu.reset();
    _ = cpu.poke(4, 0xe000_e014, 1000);
    nonSecure(&cpu);
    _ = cpu.poke(4, 0xe000_e014, 5);
    _ = cpu.poke(4, 0xe000_e010, 3);
    try std.testing.expectEqual(@as(u32, 1000), cpu.systick.rvr);
    try std.testing.expectEqual(@as(u32, 0), cpu.systick.csr & 3);
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_e014));
    cpu.state.secure = true;
    cpu.reguard();
    _ = cpu.poke(4, 0xe000_ed04, scb_block.sttns);
    cpu.state.secure = false;
    cpu.reguard();
    _ = cpu.poke(4, 0xe000_e014, 5);
    try std.testing.expectEqual(@as(u32, 5), cpu.systick.rvr);
    try std.testing.expectEqual(@as(?u32, 5), cpu.peek(4, 0xe000_e014));
}

test "ICSR.PENDNMISET is RAZ/WI from Non-secure state while AIRCR.BFHFNMINS is zero, D1.2.126" {
    var m = loaded();
    var cpu = fast(.m33, &m);
    cpu.reset();
    nonSecure(&cpu);
    _ = cpu.poke(4, 0xe000_ed04, 1 << 31);
    try std.testing.expectEqual(@as(arm.Set, 0), cpu.pending & arm.one(arm.nmi));
    try std.testing.expectEqual(@as(u32, 0), cpu.peek(4, 0xe000_ed04).? & 1 << 31);
    cpu.state.secure = true;
    cpu.reguard();
    _ = cpu.poke(4, 0xe000_ed0c, @as(u32, scb_block.vectkey) << 16 | scb_block.bfhfnmins);
    cpu.state.secure = false;
    cpu.reguard();
    _ = cpu.poke(4, 0xe000_ed04, 1 << 31);
    try std.testing.expect(cpu.pending & arm.one(arm.nmi + arm.ns_base) != 0);
    try std.testing.expectEqual(@as(u32, 1 << 31), cpu.peek(4, 0xe000_ed04).? & 1 << 31);
}

test "ICSR.PENDSTSET is RAZ/WI from Non-secure state while ICSR.STTNS is zero, D1.2.126" {
    var m = loaded();
    var cpu = fast(.m33, &m);
    cpu.reset();
    nonSecure(&cpu);
    _ = cpu.poke(4, 0xe000_ed04, 1 << 26);
    const either = arm.one(arm.systick) | arm.one(arm.systick + arm.ns_base);
    try std.testing.expectEqual(@as(arm.Set, 0), cpu.pending & either);
    cpu.state.secure = true;
    cpu.reguard();
    _ = cpu.poke(4, 0xe000_ed04, scb_block.sttns);
    cpu.state.secure = false;
    cpu.reguard();
    _ = cpu.poke(4, 0xe000_ed04, 1 << 26);
    try std.testing.expect(cpu.pending & arm.one(arm.systick + arm.ns_base) != 0);
}

test "ICSR.ISRPENDING reports an external interrupt and not a pending PendSV, D1.2.126" {
    var m = loaded();
    var cpu = fast(.m33, &m);
    cpu.reset();
    nonSecure(&cpu);
    _ = cpu.poke(4, 0xe000_ed04, 1 << 28);
    try std.testing.expectEqual(@as(u32, 1 << 28), cpu.peek(4, 0xe000_ed04).? & 1 << 28);
    try std.testing.expectEqual(@as(u32, 0), cpu.peek(4, 0xe000_ed04).? & 1 << 22);
    cpu.pend(0);
    try std.testing.expectEqual(@as(u32, 1 << 22), cpu.peek(4, 0xe000_ed04).? & 1 << 22);
}

test "Secure software pends the Non-secure PendSV through the ICSR_NS alias, D1.2.126" {
    var m = loaded();
    var cpu = fast(.m33, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe002_ed04, 1 << 28));
    try std.testing.expect(cpu.pending & arm.one(arm.pendsv + arm.ns_base) != 0);
    try std.testing.expectEqual(@as(u32, 1 << 28), cpu.peek(4, 0xe002_ed04).? & 1 << 28);
    try std.testing.expectEqual(@as(u32, 0), cpu.peek(4, 0xe000_ed04).? & 1 << 28);
}

test "ICSR_S.STTNS hands the one SysTick to the Non-secure exception instance, E2.1.123" {
    for ([_]u32{ 0, scb_block.sttns }) |side| {
        var m = placed(&.{ 0x1000, 0x41, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x101 }, &.{ 0x40, 0x100, 0x43c, 0x4c0 }, &.{
            &.{ 0x4803, 0x2101, 0x6041, 0x2103, 0x6001, 0xbf00, 0xbf00, 0xbe00, 0xe010, 0xe000 },
            &.{0xbe00},
            &.{ 0x04c1, 0x0000 },
            &.{0xbe00},
        });
        var cpu = fast(.m33, &m);
        cpu.reset();
        launched(&cpu);
        _ = cpu.poke(4, 0xe000_ed04, side);
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
        try std.testing.expectEqual(side == 0, cpu.state.secure);
        try std.testing.expectEqual(@as(u32, if (side == 0) 0x100 else 0x4c0), cpu.state.pc);
        try std.testing.expectEqual(@as(u32, 15), cpu.state.xpsr & State.ipsr_mask);
    }
}

test "the Cortex-M23 has no Main Extension, so a refused Non-secure access escalates to HardFault and SFSR reads zero, B3.18 D1.2.232" {
    var m = placed(&.{ 0xc00, 0x41, 0, 0x801 }, &.{ 0x40, 0x800 }, &.{
        &.{ 0x4901, 0x6808, 0xbe00, 0x0000, 0x0900, 0x0000 },
        &.{0xbe00},
    });
    var cpu = fast(.m23, &m);
    cpu.reset();
    nonSecureThread(&cpu);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expect(cpu.state.secure);
    try std.testing.expectEqual(@as(u32, 3), cpu.state.xpsr & State.ipsr_mask);
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ede4));
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ede8));
}

test "ARMv8-M Baseline pins CCR, so an unaligned access always faults and SDIV by zero never traps, D1.2.9" {
    var m = placed(&svc_vectors, &.{ 0x40, 0xa0 }, &.{ &.{ 0x2055, 0x2103, 0x6008, 0xbe00 }, &.{0xbe00} });
    var cpu = fast(.m23, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed14, 0x200 | scb_block.div_0_trp));
    try std.testing.expectEqual(@as(?u32, 0x209), cpu.peek(4, 0xe000_ed14));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u64, 1 << 3), cpu.active);

    var d = placed(&svc_vectors, &.{0x40}, &.{&.{ 0x2007, 0x2100, 0xfb90, 0xf0f1, 0xbe00 }});
    var quiet = fast(.m23, &d);
    quiet.reset();
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), quiet.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 0), quiet.state.r[0]);
    try std.testing.expectEqual(@as(u64, 0), quiet.active);
}

fn halfImage() Memory {
    var m = loaded();
    for ([_]u16{ 0xee71, 0x0921, 0xbe00 }, 0..) |code, i| std.mem.writeInt(u16, m.bytes[8 + 2 * i ..][0..2], code, .little);
    return m;
}

test "half-precision arithmetic runs on the M55 and raises NOCP on the M7, which leaves coprocessor 9 unimplemented, C2.4.302" {
    var fifty = halfImage();
    var cpu = fast(.m55, &fifty);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed88, 0x00f0_0000));
    cpu.state.fp[2] = 0x3c00;
    cpu.state.fp[3] = 0x4000;
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 4 }).stop);
    try std.testing.expectEqual(@as(u32, 0x4200), cpu.state.fp[1]);
    var seven = halfImage();
    var single = fast(.m7, &seven);
    single.reset();
    try std.testing.expectEqual(@as(?void, {}), single.poke(4, 0xe000_ed88, 0x00f0_0000));
    try std.testing.expectEqual(@as(?arm.Stop, .no_coprocessor), single.run(.{ .instructions = 4 }).stop);
}

test "the M55 resets FPSCR with LTPSIZE reading four while the M7 resets it to zero, D1.2.103" {
    var fifty = loaded();
    var cpu = fast(.m55, &fifty);
    cpu.reset();
    try std.testing.expectEqual(@as(u32, 0x0004_0000), cpu.state.fpscr);
    var seven = loaded();
    var single = fast(.m7, &seven);
    single.reset();
    try std.testing.expectEqual(@as(u32, 0), single.state.fpscr);
}

fn deferring() Memory {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x800, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 0x9, .little);
    for ([_]u16{ 0xec21, 0x0a00, 0xee01, 0x2a10, 0xbe00 }, 0..) |code, i| std.mem.writeInt(u16, m.bytes[8 + 2 * i ..][0..2], code, .little);
    return m;
}

test "VLSTM records the frame and the privilege it was named at, and the next instruction writes it, D1.2.99 D1.2.100 C2.4.368" {
    var m = deferring();
    var cpu = fast(.m33, &m);
    cpu.reset();
    _ = cpu.scb.writeRegister(scb_block.cpacr, scb_block.cp10);
    cpu.scb.put(scb_block.fpccr, cpu.scb.get(scb_block.fpccr) | scb_block.treat_as_secure);
    cpu.state.control |= State.control_sfpa;
    cpu.state.r[1] = 0x200;
    cpu.state.r[2] = 0x777;
    cpu.state.fp[0] = 0x1234;
    cpu.state.fp[15] = 0x5678;
    try std.testing.expectEqual(arm.Run{ .instructions = 2, .cycles = 2, .latency = 0, .stop = .breakpoint, .ended = .stopped }, cpu.run(.{ .instructions = 100 }));
    const fpccr = cpu.scb.get(scb_block.fpccr);
    try std.testing.expectEqual(@as(u32, 0), fpccr & scb_block.lspact);
    try std.testing.expect(fpccr & (scb_block.fp_secure | scb_block.fp_thread | scb_block.hfrdy) == scb_block.fp_secure | scb_block.fp_thread | scb_block.hfrdy);
    try std.testing.expectEqual(@as(u32, 0x200), cpu.scb.get(scb_block.fpcar));
    try std.testing.expectEqual(@as(u32, 0x1234), std.mem.readInt(u32, m.bytes[0x200..0x204], .little));
    try std.testing.expectEqual(@as(u32, 0x5678), std.mem.readInt(u32, m.bytes[0x23c..0x240], .little));
    try std.testing.expectEqual(@as(u32, 0), cpu.state.fp[0]);
    try std.testing.expectEqual(@as(u32, 0x777), cpu.state.fp[2]);
}

test "the extended exception frame carries the vector predication register where the core has one, B3.19" {
    inline for (.{ .m55, .m33 }) |core| {
        var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
            &.{ 0xdf00, 0xbe00 },
            &.{ 0xbf00, 0x4770 },
        });
        var cpu = fast(core, &m);
        cpu.reset();
        _ = cpu.scb.writeRegister(scb_block.cpacr, scb_block.cp10);
        cpu.scb.put(scb_block.fpccr, cpu.scb.get(scb_block.fpccr) & ~scb_block.lspen);
        cpu.state.control |= State.control_fpca;
        cpu.state.vpr = 0x1357;
        try std.testing.expectEqual(@as(?arm.Stop, null), cpu.run(.{ .instructions = 2 }).stop);
        const frame = cpu.state.msp;
        try std.testing.expectEqual(@as(u32, if (core == .m55) 0x1357 else 0), std.mem.readInt(u32, m.bytes[frame + 0x64 ..][0..4], .little));
        cpu.state.vpr = 0;
        _ = cpu.run(.{ .instructions = 1 });
        try std.testing.expectEqual(@as(u32, 0x42), cpu.state.pc);
        try std.testing.expectEqual(@as(u32, if (core == .m55) 0x1357 else 0), cpu.state.vpr);
    }
}

test "exception entry with FPCCR.LSPEN set defers the floating-point context instead of writing it, v7-M B1.5.6, v8-M B3.19" {
    inline for (.{ .m4, .m33 }) |core| {
        var m = placed(&svc_vectors, &.{ 0x40, 0x60 }, &.{
            &.{ 0xdf00, 0xbe00 },
            &.{ 0xbf00, 0x4770 },
        });
        var cpu = fast(core, &m);
        cpu.reset();
        _ = cpu.scb.writeRegister(scb_block.cpacr, scb_block.cp10);
        cpu.state.control |= State.control_fpca;
        cpu.state.fp[0] = 0xfeedface;
        try std.testing.expectEqual(@as(?arm.Stop, null), cpu.run(.{ .instructions = 2 }).stop);
        const frame = cpu.state.msp;
        try std.testing.expectEqual(scb_block.lspact, cpu.scb.get(scb_block.fpccr) & scb_block.lspact);
        try std.testing.expectEqual(frame + 0x20, cpu.scb.get(scb_block.fpcar));
        try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, m.bytes[frame + 0x20 ..][0..4], .little));
        try std.testing.expectEqual(@as(u32, 0), cpu.state.control & State.control_fpca);
        _ = cpu.run(.{ .instructions = 1 });
        try std.testing.expectEqual(@as(u32, 0), cpu.scb.get(scb_block.fpccr) & scb_block.lspact);
        try std.testing.expectEqual(@as(u32, 0xfeedface), cpu.state.fp[0]);
        try std.testing.expectEqual(State.control_fpca, cpu.state.control & State.control_fpca);
    }
}

fn protect(cpu: *Cpu, base: u32, limit: u32, attributes: u32, control: u32) void {
    _ = cpu.poke(4, 0xe000_ed98, 0);
    _ = cpu.poke(4, 0xe000_ed9c, base | attributes);
    _ = cpu.poke(4, 0xe000_eda0, limit | 1);
    _ = cpu.poke(4, 0xe000_ed94, control | 1);
}

test "a store outside every PMSAv8 region raises MemManage, and MMFAR names the address, B10.1 D1.2.166" {
    var m = storeAndLoad(0x800);
    var cpu = fast(.m33, &m);
    cpu.reset();
    protect(&cpu, 0, 0x7e0, 0, 0);
    try std.testing.expectEqual(@as(?arm.Stop, .data_violation), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(?u32, 0x0000_0082), cpu.peek(4, 0xe000_ed28));
    try std.testing.expectEqual(@as(?u32, 0x0000_0800), cpu.peek(4, 0xe000_ed34));
}

test "a debugger read the protection unit refuses is not counted against the next fault the core takes" {
    var m = loaded();
    std.mem.writeInt(u16, m.bytes[8..10], 0xde00, .little);
    var cpu = fast(.m33, &m);
    cpu.reset();
    protect(&cpu, 0, 0x7e0, 0, 0);
    try std.testing.expectEqual(@as(?u32, null), cpu.peek(4, 0x800));
    try std.testing.expectEqual(@as(?arm.Stop, .undefined_instruction), cpu.run(.{ .instructions = 4 }).stop);
}

test "PRIVDEFENA leaves the rest of the map open to privileged code, D1.2.168" {
    var m = storeAndLoad(0x800);
    var cpu = fast(.m33, &m);
    cpu.reset();
    protect(&cpu, 0, 0x7e0, 0, mpu_block.privdefena);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(?u32, 5), m.peek(4, 0x800));
}

test "the unit stands aside while the execution priority is negative, which FAULTMASK, NMI and HardFault are the only ways to reach, D1.2.168" {
    for ([_]u3{ 0, 1, 2, 3 }) |which| {
        var m = storeAndLoad(0x800);
        var cpu = fast(.m33, &m);
        cpu.reset();
        protect(&cpu, 0, 0x7e0, 0, 0);
        switch (which) {
            0 => cpu.state.faultmask = true,
            1 => {
                _ = cpu.poke(4, 0xe000_ed0c, scb_block.vectkey << 16 | scb_block.bfhfnmins);
                cpu.banked.faultmask = true;
            },
            2 => cpu.active |= 1 << 2,
            else => cpu.active |= arm.one(arm.ns_base + 3),
        }
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
        try std.testing.expectEqual(@as(?u32, 5), m.peek(4, 0x800));
    }
}

test "HFNMIENA keeps the unit on where the execution priority is negative, D1.2.168" {
    var m = storeAndLoad(0x800);
    var cpu = fast(.m33, &m);
    cpu.reset();
    protect(&cpu, 0, 0x7e0, 0, mpu_block.hfnmiena);
    cpu.state.faultmask = true;
    try std.testing.expectEqual(@as(?arm.Stop, .data_violation), cpu.run(.{ .instructions = 20 }).stop);
}

test "a raised BASEPRI or PRIMASK is not a negative execution priority, so the unit stays on, B3.13 D1.2.168" {
    for ([_]u2{ 0, 1, 2 }) |which| {
        var m = storeAndLoad(0x800);
        var cpu = fast(.m33, &m);
        cpu.reset();
        protect(&cpu, 0, 0x7e0, 0, 0);
        switch (which) {
            0 => cpu.state.primask = true,
            1 => cpu.state.basepri = 1,
            else => cpu.active |= 1 << 11,
        }
        try std.testing.expectEqual(@as(?arm.Stop, .data_violation), cpu.run(.{ .instructions = 20 }).stop);
    }
}

test "CCR.BFHFNMIGN lets a handler at a negative priority read an address nothing answers, and records the BusFault anyway, B3.2.8" {
    for ([_]u32{ 0, scb_block.bfhfnmign }) |ccr| {
        var m = placed(&svc_vectors, &.{0x40}, &.{&.{ 0xb671, 0x4a03, 0x6813, 0x2415, 0xbe00, 0x0000, 0x0000, 0x0000, 0x0000, 0x7000 }});
        var cpu = fast(.m4, &m);
        cpu.reset();
        try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed14, scb_block.stkalign | ccr));
        const stop = cpu.run(.{ .instructions = 20 }).stop;
        if (ccr == 0) {
            try std.testing.expectEqual(@as(?arm.Stop, .data_fault), stop);
            continue;
        }
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), stop);
        try std.testing.expectEqual(@as(u32, 0x15), cpu.state.r[4]);
        try std.testing.expectEqual(@as(u32, 0), cpu.state.r[3]);
        try std.testing.expectEqual(@as(?u32, 0x0000_8200), cpu.peek(4, 0xe000_ed28));
        try std.testing.expectEqual(@as(u32, 0x7000_0000), cpu.state.r[2]);
        try std.testing.expectEqual(@as(?u32, 0x7000_0000), cpu.peek(4, 0xe000_ed38));
    }
}

test "SHCSR.MEMFAULTENA sends the violation to the MemManage handler rather than escalating it, D1.2.233" {
    var m = storeAndLoad(0x800);
    std.mem.writeInt(u32, m.bytes[0x10..0x14], 0x101, .little);
    std.mem.writeInt(u16, m.bytes[0x100..0x102], 0xbe00, .little);
    var cpu = fast(.m33, &m);
    cpu.reset();
    _ = cpu.poke(4, 0xe000_ed24, scb_block.memfaultena);
    protect(&cpu, 0, 0x7e0, 0, 0);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(u32, 4), cpu.state.xpsr & 0x1ff);
    try std.testing.expectEqual(@as(u32, 0x100), cpu.state.pc);
}

test "an execute-never region refuses the instruction fetch that lands in it, D1.2.171" {
    var m = storeAndLoad(0x800);
    var cpu = fast(.m33, &m);
    cpu.reset();
    protect(&cpu, 0, 0x7e0, 1, 0);
    try std.testing.expectEqual(@as(?arm.Stop, .fetch_violation), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(?u32, 0x0000_0001), cpu.peek(4, 0xe000_ed28));
}

test "an unprivileged store needs a region that opens itself to unprivileged code, D1.2.171" {
    var m = storeAndLoad(0x800);
    var cpu = fast(.m33, &m);
    cpu.reset();
    protect(&cpu, 0, 0xfe0, 0, 0);
    cpu.state.control |= State.control_npriv;
    try std.testing.expectEqual(@as(?arm.Stop, .fetch_violation), cpu.run(.{ .instructions = 20 }).stop);
}

test "TT reports the access the MPU gives the address, and TTT the access it gives unprivileged code, D1.2.269" {
    for ([_]struct { attributes: u32, privileged: u32, unprivileged: u32 }{
        .{ .attributes = 0, .privileged = 0x004c_0000, .unprivileged = 0x0040_0000 },
        .{ .attributes = mpu_block.unprivileged | mpu_block.read_only, .privileged = 0x0044_0000, .unprivileged = 0x0044_0000 },
    }) |case| {
        var m = placed(&.{ 0x1000, 0x41 }, &.{0x40}, &.{&.{ 0xe844, 0xf000, 0xe844, 0xf140, 0xbe00 }});
        var cpu = fast(.m33, &m);
        cpu.reset();
        protect(&cpu, 0x600, 0x7e0, case.attributes, mpu_block.privdefena);
        cpu.state.r[4] = 0x600;
        try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
        try std.testing.expectEqual(case.privileged, cpu.state.r[0]);
        try std.testing.expectEqual(case.unprivileged, cpu.state.r[1]);
    }
}

test "a vector fetch reads the default memory map, not the regions the MPU describes, B10.1" {
    var m = storeAndLoad(0x800);
    std.mem.writeInt(u32, m.bytes[0x10..0x14], 0x101, .little);
    std.mem.writeInt(u16, m.bytes[0x100..0x102], 0xbe00, .little);
    var cpu = fast(.m33, &m);
    cpu.reset();
    _ = cpu.poke(4, 0xe000_ed24, scb_block.memfaultena);
    protect(&cpu, 0x20, 0x7e0, 0, 0);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(u32, 4), cpu.state.xpsr & 0x1ff);
}

test "a PMSAv7 unit refuses a store past its region and raises MemManage on the M4, B3.5.3" {
    var m = storeAndLoad(0x800);
    std.mem.writeInt(u32, m.bytes[0x10..0x14], 0x101, .little);
    std.mem.writeInt(u16, m.bytes[0x100..0x102], 0xbe00, .little);
    var cpu = fast(.m4, &m);
    cpu.reset();
    _ = cpu.poke(4, 0xe000_ed24, scb_block.memfaultena);
    _ = cpu.poke(4, 0xe000_ed98, 0);
    _ = cpu.poke(4, 0xe000_ed9c, 0);
    _ = cpu.poke(4, 0xe000_eda0, (3 << mpu_block.ap_shift) | (10 << mpu_block.size_shift) | 1);
    _ = cpu.poke(4, 0xe000_ed94, 1);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(u32, 4), cpu.state.xpsr & 0x1ff);
    try std.testing.expectEqual(@as(?u32, 0x0000_0082), cpu.peek(4, 0xe000_ed28));
    try std.testing.expectEqual(@as(?u32, 0x0000_0800), cpu.peek(4, 0xe000_ed34));
}

test "a PMSAv6 violation on a core without the Main Extension is a HardFault, since there is no MemManage to take it, B3.5" {
    var m = storeAndLoad(0x800);
    var cpu = fast(.m0plus, &m);
    cpu.reset();
    _ = cpu.poke(4, 0xe000_ed98, 0);
    _ = cpu.poke(4, 0xe000_ed9c, 0);
    _ = cpu.poke(4, 0xe000_eda0, (3 << mpu_block.ap_shift) | (10 << mpu_block.size_shift) | 1);
    _ = cpu.poke(4, 0xe000_ed94, 1);
    try std.testing.expectEqual(@as(?arm.Stop, .data_violation), cpu.run(.{ .instructions = 20 }).stop);
}

fn tSuffixed(code: u32) Memory {
    var m: Memory = .{};
    std.mem.writeInt(u32, m.bytes[0..4], 0x800, .little);
    std.mem.writeInt(u32, m.bytes[4..8], 0x41, .little);
    std.mem.writeInt(u16, m.bytes[0x40..0x42], 0x2005, .little);
    std.mem.writeInt(u16, m.bytes[0x42..0x44], 0x4902, .little);
    std.mem.writeInt(u16, m.bytes[0x44..0x46], @intCast(code >> 16), .little);
    std.mem.writeInt(u16, m.bytes[0x46..0x48], @truncate(code), .little);
    std.mem.writeInt(u16, m.bytes[0x48..0x4a], 0xbe00, .little);
    std.mem.writeInt(u32, m.bytes[0x4c..0x50], 0x400, .little);
    return m;
}

test "a T-suffixed store is refused where the plain one is allowed, because it asks as unprivileged, C2.4.236" {
    for ([_]struct { code: u32, stop: arm.Stop }{
        .{ .code = 0xf8c1_0000, .stop = .breakpoint },
        .{ .code = 0xf841_0e00, .stop = .data_violation },
    }) |case| {
        var m = tSuffixed(case.code);
        var cpu = fast(.m33, &m);
        cpu.reset();
        protect(&cpu, 0, 0x7e0, 0, 0);
        try std.testing.expectEqual(@as(?arm.Stop, case.stop), cpu.run(.{ .instructions = 20 }).stop);
    }
}

test "a T-suffixed load reaches a region unprivileged code may read, C2.4.102" {
    for ([_]struct { attributes: u32, stop: arm.Stop }{
        .{ .attributes = mpu_block.unprivileged, .stop = .breakpoint },
        .{ .attributes = 0, .stop = .data_violation },
    }) |case| {
        var m = tSuffixed(0xf851_0e00);
        var cpu = fast(.m33, &m);
        cpu.reset();
        protect(&cpu, 0, 0x7e0, case.attributes, 0);
        try std.testing.expectEqual(@as(?arm.Stop, case.stop), cpu.run(.{ .instructions = 20 }).stop);
    }
}

test "SHCSR reports MemManage as active while its handler runs, D1.2.233" {
    var m = storeAndLoad(0x800);
    std.mem.writeInt(u32, m.bytes[0x10..0x14], 0x101, .little);
    std.mem.writeInt(u16, m.bytes[0x100..0x102], 0xbe00, .little);
    var cpu = fast(.m33, &m);
    cpu.reset();
    _ = cpu.poke(4, 0xe000_ed24, scb_block.memfaultena);
    protect(&cpu, 0, 0x7e0, 0, 0);
    try std.testing.expectEqual(@as(?u32, scb_block.memfaultena), cpu.peek(4, 0xe000_ed24));
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 20 }).stop);
    try std.testing.expectEqual(@as(?u32, scb_block.memfaultena | 1), cpu.peek(4, 0xe000_ed24));
}

test "FPCCR.MMRDY says whether a MemManage could be taken for the deferred state, D1.2.100" {
    var m = deferring();
    var cpu = fast(.m33, &m);
    cpu.reset();
    _ = cpu.scb.writeRegister(scb_block.cpacr, scb_block.cp10);
    _ = cpu.poke(4, 0xe000_ed24, scb_block.memfaultena);
    cpu.state.control |= State.control_sfpa;
    cpu.state.r[1] = 0x200;
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(scb_block.mmrdy, cpu.scb.get(scb_block.fpccr) & scb_block.mmrdy);
    var without = deferring();
    var bare = fast(.m33, &without);
    bare.reset();
    _ = bare.scb.writeRegister(scb_block.cpacr, scb_block.cp10);
    bare.state.control |= State.control_sfpa;
    bare.state.r[1] = 0x200;
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), bare.run(.{ .instructions = 100 }).stop);
    try std.testing.expectEqual(@as(u32, 0), bare.scb.get(scb_block.fpccr) & scb_block.mmrdy);
}

test "SHCSR keeps the active and pending state of the system exceptions and takes a write to either, D1.2.233" {
    var m: Memory = .{};
    var cpu = fast(.m4, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed24, 0xff8b));
    try std.testing.expectEqual(@as(u64, 0xc870), cpu.active);
    try std.testing.expectEqual(@as(u64, 0x0870), cpu.pending);
    try std.testing.expectEqual(@as(?u32, 0xfd8b), cpu.peek(4, 0xe000_ed24));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed24, 0));
    try std.testing.expectEqual(@as(u64, 0), cpu.active | cpu.pending);
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ed24));
    cpu.active = 1 << 11;
    cpu.pending = 1 << 5;
    try std.testing.expectEqual(@as(?u32, (1 << 7) | (1 << 14)), cpu.peek(4, 0xe000_ed24));
}

test "the Non-secure alias of SHCSR reaches the Non-secure instances and the Secure fault bits are not in it, D1.2.233" {
    var m: Memory = .{};
    var cpu = fast(.m33, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed24, (1 << 4) | (1 << 0)));
    try std.testing.expectEqual(@as(u64, (1 << 7) | (1 << 4)), cpu.active);
    try std.testing.expectEqual(@as(?u32, (1 << 4) | (1 << 0)), cpu.peek(4, 0xe000_ed24));
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe002_ed24));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe002_ed24, (1 << 4) | (1 << 0)));
    try std.testing.expectEqual((1 << 7) | (1 << 4) | arm.one(arm.ns_base + 4), cpu.active);
    try std.testing.expectEqual(@as(?u32, 1), cpu.peek(4, 0xe002_ed24));
    cpu.active |= @as(u64, 1) << 3;
    try std.testing.expectEqual(@as(?u32, (1 << 4) | (1 << 2) | (1 << 0)), cpu.peek(4, 0xe000_ed24));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe002_ed24, 0));
    try std.testing.expectEqual(@as(u64, (1 << 7) | (1 << 4) | (1 << 3)), cpu.active);
}

test "the M33 banks CTR, Secure software reading zero through CTR and CTR_NS and Non-secure software through CTR, v8-M D1.2.18, M33 TRM Table 3-1" {
    var m = loaded();
    var cpu = fast(.m33, &m);
    cpu.reset();
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ed7c));
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe002_ed7c));
    cpu.state.secure = false;
    cpu.reguard();
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe000_ed7c));
}

test "the Non-secure alias is RES0 to Non-secure software, reading zero and ignoring writes, and faults unprivileged, v8-M D1.2.9 D1.2.272 B8.2" {
    var m = loaded();
    var cpu = fast(.m33, &m);
    cpu.reset();
    cpu.state.secure = false;
    cpu.reguard();
    const vtor = cpu.peek(4, 0xe000_ed08);
    try std.testing.expectEqual(@as(?u32, 0x0000_0201), cpu.peek(4, 0xe000_ed14));
    try std.testing.expectEqual(@as(?u32, 0), cpu.peek(4, 0xe002_ed14));
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe002_ed08, 0x400));
    try std.testing.expectEqual(vtor, cpu.peek(4, 0xe000_ed08));
    cpu.state.control |= State.control_npriv;
    try std.testing.expectEqual(@as(?u32, null), cpu.peek(4, 0xe002_ed14));
    try std.testing.expectEqual(@as(?void, null), cpu.poke(4, 0xe002_ed08, 0x400));
}

test "a HardFault software pends waits for a priority that lets it in where one the core forces locks the core up, B3.33" {
    var m = placed(&svc_vectors, &.{0x40}, &.{&.{ 0xbf00, 0xbe00 }});
    var cpu = fast(.m33, &m);
    cpu.reset();
    cpu.state.faultmask = true;
    try std.testing.expectEqual(@as(?void, {}), cpu.poke(4, 0xe000_ed24, 1 << 21));
    try std.testing.expectEqual(@as(u64, 1 << 3), cpu.pending);
    try std.testing.expectEqual(@as(?arm.Stop, .breakpoint), cpu.run(.{ .instructions = 10 }).stop);
    try std.testing.expect(!cpu.state.lockup);
    try std.testing.expectEqual(@as(u64, 1 << 3), cpu.pending);
}
