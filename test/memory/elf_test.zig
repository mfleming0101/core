const std = @import("std");
const elf = @import("../../src/memory/elf.zig");
const Regions = @import("../../src/memory/regions.zig").Regions;

fn segment(offset: u32, vaddr: u32, paddr: u32, filesz: u32, memsz: u32) std.elf.Elf32_Phdr {
    return .{ .p_type = std.elf.PT_LOAD, .p_offset = offset, .p_vaddr = vaddr, .p_paddr = paddr, .p_filesz = filesz, .p_memsz = memsz, .p_flags = 0, .p_align = 4 };
}

test "a segment's file bytes land at its physical address and the rest is zeroed at its virtual address, leaving flash beside it" {
    const headers = @sizeOf(std.elf.Elf32_Ehdr) + 2 * @sizeOf(std.elf.Elf32_Phdr);
    var image: [headers + 4]u8 = undefined;
    const header: std.elf.Elf32_Ehdr = .{
        .e_ident = .{ 0x7f, 'E', 'L', 'F', std.elf.ELFCLASS32, std.elf.ELFDATA2LSB, 1 } ++ @as([9]u8, @splat(0)),
        .e_type = .EXEC,
        .e_machine = .ARM,
        .e_version = 1,
        .e_entry = 0x0800_0000,
        .e_phoff = @sizeOf(std.elf.Elf32_Ehdr),
        .e_shoff = 0,
        .e_flags = 0,
        .e_ehsize = @sizeOf(std.elf.Elf32_Ehdr),
        .e_phentsize = @sizeOf(std.elf.Elf32_Phdr),
        .e_phnum = 2,
        .e_shentsize = 0,
        .e_shnum = 0,
        .e_shstrndx = 0,
    };
    const phdrs = [2]std.elf.Elf32_Phdr{ segment(headers, 0x2000_0000, 0x0800_0000, 2, 6), segment(headers + 2, 0x0000_0000, 0x0800_0002, 2, 2) };
    @memcpy(image[0..@sizeOf(std.elf.Elf32_Ehdr)], std.mem.asBytes(&header));
    @memcpy(image[@sizeOf(std.elf.Elf32_Ehdr)..headers], std.mem.sliceAsBytes(&phdrs));
    @memcpy(image[headers..], &[_]u8{ 1, 2, 3, 4 });
    var itcm: [4]u8 = @splat(0xff);
    var flash: [8]u8 = @splat(0xff);
    var ram: [8]u8 = @splat(0xff);
    var entries = [_]Regions.Entry{
        .{ .memory = .{ .base = 0, .bytes = &itcm, .writable = true } },
        .{ .memory = .{ .base = 0x0800_0000, .bytes = &flash, .writable = false } },
        .{ .memory = .{ .base = 0x2000_0000, .bytes = &ram, .writable = true } },
    };
    var r = try Regions.adopt(&entries);
    try elf.load(&image, &r);
    try std.testing.expectEqual([_]u8{ 1, 2, 3, 4, 0xff, 0xff, 0xff, 0xff }, flash);
    try std.testing.expectEqual([_]u8{ 0xff, 0xff, 0, 0, 0, 0, 0xff, 0xff }, ram);
    try std.testing.expectEqual([_]u8{0xff} ** 4, itcm);
}
