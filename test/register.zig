pub const Register = struct {
    name: []const u8,
    offset: u32,
    reset: u32,
    write_mask: u32,
};

pub const Mismatch = struct {
    name: []const u8,
    kind: enum { reset, write_mask },
    value: u32,
};

pub fn check(block: anytype, table: []const Register) ?Mismatch {
    for (table) |r| {
        block.reset();
        const at_reset = block.readRegister(r.offset) orelse return .{ .name = r.name, .kind = .reset, .value = 0 };
        if (at_reset != r.reset) return .{ .name = r.name, .kind = .reset, .value = at_reset };
        _ = block.writeRegister(r.offset, 0xffff_ffff);
        const after_write = block.readRegister(r.offset) orelse return .{ .name = r.name, .kind = .write_mask, .value = 0 };
        if (after_write & ~(r.write_mask | r.reset) != 0) return .{ .name = r.name, .kind = .write_mask, .value = after_write };
    }
    return null;
}
