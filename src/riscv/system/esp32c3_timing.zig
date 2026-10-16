pub fn extraOf(code: u32, x: *const [32]u32) u32 {
    if (!multiplies(code)) return 0;
    return switch (code >> 12 & 7) {
        0 => 0,
        1, 2, 3 => 4,
        else => latencyOf(code, x) - 1,
    };
}

pub fn shadowOf(code: u32, x: *const [32]u32) u32 {
    return if (multiplies(code) and code >> 14 & 1 == 1) latencyOf(code, x) - 1 else 0;
}

fn multiplies(code: u32) bool {
    return code & 0xfe00_007f == 0x0200_0033;
}

fn latencyOf(code: u32, x: *const [32]u32) u32 {
    const divisor = x[code >> 20 & 31];
    const negative = code >> 12 & 1 == 0 and @as(i32, @bitCast(divisor)) < 0;
    return 3 + @clz(if (negative) 0 -% divisor else divisor);
}

pub const Registers = struct { reads: u32, writes: u32 };

pub fn registersOf(code: u32) Registers {
    return if (code & 3 == 3) wide(code) else narrow(@truncate(code));
}

fn bit(r: u32) u32 {
    return @as(u32, 1) << @intCast(r & 31) & ~@as(u32, 1);
}

fn wide(code: u32) Registers {
    const rd = bit(code >> 7);
    const rs1 = bit(code >> 15);
    const rs2 = bit(code >> 20);
    return switch (code & 0x7f) {
        0x03, 0x13, 0x67 => .{ .reads = rs1, .writes = rd },
        0x23, 0x63 => .{ .reads = rs1 | rs2, .writes = 0 },
        0x33 => .{ .reads = rs1 | rs2, .writes = rd },
        0x37, 0x17, 0x6f => .{ .reads = 0, .writes = rd },
        0x73 => .{ .reads = if (code >> 14 & 1 == 0) rs1 else 0, .writes = rd },
        else => .{ .reads = 0, .writes = 0 },
    };
}

fn narrow(code: u16) Registers {
    const full = bit(code >> 7);
    const full2 = bit(code >> 2);
    const low = bit(8 + (code >> 7 & 7));
    const low2 = bit(8 + (code >> 2 & 7));
    const sp = bit(2);
    const linked = code >> 12 & 1 == 1;
    return switch ((code & 3) << 3 | code >> 13) {
        0b00_000 => .{ .reads = sp, .writes = low2 },
        0b00_010 => .{ .reads = low, .writes = low2 },
        0b00_110 => .{ .reads = low | low2, .writes = 0 },
        0b01_000, 0b10_000 => .{ .reads = full, .writes = full },
        0b01_001 => .{ .reads = 0, .writes = bit(1) },
        0b01_010 => .{ .reads = 0, .writes = full },
        0b01_011 => .{ .reads = full & sp, .writes = full },
        0b01_100 => .{ .reads = low | if (code >> 10 & 3 == 3) low2 else 0, .writes = low },
        0b01_110, 0b01_111 => .{ .reads = low, .writes = 0 },
        0b10_010 => .{ .reads = sp, .writes = full },
        0b10_100 => if (full2 == 0)
            .{ .reads = full, .writes = if (linked) bit(1) else 0 }
        else
            .{ .reads = full2 | if (linked) full else 0, .writes = full },
        0b10_110 => .{ .reads = sp | full2, .writes = 0 },
        else => .{ .reads = 0, .writes = 0 },
    };
}
