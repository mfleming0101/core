const Class = @import("isa").riscv.instruction.Class;

pub fn extraOf(code: u32, class: Class, branched: bool) u32 {
    return switch (class) {
        .branch => @as(u32, if (branched == backward(code)) 0 else 2),
        .jump => @intFromBool(indirect(code)),
        else => fixedOf(code),
    };
}

fn backward(code: u32) bool {
    return if (code & 3 == 3) code >> 31 != 0 else code >> 12 & 1 != 0;
}

fn indirect(code: u32) bool {
    return if (code & 3 == 3) code & 0x7f == 0x67 else code & 0xe07f == 0x8002;
}

fn fixedOf(code: u32) u32 {
    if (code & 0x7f == 0x0f) return 4;
    if (code & 0xfe00_007f != 0x0200_0033) return 0;
    return switch (code >> 12 & 7) {
        0 => 0,
        1, 2, 3 => 1,
        else => 9,
    };
}

pub fn multiplies(code: u32) bool {
    return code & 0xfe00_407f == 0x0200_0033;
}

pub fn baseOf(code: u32) u32 {
    if (code & 3 == 3) return if (code & 0x5f == 0x03) bit(code >> 15) else 0;
    return switch (code & 0xe003) {
        0x4000, 0xc000 => bit(8 + (code >> 7 & 7)),
        0x4002, 0xc002 => bit(2),
        else => 0,
    };
}

fn bit(r: u32) u32 {
    return @as(u32, 1) << @intCast(r & 31) & ~@as(u32, 1);
}
