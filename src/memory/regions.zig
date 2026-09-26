//! The bus the library ships, and the fold in front of it. Regions is a sorted,
//! non-overlapping array of memory blocks and devices the caller owns, found by binary search
//! with the last device answered cached ahead of it. Folded is the three one-block caches a
//! processor reaches memory through, one per access lane, so a hit is a subtract and a
//! compare. The rest is the device schedule: two intrusive lists, the raise word and the
//! attention point the processor's clock is followed through.
const std = @import("std");
const contract = @import("../contract.zig");

/// The size of a device access; the values are the byte counts themselves.
pub const Width = enum(u3) { byte = 1, half = 2, word = 4 };

/// How many interrupt lines the bus carries: the most an Arm core other than the M33, M55 and M85 is built with, and more than either ESP32 has.
pub const lines = 240;
/// A set of interrupt lines, one bit per line.
pub const Lines = u240;
/// One interrupt line: an Arm IRQ number or a RISC-V interrupt matrix source.
pub const Line = u8;

/// Anything in the address space that is not memory: a context and the calls made on it.
pub const Device = struct {
    context: *anyopaque,
    read: *const fn (context: *anyopaque, offset: u32, width: Width, raise: *Lines) ?u32,
    write: *const fn (context: *anyopaque, offset: u32, width: Width, value: u32, raise: *Lines) ?void,
    tick: ?*const fn (context: *anyopaque, cycles: u32, raise: *Lines) ?u32 = null,
    asserted: ?*const fn (context: *anyopaque) Lines = null,
};

/// One folded run of addresses that all answer the same way, with its host bytes if memory backs it.
pub const Block = struct { base: u32 = 0, len: u64 = 0, host: ?[*]u8 = null };

const none: u32 = std.math.maxInt(u32);

/// Pulls the low or high bound of a block in to an edge, whichever side of the address it is.
pub fn narrow(address: u32, low: *u64, high: *u64, edge: u64) void {
    if (edge <= address) low.* = @max(low.*, edge) else high.* = @min(high.*, edge);
}

/// What a lookup answers: the entry or hole holding the address, and the device index if one owns it.
pub const Found = struct { base: u32, len: u64, host: ?[*]u8 = null, writable: bool = false, window: ?u32 = null };

/// The three one-block caches, one per lane, a processor fetches, loads and stores through.
pub const Folded = struct {
    blocks: [3]Block = @splat(.{}),
    refused: [3]Block = @splat(.{}),

    fn lane(kind: contract.Kind) usize {
        return switch (kind) {
            .fetch => 0,
            .read, .vector => 1,
            .write => 2,
        };
    }

    /// The bytes from an address to the end of the lane's block, or empty if it does not hold them.
    pub inline fn span(self: *Folded, address: u32, comptime n: usize, kind: contract.Kind) []u8 {
        return within(&self.blocks[lane(kind)], address, n);
    }

    inline fn within(block: *const Block, address: u32, comptime n: usize) []u8 {
        const offset = address -% block.base;
        if (@as(u64, offset) + n > block.len) return &.{};
        const host = block.host orelse return &.{};
        return host[offset..@intCast(block.len)];
    }

    /// A span, refolding the lane through the caller's describe once when the block does not hold it.
    pub inline fn reach(self: *Folded, address: u32, comptime n: usize, comptime kind: contract.Kind, host: anytype, comptime describe: anytype) []u8 {
        const bytes = self.span(address, n, kind);
        if (bytes.len != 0) return bytes;
        @call(.never_inline, refold, .{ self, address, kind, host, describe });
        return self.span(address, n, kind);
    }

    noinline fn refold(self: *Folded, address: u32, kind: contract.Kind, host: anytype, comptime describe: anytype) void {
        if (self.holds(address, kind)) return;
        const block = describe(host, address, kind);
        if (block.host == null) self.refuse(kind, block) else self.publish(kind, block);
    }

    /// Whether the lane has already answered for this address, as a block or as a refusal.
    pub fn holds(self: *const Folded, address: u32, kind: contract.Kind) bool {
        const at = lane(kind);
        if (@as(u64, address -% self.refused[at].base) < self.refused[at].len) return true;
        const block = self.blocks[at];
        return @as(u64, address -% block.base) < block.len;
    }

    /// Remembers a run nothing answers, so the next access to it goes straight to the slow lane.
    pub fn refuse(self: *Folded, kind: contract.Kind, block: Block) void {
        self.refused[lane(kind)] = block;
    }

    /// Puts a block in a lane, which every later access in its bounds is answered from.
    pub fn publish(self: *Folded, kind: contract.Kind, block: Block) void {
        self.blocks[lane(kind)] = block;
    }

    /// Empties every lane, which anything that can change an answer must do.
    pub noinline fn unfold(self: *Folded) void {
        self.blocks = @splat(.{});
        self.refused = @splat(.{});
    }
};

/// The bus: the sorted entries, the folded caches, the device schedule and the raise word.
pub const Regions = struct {
    entries: []const Entry,
    raised: Lines = 0,
    armed: bool = false,
    now: u64 = 0,
    elapsed: u32 = 0,
    due: u32 = 0,
    first_tick: u32 = none,
    first_held: u32 = none,
    clock: ?*const u64 = null,
    attention: ?*u64 = null,
    folded: Folded = .{},
    recent: Window = .{},

    /// One block of bytes at a base, and whether a store may reach it.
    pub const Memory = struct { base: u32, bytes: []u8, writable: bool };

    const Window = struct { base: u32 = 0, size: u32 = 0, at: u32 = none };

    /// One device at a base and size, with its links in the tick and held-line lists.
    pub const Mapped = struct { base: u32, size: u32, device: Device, next_tick: u32 = none, next_held: u32 = none };

    /// One element of the map: bytes or a device.
    pub const Entry = union(enum) {
        memory: Memory,
        device: Mapped,

        fn base(self: Entry) u32 {
            return switch (self) {
                inline else => |e| e.base,
            };
        }

        fn span(self: Entry) u32 {
            return switch (self) {
                .memory => |m| @intCast(m.bytes.len),
                .device => |d| d.size,
            };
        }
    };

    /// Why a set of entries cannot become a map.
    pub const Malformed = error{ Empty, Wraps, Overlaps };

    /// Sorts the caller's entries in place, keeps them, and threads the tick and held-line lists.
    fn offending(entries: []const Entry) ?struct { at: usize, err: Malformed } {
        for (entries, 0..) |entry, i| {
            const span = entry.span();
            if (span == 0) return .{ .at = i, .err = error.Empty };
            if (@as(u64, entry.base()) + span > 1 << 32) return .{ .at = i, .err = error.Wraps };
            if (i + 1 < entries.len and @as(u64, entry.base()) + span > entries[i + 1].base()) return .{ .at = i + 1, .err = error.Overlaps };
        }
        return null;
    }

    /// Where the entry adopt refused lies, once it has sorted them: the empty or wrapping one, or the later of two that overlap.
    pub fn culprit(entries: []const Entry) ?struct { base: u32, size: u32 } {
        const bad = offending(entries) orelse return null;
        return .{ .base = entries[bad.at].base(), .size = entries[bad.at].span() };
    }

    pub fn adopt(entries: []Entry) Malformed!Regions {
        sort(entries);
        if (offending(entries)) |bad| return bad.err;
        var first_tick: u32 = none;
        var first_held: u32 = none;
        var i = entries.len;
        while (i > 0) {
            i -= 1;
            if (entries[i] != .device) continue;
            const mapped = &entries[i].device;
            if (mapped.device.tick != null) {
                mapped.next_tick = first_tick;
                first_tick = @intCast(i);
            }
            if (mapped.device.asserted != null) {
                mapped.next_held = first_held;
                first_held = @intCast(i);
            }
        }
        return .{
            .entries = entries,
            .due = @intFromBool(first_tick != none),
            .first_tick = first_tick,
            .first_held = first_held,
        };
    }

    fn sort(entries: []Entry) void {
        var i: usize = 1;
        while (i < entries.len) : (i += 1) {
            var j = i;
            while (j > 0 and entries[j].base() < entries[j - 1].base()) : (j -= 1) {
                std.mem.swap(Entry, &entries[j], &entries[j - 1]);
            }
        }
    }

    /// The entry an address falls in, or the bounds of the hole, with the last device tried in front.
    pub fn lookup(self: *Regions, address: u32) Found {
        const recent = self.recent;
        if (address -% recent.base < recent.size) return .{ .base = recent.base, .len = recent.size, .window = recent.at };
        var low: usize = 0;
        var high: usize = self.entries.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const entry = &self.entries[mid];
            if (address -% entry.base() < entry.span()) return switch (entry.*) {
                .memory => |m| .{ .base = m.base, .len = m.bytes.len, .host = m.bytes.ptr, .writable = m.writable },
                .device => |d| blk: {
                    self.recent = .{ .base = d.base, .size = d.size, .at = @intCast(mid) };
                    break :blk .{ .base = d.base, .len = d.size, .window = self.recent.at };
                },
            };
            if (address < entry.base()) high = mid else low = mid + 1;
        }
        const first: u64 = if (low == 0) 0 else @as(u64, self.entries[low - 1].base()) + self.entries[low - 1].span();
        const last: u64 = if (low == self.entries.len) 1 << 32 else self.entries[low].base();
        return .{ .base = @intCast(first), .len = last - first };
    }

    fn within(found: Found, address: u32, comptime n: usize, comptime write: bool) ?*[n]u8 {
        const host = found.host orelse return null;
        if (write and !found.writable) return null;
        const offset = address -% found.base;
        if (@as(u64, offset) + n > found.len) return null;
        return host[offset..][0..n];
    }

    fn find(self: *Regions, address: u32, comptime n: usize, comptime write: bool) ?*[n]u8 {
        return within(self.lookup(address), address, n, write);
    }

    fn reach(self: *Regions, found: Found, address: u32, width: Width) ?*const Mapped {
        const mapped = &self.entries[found.window orelse return null].device;
        if (@as(u64, address -% mapped.base) + @intFromEnum(width) > mapped.size) return null;
        return mapped;
    }

    fn ask(self: *Regions, found: Found, address: u32, width: Width) ?u32 {
        const mapped = self.reach(found, address, width) orelse return null;
        defer self.arm();
        self.catchUp();
        return mapped.device.read(mapped.device.context, address -% mapped.base, width, &self.raised);
    }

    fn tell(self: *Regions, found: Found, address: u32, width: Width, value: u32) ?void {
        const mapped = self.reach(found, address, width) orelse return null;
        defer self.arm();
        self.catchUp();
        mapped.device.write(mapped.device.context, address -% mapped.base, width, value, &self.raised) orelse return null;
        const tick = mapped.device.tick orelse return;
        const next = @max(tick(mapped.device.context, 0, &self.raised) orelse return, 1);
        if (self.due != 0 and next >= self.due) return;
        self.due = next;
        const attention = self.attention orelse return;
        const at = self.now +| next;
        if (at < attention.*) attention.* = at;
    }

    fn arm(self: *Regions) void {
        if (self.raised == 0) return;
        self.armed = true;
        const attention = self.attention orelse return;
        if (self.now < attention.*) attention.* = self.now;
    }

    /// Cycles until a device wants attention: zero if lines are waiting, forever if none ticks.
    pub fn untilDue(self: *const Regions) u64 {
        if (self.armed) return 0;
        if (self.due == 0) return std.math.maxInt(u64);
        return self.due -| self.elapsed;
    }

    /// Follows the processor's cycle counter, and moves its attention point when a device is due sooner.
    pub fn follow(self: *Regions, clock: *const u64, attention: *u64) void {
        self.clock = clock;
        self.attention = attention;
    }

    fn carryTo(self: *Regions, cycle: u64) void {
        const pending = cycle -% self.now;
        if (pending == 0) return;
        self.now = cycle;
        if (self.due == 0) return;
        self.elapsed +|= @intCast(@min(pending, std.math.maxInt(u32)));
        if (self.elapsed >= self.due) self.wake();
    }

    fn catchUp(self: *Regions) void {
        if (self.clock) |clock| self.carryTo(clock.*);
        if (self.first_tick != none and self.elapsed != 0) self.wake();
    }

    /// The lines devices raised since the last call, taken and cleared, or null if none.
    pub fn interrupts(self: *Regions) ?Lines {
        if (self.clock) |clock| self.carryTo(clock.*);
        if (!self.armed) return null;
        self.armed = false;
        defer self.raised = 0;
        return self.raised;
    }

    /// The lines devices hold high right now, for level-sensitive sources.
    pub fn asserted(self: *const Regions) Lines {
        var high: Lines = 0;
        var at = self.first_held;
        while (at != none) {
            const mapped = &self.entries[at].device;
            high |= mapped.device.asserted.?(mapped.device.context);
            at = mapped.next_held;
        }
        return high;
    }

    noinline fn wake(self: *Regions) void {
        const elapsed = self.elapsed;
        self.elapsed = 0;
        var soonest: u32 = 0;
        var at = self.first_tick;
        while (at != none) {
            const mapped = &self.entries[at].device;
            if (mapped.device.tick.?(mapped.device.context, elapsed, &self.raised)) |next| {
                const want = @max(next, 1);
                if (soonest == 0 or want < soonest) soonest = want;
            }
            at = mapped.next_tick;
        }
        self.due = soonest;
        self.arm();
    }

    /// Copies bytes into the memory covering an address and zeroes the rest of the span.
    pub fn place(self: *Regions, address: u32, bytes: []const u8, span: usize) bool {
        const found = self.lookup(address);
        const host = found.host orelse return false;
        const offset = address -% found.base;
        if (bytes.len > span or @as(u64, offset) + span > found.len) return false;
        @memcpy(host[offset..][0..bytes.len], bytes);
        @memset(host[offset + bytes.len ..][0 .. span - bytes.len], 0);
        return true;
    }

    /// One halfword of code, or null where no memory answers.
    pub fn parcel(self: *Regions, address: u32) ?u16 {
        const bytes = self.find(address, 2, false) orelse return null;
        return std.mem.readInt(u16, bytes, .little);
    }

    /// Reads one, two or four bytes from memory or a device; null where nothing answers.
    pub fn peek(self: *Regions, comptime bytes: u8, address: u32) ?contract.Word(bytes) {
        const found = self.lookup(address);
        const host = within(found, address, bytes, false) orelse
            return @truncate(self.ask(found, address, @enumFromInt(bytes)) orelse return null);
        return std.mem.readInt(contract.Word(bytes), host, .little);
    }

    /// Writes one, two or four bytes to memory or a device; null where nothing takes it.
    pub fn poke(self: *Regions, comptime bytes: u8, address: u32, value: contract.Word(bytes)) ?void {
        const found = self.lookup(address);
        const host = within(found, address, bytes, true) orelse
            return self.tell(found, address, @enumFromInt(bytes), value);
        std.mem.writeInt(contract.Word(bytes), host, value, .little);
    }
};
