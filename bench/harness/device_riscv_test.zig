const std = @import("std");
const machine = @import("machine");
const device = @import("device.zig");

const ram: u32 = 0x0;
const ram_size: u32 = 0x1000;
const base: u32 = 0x1000;
const id: u32 = 7;
const vectors: u32 = 0x100;
const entry: u32 = 0x0;
const handler: u32 = 0x180;
const budget: u64 = 256;

const image_bytes = handler + 20;
const ehdr_bytes = @sizeOf(std.elf.Elf32_Ehdr);
const phdr_bytes = @sizeOf(std.elf.Elf32_Phdr);
const elf_bytes = ehdr_bytes + phdr_bytes + image_bytes;

fn firmware(into: *[image_bytes]u8, reload: u12, ctrl: u12, clearing: bool) void {
    @memset(into, 0);
    place(into, entry, &.{
        0x10000293,
        0x30529073,
        0x00001537,
        0x00700313,
        0x00652823,
        0x600c23b7,
        0x0063ae23,
        0x00100e13,
        0x13c3a823,
        0x08000e93,
        0x11d3a223,
        0x00000413,
        0x00000313 | @as(u32, reload) << 20,
        0x00652223,
        0x30046073,
        0x00000313 | @as(u32, ctrl) << 20,
        0x00652023,
        0x0000006f,
    });
    place(into, vectors + 4 * id, &.{0x0640006f});
    place(into, handler, &.{ 0x00140413, 0x01452483 });
    place(into, handler + 8, if (clearing) &.{ 0x00100313, 0x00652623, 0x30200073 } else &.{0x30200073});
}

fn place(into: []u8, at: u32, code: []const u32) void {
    for (code, 0..) |word, i| std.mem.writeInt(u32, into[at + 4 * i ..][0..4], word, .little);
}

fn imageOf(into: *[elf_bytes]u8, reload: u12, ctrl: u12, clearing: bool) []const u8 {
    var ident: [std.elf.EI.NIDENT]u8 = @splat(0);
    @memcpy(ident[0..std.elf.MAGIC.len], std.elf.MAGIC);
    ident[std.elf.EI.CLASS] = std.elf.ELFCLASS32;
    ident[std.elf.EI.DATA] = std.elf.ELFDATA2LSB;
    ident[std.elf.EI.VERSION] = 1;
    into[0..ehdr_bytes].* = std.mem.toBytes(std.elf.Elf32_Ehdr{
        .e_ident = ident,
        .e_type = .EXEC,
        .e_machine = .RISCV,
        .e_version = 1,
        .e_entry = entry,
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

fn ran(reload: u12, ctrl: u12, clearing: bool) ![32]u32 {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var bytes: [elf_bytes]u8 = undefined;
    var m = try machine.riscv.Machine.init(.{
        .arena = arena.allocator(),
        .map = .{
            .core = .esp32c3,
            .regions = &.{.{ .base = ram, .size = ram_size, .writable = true }},
            .devices = &.{.{ .base = base, .size = 0x100, .model = "probe-timer" }},
        },
        .elf = imageOf(&bytes, reload, ctrl, clearing),
        .console = null,
        .registry = device.registry,
        .history = 0,
    });
    _ = m.run(budget);
    return m.snapshot().regs;
}

test "the countdown's source reaches the hart as an interrupt" {
    const regs = try ran(4, 1, false);
    try std.testing.expectEqual(@as(u32, 1), regs[9]);
    try std.testing.expect(regs[8] >= 2);
}

test "a level the handler drops is not taken again by the hart" {
    const regs = try ran(4, 1, true);
    try std.testing.expectEqual(@as(u32, 1), regs[8]);
    try std.testing.expectEqual(@as(u32, 1), regs[9]);
}

test "an auto-reloading countdown fires once per interrupt the hart takes" {
    const regs = try ran(64, 3, true);
    try std.testing.expect(regs[8] >= 2);
    try std.testing.expectEqual(regs[8], regs[9]);
}
