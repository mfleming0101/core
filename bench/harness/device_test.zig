const std = @import("std");
const machine = @import("machine");
const device = @import("device.zig");

const ram: u32 = 0x0;
const ram_size: u32 = 0x1000;
const stack: u32 = 0x800;
const base: u32 = 0x1000;
const line: u16 = 7;
const handler: u32 = 0x60;
const entry: u32 = 0x80;
const budget: u64 = 256;

const image_bytes = entry + 32;
const ehdr_bytes = @sizeOf(std.elf.Elf32_Ehdr);
const phdr_bytes = @sizeOf(std.elf.Elf32_Phdr);
const elf_bytes = ehdr_bytes + phdr_bytes + image_bytes;

fn firmware(into: *[image_bytes]u8, reload: u16, ctrl: u16, clearing: bool) void {
    @memset(into, 0);
    std.mem.writeInt(u32, into[0..4], stack, .little);
    std.mem.writeInt(u32, into[4 * (16 + line) ..][0..4], handler | 1, .little);
    place(into, handler, &.{ 0x3401, 0x6945 });
    place(into, handler + 4, if (clearing) &.{ 0x2101, 0x60c1, 0x4770 } else &.{0x4770});
    place(into, entry, &.{ 0x2001, 0x0300, 0xf24e, 0x1200, 0xf2ce, 0x0200, 0x2180, 0x6011 });
    place(into, entry + 16, &.{ 0x2107, 0x6101, 0x2100 | reload, 0x6041 });
    place(into, entry + 24, &.{ 0x2400, 0x2100 | ctrl, 0x6001, 0xe7fe });
}

fn place(into: []u8, at: u32, code: []const u16) void {
    for (code, 0..) |half, i| std.mem.writeInt(u16, into[at + 2 * i ..][0..2], half, .little);
}

fn imageOf(into: *[elf_bytes]u8, reload: u16, ctrl: u16, clearing: bool) []const u8 {
    var ident: [std.elf.EI.NIDENT]u8 = @splat(0);
    @memcpy(ident[0..std.elf.MAGIC.len], std.elf.MAGIC);
    ident[std.elf.EI.CLASS] = std.elf.ELFCLASS32;
    ident[std.elf.EI.DATA] = std.elf.ELFDATA2LSB;
    ident[std.elf.EI.VERSION] = 1;
    into[0..ehdr_bytes].* = std.mem.toBytes(std.elf.Elf32_Ehdr{
        .e_ident = ident,
        .e_type = .EXEC,
        .e_machine = .ARM,
        .e_version = 1,
        .e_entry = entry | 1,
        .e_phoff = ehdr_bytes,
        .e_shoff = 0,
        .e_flags = 0,
        .e_ehsize = ehdr_bytes,
        .e_phentsize = phdr_bytes,
        .e_phnum = 1,
        .e_shentsize = 0,
        .e_shnum = 0,
        .e_shstrndx = 0,
    });
    into[ehdr_bytes..][0..phdr_bytes].* = std.mem.toBytes(std.elf.Elf32_Phdr{
        .p_type = std.elf.PT_LOAD,
        .p_offset = ehdr_bytes + phdr_bytes,
        .p_vaddr = ram,
        .p_paddr = ram,
        .p_filesz = image_bytes,
        .p_memsz = image_bytes,
        .p_flags = std.elf.PF_R | std.elf.PF_W | std.elf.PF_X,
        .p_align = 1,
    });
    firmware(into[ehdr_bytes + phdr_bytes ..][0..image_bytes], reload, ctrl, clearing);
    return into;
}

fn ran(reload: u16, ctrl: u16, clearing: bool) ![32]u32 {
    return (try watched(reload, ctrl, clearing, &.{})).regs;
}

fn watched(reload: u16, ctrl: u16, clearing: bool, records: []device.Event) !struct { regs: [32]u32, cycles: u64 } {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var bytes: [elf_bytes]u8 = undefined;
    try device.events.open(records);
    var m = try machine.arm.Machine.init(.{
        .arena = arena.allocator(),
        .map = .{
            .core = .m3,
            .regions = &.{.{ .base = ram, .size = ram_size, .writable = true }},
            .devices = &.{.{ .base = base, .size = 0x100, .model = "probe-timer" }},
        },
        .elf = imageOf(&bytes, reload, ctrl, clearing),
        .console = null,
        .registry = if (records.len == 0) device.registry else device.watching,
        .history = 0,
    });
    device.events.follow(m.clock());
    _ = m.run(budget);
    return .{ .regs = m.snapshot().regs, .cycles = m.clock().* };
}

test "the countdown's line reaches the machine as an interrupt" {
    const regs = try ran(4, 1, false);
    try std.testing.expectEqual(@as(u32, 1), regs[5]);
    try std.testing.expect(regs[4] >= 2);
}

test "a level the handler drops is not taken again" {
    const regs = try ran(4, 1, true);
    try std.testing.expectEqual(@as(u32, 1), regs[4]);
    try std.testing.expectEqual(@as(u32, 1), regs[5]);
}

test "an auto-reloading countdown fires once per interrupt" {
    const regs = try ran(64, 3, true);
    try std.testing.expect(regs[4] >= 2);
    try std.testing.expectEqual(regs[4], regs[5]);
}

test "the event ring holds every access and every raise, named, stamped on the machine's own clock" {
    var records: [64]device.Event = undefined;
    const out = try watched(4, 1, true, &records);
    try std.testing.expectEqual(@as(u32, 1), out.regs[4]);
    var reads: usize = 0;
    var writes: usize = 0;
    var raises: usize = 0;
    var back = device.events.count();
    var last: u64 = 0;
    while (back > 0) {
        back -= 1;
        const event = device.events.at(back).?;
        try std.testing.expect(event.at >= last);
        try std.testing.expect(event.at <= out.cycles);
        last = event.at;
        try std.testing.expectEqualStrings("probe-timer", device.events.nameOf(event.unit));
        switch (event.kind) {
            .read => reads += 1,
            .write => writes += 1,
            .raise => {
                raises += 1;
                try std.testing.expectEqual(@as(u32, line), event.value);
            },
        }
    }
    try std.testing.expectEqualStrings("status", device.events.registerOf(0, 0x0c).?);
    try std.testing.expectEqual(@as(usize, 1), reads);
    try std.testing.expectEqual(@as(usize, 4), writes);
    try std.testing.expectEqual(@as(usize, 1), raises);
    try device.events.open(&.{});
}
