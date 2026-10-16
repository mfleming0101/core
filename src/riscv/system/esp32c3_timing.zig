pub fn extraOf(code: u32, x: *const [32]u32) u32 {
    if (code & 0xfe00_007f != 0x0200_0033) return 0;
    return switch (code >> 12 & 7) {
        0 => 0,
        1, 2, 3 => 4,
        else => latencyOf(code, x) - 1,
    };
}

fn latencyOf(code: u32, x: *const [32]u32) u32 {
    const divisor = x[code >> 20 & 31];
    const negative = code >> 12 & 1 == 0 and @as(i32, @bitCast(divisor)) < 0;
    return 3 + @clz(if (negative) 0 -% divisor else divisor);
}
