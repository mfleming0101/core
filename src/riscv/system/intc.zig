//! The Espressif block in front of the hart: a table routing each peripheral source to one of
//! thirty-two CPU interrupts, with the enable, type, clear, status, priority and threshold
//! registers beside it, and on the C6 the software registers a program raises its own source
//! through. It keeps an edge latch and a level word and ranks the unmasked ids by priority, so
//! the processor asks it once for whichever interrupt to take. The Layout is the part's
//! addresses; the registers themselves are the same on both.
const regions = @import("../../memory/regions.zig");

/// The most peripheral interrupt sources either part has, which is the C6's, C6 TRM 10.3.
pub const sources = 77;

/// How many CPU interrupts a source can be routed to.
pub const ids = 32;

/// How wide each of the two register windows is.
pub const size: u32 = 0x1000;

/// Where one part puts its matrix and controller registers, and which ids it can raise.
pub const Layout = struct {
    sources: u8,
    matrix_base: u32,
    control_base: u32,
    enable: u32,
    kinds: u32,
    clear: u32,
    status: u32,
    priority: u32,
    priority_first: u8,
    threshold: u32,
    threshold_mask: u32,
    external: u32,
    software: u32,
    software_count: u8,
    software_source: u8,

    zero_masks: bool,
};

/// The C3: 62 sources, one window holding both register groups, priority zero masks, C3 TRM 8.4.
pub const esp32c3: Layout = .{
    .sources = 62,
    .matrix_base = 0x600c_2000,
    .control_base = 0x600c_2000,
    .enable = 0x0104,
    .kinds = 0x0108,
    .clear = 0x010c,
    .status = 0x0110,
    .priority = 0x0118,
    .priority_first = 1,
    .threshold = 0x0194,
    .threshold_mask = 0xf,
    .external = ~@as(u32, 1),
    .software = 0,
    .software_count = 0,
    .software_source = 0,
    .zero_masks = true,
};

/// The C6: 77 sources, matrix and priority windows apart, ids 1, 2, 5, 6 and 8 up, C6 TRM 10.3.3.
pub const esp32c6: Layout = .{
    .sources = 77,
    .matrix_base = 0x6001_0000,
    .control_base = 0x600c_5000,
    .enable = 0x0000,
    .kinds = 0x0004,
    .clear = 0x00a8,
    .status = 0x0008,
    .priority = 0x000c,
    .priority_first = 0,
    .threshold = 0x008c,
    .threshold_mask = 0xff,
    .external = ~@as(u32, 1 << 0 | 1 << 3 | 1 << 4 | 1 << 7),
    .software = 0x0090,
    .software_count = 4,
    .software_source = 22,
    .zero_masks = false,
};

/// Whether an address falls in one of the two register windows or in ordinary memory.
pub const Region = enum { memory, interrupt };

/// The interrupt matrix and controller: the routing table, the registers and the two latches.
pub const Intc = struct {
    const Self = @This();

    layout: Layout = esp32c3,

    map: [sources]u5 = @splat(0),

    enabled: u32 = 0,
    kinds: u32 = 0,
    cleared: u32 = 0,
    priorities: [ids]u4 = @splat(0),
    threshold: u8 = 0,

    software: u4 = 0,

    latched: u32 = 0,
    levels: u32 = 0,

    /// Returns every register to its reset value, keeping the layout of the part.
    pub fn reset(self: *Self) void {
        self.* = .{ .layout = self.layout };
    }

    /// Which window an address falls in, which decides whether a block may be folded over it.
    pub fn region(self: *const Self, address: u32) Region {
        if (address -% self.layout.matrix_base < size) return .interrupt;
        if (address -% self.layout.control_base < size) return .interrupt;
        return .memory;
    }

    fn mapped(self: *const Self, address: u32) ?usize {
        const offset = address -% self.layout.matrix_base;
        if (offset >= 4 * @as(u32, self.layout.sources)) return null;
        return offset / 4;
    }

    fn prioritised(self: *const Self, address: u32) ?usize {
        const offset = address -% self.layout.control_base -% self.layout.priority;
        if (offset >= 4 * (ids - @as(u32, self.layout.priority_first))) return null;
        return offset / 4 + self.layout.priority_first;
    }

    fn softwareAt(self: *const Self, address: u32) ?u2 {
        if (self.layout.software_count == 0) return null;
        const offset = address -% self.layout.control_base -% self.layout.software;
        if (offset >= 4 * @as(u32, self.layout.software_count)) return null;
        return @intCast(offset / 4);
    }

    fn asserting(self: *const Self) regions.Lines {
        var out: regions.Lines = 0;
        for (0..self.layout.software_count) |i| {
            if (self.software & bitOf(@intCast(i)) != 0) out |= line(self.layout.software_source + i);
        }
        return out;
    }

    fn bitOf(i: u2) u4 {
        return @as(u4, 1) << i;
    }

    fn line(source: usize) regions.Lines {
        return @as(regions.Lines, 1) << @intCast(source);
    }

    /// The CPU interrupt a source's map register sends it to, or null where it holds zero.
    pub fn routed(self: *const Self, source: regions.Line) ?u5 {
        if (source >= self.layout.sources) return null;
        const id = self.map[source];
        return if (id == 0) null else id;
    }

    fn route(self: *const Self, lines: regions.Lines) u32 {
        var out: u32 = 0;
        var rest = lines;
        while (rest != 0) {
            const source = @ctz(rest);
            rest &= rest - 1;
            if (source >= self.layout.sources) break;
            if (self.routed(source)) |id| out |= @as(u32, 1) << id;
        }
        return out;
    }

    /// Routes lines to their ids and latches them, for edge and level alike.
    pub fn raise(self: *Self, lines: regions.Lines) void {
        const arriving = self.route(lines);
        self.latched |= arriving;
        self.levels |= arriving;
    }

    /// Replaces the level state with the lines devices hold high right now.
    pub fn hold(self: *Self, lines: regions.Lines) void {
        self.levels = self.route(lines);
    }

    /// The ids asking for attention: the latch where an id is edge-typed, the level where it is not.
    pub fn pending(self: *const Self) u32 {
        const level = self.levels | self.route(self.asserting());
        return (self.latched & self.kinds) | (level & ~self.kinds);
    }

    /// The pending ids that are also unmasked, which is what the status register reads as.
    pub fn status(self: *const Self) u32 {
        var out: u32 = 0;
        var rest = self.pending();
        while (rest != 0) {
            const id: u5 = @intCast(@ctz(rest));
            rest &= rest - 1;
            if (self.unmasked(id)) out |= @as(u32, 1) << id;
        }
        return out;
    }

    /// Whether an id is enabled, is an external one, and has priority at or above the threshold.
    pub fn unmasked(self: *const Self, id: u5) bool {
        if ((self.enabled & self.layout.external) >> id & 1 == 0) return false;
        const priority = self.priorities[id];
        return (priority != 0 or !self.layout.zero_masks) and @as(u8, priority) >= self.threshold;
    }

    /// The highest-priority id asking within the gate, or null if none is.
    pub fn best(self: *const Self, gate: u32) ?u5 {
        var chosen: ?u5 = null;
        var top: u4 = 0;
        var rest = self.status() & gate;
        while (rest != 0) {
            const id: u5 = @intCast(@ctz(rest));
            rest &= rest - 1;
            if (chosen == null or self.priorities[id] > top) {
                top = self.priorities[id];
                chosen = id;
            }
        }
        return chosen;
    }

    /// The word a register read in either window answers; an address with no register reads zero.
    pub fn readRegister(self: *const Self, address: u32) u32 {
        if (self.mapped(address)) |source| return self.map[source];
        if (self.prioritised(address)) |id| return self.priorities[id];
        if (self.softwareAt(address)) |i| return @intFromBool(self.software & bitOf(i) != 0);
        const offset = address -% self.layout.control_base;
        if (offset == self.layout.enable) return self.enabled;
        if (offset == self.layout.kinds) return self.kinds;
        if (offset == self.layout.clear) return self.cleared;
        if (offset == self.layout.status) return self.status();
        if (offset == self.layout.threshold) return self.threshold;
        return 0;
    }

    /// Takes a register write; a clear drops the latch and a software register raises its own source.
    pub fn writeRegister(self: *Self, address: u32, value: u32) void {
        if (self.mapped(address)) |source| {
            self.map[source] = @truncate(value);
            return;
        }
        if (self.prioritised(address)) |id| {
            self.priorities[id] = @truncate(value);
            return;
        }
        if (self.softwareAt(address)) |i| {
            if (value & 1 == 0) {
                self.software &= ~bitOf(i);
                return;
            }
            if (self.software & bitOf(i) != 0) return;
            self.software |= bitOf(i);
            self.latched |= self.route(line(self.layout.software_source + @as(usize, i)));
            return;
        }
        const offset = address -% self.layout.control_base;
        if (offset == self.layout.enable) {
            self.enabled = value;
        } else if (offset == self.layout.kinds) {
            self.kinds = value;
        } else if (offset == self.layout.clear) {
            self.cleared = value;
            self.latched &= ~value;
        } else if (offset == self.layout.threshold) {
            self.threshold = @truncate(value & self.layout.threshold_mask);
        }
    }
};
