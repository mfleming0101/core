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
