//! The Data Watchpoint and Trace block, of which the library models the cycle counter alone.
//! CYCCNT is not stored and advanced: the block keeps an origin and a held value, and derives
//! the count from the processor's own cycle count when it is read. So the counter costs
//! nothing between reads, and enabling or disabling it only moves the origin.
/// Where the DWT registers begin.
pub const base: u32 = 0xe000_1000;
/// How wide the DWT window is.
pub const size: u32 = 0x1000;

/// DWT_CTRL, at an offset from the base.
pub const ctrl: u32 = 0x000;
/// DWT_CYCCNT, at an offset from the base.
pub const cyccnt: u32 = 0x004;

/// The DWT_CTRL bit that runs the cycle counter.
pub const cyccntena: u32 = 1 << 0;
const notrcpkt: u32 = 1 << 27;
const noexttrig: u32 = 1 << 26;
const noprfcnt: u32 = 1 << 24;
const present: u32 = notrcpkt | noexttrig | noprfcnt;

/// The cycle counter: not a register that ticks, but an origin the processor's count is read against.
pub const Dwt = struct {
    const Self = @This();

    counts: bool,
    control: u32,
    held: u32 = 0,
    origin: u64 = 0,
    running: bool = false,

    /// A DWT for a core that has one, or a block that reads zero everywhere.
    pub fn init(counts: bool) Self {
        return .{ .counts = counts, .control = if (counts) present else 0 };
    }

    /// The word a register read answers, CYCCNT derived from the processor's cycle count.
    pub fn readRegister(self: *const Self, offset: u32, cycles: u64) ?u32 {
        if (offset >= size or offset & 3 != 0) return null;
        if (!self.counts) return 0;
        return switch (offset) {
            ctrl => self.control,
            cyccnt => self.count(cycles),
            else => 0,
        };
    }

    /// Takes a register write; a CYCCNT write moves the origin rather than a counter.
    pub fn writeRegister(self: *Self, offset: u32, value: u32, cycles: u64) bool {
        if (offset >= size or offset & 3 != 0) return false;
        if (!self.counts) return true;
        switch (offset) {
            ctrl => self.control = present | (value & cyccntena),
            cyccnt => {
                self.held = value;
                self.origin = cycles;
            },
            else => {},
        }
        return true;
    }

    /// Starts or stops the counter, holding the count it had reached, when the enables change.
    pub fn retime(self: *Self, cycles: u64, traced: bool) void {
        if (!self.counts) return;
        const running = traced and self.control & cyccntena != 0;
        if (running == self.running) return;
        if (running) self.origin = cycles else self.held = self.count(cycles);
        self.running = running;
    }

    fn count(self: *const Self, cycles: u64) u32 {
        return if (self.running) self.held +% @as(u32, @truncate(cycles -% self.origin)) else self.held;
    }
};
