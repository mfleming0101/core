//! The RISC-V Physical Memory Protection unit. Sixteen configuration bytes and sixteen
//! address registers, each entry off or naming a range as top-of-range, one word or a
//! naturally aligned power of two. The processor asks it once per access on the slow lane and
//! once per fold to bound the block a span may run over, and answers the pmpcfg and pmpaddr
//! CSRs from it. Whether the lowest match decides is a part property the Spec carries.
const contract = @import("../../contract.zig");
const csr = @import("isa").riscv.csr;

/// How many configuration and address pairs the unit has.
pub const entries: usize = 16;

/// How an entry names its range: disabled, top of range, one word, or naturally aligned.
pub const Mode = enum(u2) { off, tor, na4, napot };

/// One pmpcfg byte: the three permissions, the mode, and the lock that outlasts a write.
pub const Config = packed struct(u8) {
    r: bool = false,
    w: bool = false,
    x: bool = false,
    mode: Mode = .off,
    _5: u2 = 0,
    l: bool = false,
};

fn configOf(byte: u8) Config {
    var c: Config = @bitCast(byte);
    c._5 = 0;
    if (!c.r) c.w = false;
    return c;
}

/// The Physical Memory Protection unit: sixteen entries, and the part rule that ranks them.
pub const Pmp = struct {
    const Self = @This();

    cfg: [entries]Config = @splat(.{}),
    addr: [entries]u32 = @splat(0),

    static_priority: bool = false,

    /// Whether any locked entry is on, which is what can refuse a machine-mode access.
    pub fn restrictive(self: *const Self) bool {
        for (self.cfg) |c| {
            if (c.l and c.mode != .off) return true;
        }
        return false;
    }

    /// Whether an access is allowed; machine mode passes an unmatched address and an unlocked entry.
    pub fn permits(self: *const Self, address: u32, privilege: csr.Privilege, access: contract.Kind) bool {
        var matched = false;
        for (0..entries) |i| {
            if (!self.matches(i, address)) continue;
            matched = true;
            const c = self.cfg[i];
            const granted = (privilege == .machine and !c.l) or switch (access) {
                .fetch => c.x,
                .read, .vector => c.r,
                .write => c.w,
            };
            if (granted) return true;
            if (self.static_priority) return false;
        }
        return !matched and privilege == .machine;
    }

    fn matches(self: *const Self, i: usize, address: u32) bool {
        const at: u64 = address;
        return switch (self.cfg[i].mode) {
            .off => false,
            .tor => at >= bottom(self, i) and at < @as(u64, self.addr[i]) << 2,
            .na4 => at >> 2 == self.addr[i],
            .napot => blk: {
                const ones = @ctz(~self.addr[i]);
                const size = @as(u64, 1) << (@as(u6, ones) + 3);
                const base = (@as(u64, self.addr[i]) & ~((@as(u64, 1) << ones) - 1)) << 2;
                break :blk at >= base and at - base < size;
            },
        };
    }

    fn bottom(self: *const Self, i: usize) u64 {
        if (i == 0) return 0;
        return @as(u64, self.addr[i - 1]) << 2;
    }

    fn frozen(self: *const Self, i: usize) bool {
        if (self.cfg[i].l) return true;
        if (i + 1 >= entries) return false;
        return self.cfg[i + 1].l and self.cfg[i + 1].mode == .tor;
    }

    /// The word a pmpcfg or pmpaddr CSR read answers.
    pub fn read(self: *const Self, number: csr.Protection) u32 {
        const group = number.group() orelse return self.addr[number.entry()];
        var word: u32 = 0;
        for (0..4) |i| word |= @as(u32, @as(u8, @bitCast(self.cfg[4 * group + i]))) << @intCast(8 * i);
        return word;
    }

    /// Takes a pmpcfg or pmpaddr write, leaving locked entries and the entry below a locked TOR alone.
    pub fn write(self: *Self, number: csr.Protection, value: u32) void {
        const group = number.group() orelse {
            const i = number.entry();
            if (!self.frozen(i)) self.addr[i] = value;
            return;
        };
        for (0..4) |i| {
            const at = 4 * group + i;
            if (self.cfg[at].l) continue;
            self.cfg[at] = configOf(@truncate(value >> @intCast(8 * i)));
        }
    }
};
