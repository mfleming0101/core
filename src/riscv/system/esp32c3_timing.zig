pub fn extraOf(code: u32, x: *const [32]u32) u32 {
    return fixedOf(code) orelse latencyOf(code, x) - 1;
}

pub fn fixedOf(code: u32) ?u32 {
    if (code & 0x7f == 0x0f) return 3;
    if (!multiplies(code)) return 0;
    return switch (code >> 12 & 7) {
        0 => 0,
        1, 2, 3 => 4,
        else => null,
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

fn mask(flags: u32, comptime at: u5) u32 {
    return 0 -% (flags >> at & 1);
}

const wides = blk: {
    var table: [32]u8 = @splat(0);
    for (.{ 0x03, 0x13, 0x67 }) |op| table[op >> 2] = 0b101;
    for (.{ 0x23, 0x63 }) |op| table[op >> 2] = 0b011;
    table[0x33 >> 2] = 0b111;
    for (.{ 0x37, 0x17, 0x6f }) |op| table[op >> 2] = 0b100;
    table[0x73 >> 2] = 0b1100;
    break :blk table;
};

fn wide(code: u32) Registers {
    const flags: u32 = wides[code >> 2 & 31];
    const first = flags | (flags >> 3 & ~code >> 14);
    return .{ .reads = (mask(first, 0) & bit(code >> 15)) | (mask(flags, 1) & bit(code >> 20)), .writes = mask(flags, 2) & bit(code >> 7) };
}

const sp_read = 0;
const low_read = 1;
const low2_read = 2;
const full_read = 3;
const full2_read = 4;
const low_write = 5;
const low2_write = 6;
const full_write = 7;
const ra_write = 8;
const upper = 9;
const arithmetic = 10;
const register = 11;

const narrows = blk: {
    var table: [32]u16 = @splat(0);
    table[0b00_000] = 1 << sp_read | 1 << low2_write;
    table[0b00_010] = 1 << low_read | 1 << low2_write;
    table[0b00_110] = 1 << low_read | 1 << low2_read;
    table[0b01_000] = 1 << full_read | 1 << full_write;
    table[0b10_000] = 1 << full_read | 1 << full_write;
    table[0b01_001] = 1 << ra_write;
    table[0b01_010] = 1 << full_write;
    table[0b01_011] = 1 << upper | 1 << full_write;
    table[0b01_100] = 1 << low_read | 1 << arithmetic | 1 << low_write;
    table[0b01_110] = 1 << low_read;
    table[0b01_111] = 1 << low_read;
    table[0b10_010] = 1 << sp_read | 1 << full_write;
    table[0b10_100] = 1 << register;
    table[0b10_110] = 1 << sp_read | 1 << full2_read;
    break :blk table;
};

fn narrow(code: u16) Registers {
    const c: u32 = code;
    const flags: u32 = narrows[(c & 3) << 3 | c >> 13];
    const full = bit(c >> 7);
    const full2 = bit(c >> 2);
    const low = bit(8 + (c >> 7 & 7));
    const low2 = bit(8 + (c >> 2 & 7));
    const sp = bit(2);
    const linked = 0 -% (c >> 12 & 1);
    const paired = 0 -% @as(u32, @intFromBool(c >> 10 & 3 == 3));
    const moved = 0 -% @as(u32, @intFromBool(full2 != 0));
    const reads = (mask(flags, sp_read) & sp) | (mask(flags, low_read) & low) | (mask(flags, low2_read) & low2) | (mask(flags, full_read) & full) | (mask(flags, full2_read) & full2) |
        (mask(flags, upper) & full & sp) | (mask(flags, arithmetic) & paired & low2) | (mask(flags, register) & (full2 | ((~moved | linked) & full)));
    const writes = (mask(flags, low_write) & low) | (mask(flags, low2_write) & low2) | (mask(flags, full_write) & full) | (mask(flags, ra_write) & bit(1)) |
        (mask(flags, register) & ((moved & full) | (~moved & linked & bit(1))));
    return .{ .reads = reads, .writes = writes };
}
