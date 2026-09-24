//! The ELF loader. It reads a 32-bit little-endian Arm or RISC-V executable and places every
//! PT_LOAD segment into whatever memory covers its physical address, zeroing the part of each
//! segment the file does not carry. It works over any type with place, so the bus it fills is
//! the caller's; Regions is the one the library ships.
const std = @import("std");

/// Why a load failed: not an ELF, not this kind of executable, malformed, or unplaceable.
pub const Failure = error{ NotElf, NotFirmware, Malformed, NoMemory };

/// Places every PT_LOAD segment at its physical address and zero-fills the rest of each.
pub fn load(image: []const u8, memory: anytype) Failure!void {
    var reader: std.Io.Reader = .fixed(image);
    const header = std.elf.Header.read(&reader) catch return error.NotElf;
    if (header.is_64 or header.endian != .little or header.type != .EXEC) return error.NotFirmware;
    if (header.machine != .ARM and header.machine != .RISCV) return error.NotFirmware;
    if (header.phnum == 0) return error.Malformed;
    if (header.phoff + @as(u64, header.phnum) * @sizeOf(std.elf.Elf32_Phdr) > image.len) return error.Malformed;
    var headers = header.iterateProgramHeadersBuffer(image);
    while (headers.next() catch return error.Malformed) |p| {
        if (p.p_type != std.elf.PT_LOAD or p.p_memsz == 0) continue;
        if (p.p_filesz > p.p_memsz or p.p_offset + p.p_filesz > image.len) return error.Malformed;
        if (p.p_paddr + p.p_memsz > 1 << 32) return error.Malformed;
        const bytes = image[@intCast(p.p_offset)..][0..@intCast(p.p_filesz)];
        if (!memory.place(@intCast(p.p_paddr), bytes, @intCast(p.p_memsz))) return error.NoMemory;
    }
}

/// The sentence a failure is reported to a user as.
pub fn message(failure: Failure) []const u8 {
    return switch (failure) {
        error.NotElf => "not an ELF image",
        error.NotFirmware => "not a 32-bit little-endian ARM or RISC-V executable",
        error.Malformed => "the ELF headers are malformed",
        error.NoMemory => "no memory holds a segment of the ELF",
    };
}
