//! Which lines the M7's level 1 caches hold, as the timing sees them, M7 TRM 5.9: 32-byte lines,
//! the instruction cache two-way and the data cache four-way set-associative, every cacheable
//! read allocating. The TRM names no replacement policy, so a set fills its ways in turn.
const core = @import("core.zig");

/// The tags of one cache of up to 64 KB, the most M7 TRM Table 1-1 allows.
pub fn Cache(comptime ways: u32) type {
    const most = 64 * 1024 / 32 / ways;
    return struct {
        const Self = @This();
        const empty: u32 = 0xffff_ffff;

        tags: [most * ways]u32,
        turn: [most]u8,
        sets: u32,

        /// The tags of a cache of the part's size, every line invalid.
        pub fn init(size: core.CacheSize) Self {
            var self: Self = .{ .tags = undefined, .turn = undefined, .sets = @max(bytesOf(size) / 32 / ways, 1) };
            @memset(&self.tags, empty);
            @memset(&self.turn, 0);
            return self;
        }

        /// Whether the line holding the address is present; a miss allocates it.
        pub fn present(self: *Self, address: u32) bool {
            const line = address >> 5;
            const set = self.tags[(line & (self.sets - 1)) * ways ..][0..ways];
            for (set) |tag| if (tag == line) return true;
            const turn = &self.turn[line & (self.sets - 1)];
            set[turn.*] = line;
            turn.* = @intCast((turn.* + 1) % ways);
            return false;
        }
    };
}

fn bytesOf(size: core.CacheSize) u32 {
    return switch (size) {
        .none => 0,
        .kb4 => 4 << 10,
        .kb8 => 8 << 10,
        .kb16 => 16 << 10,
        .kb32 => 32 << 10,
        .kb64 => 64 << 10,
    };
}

/// Both caches of one M7.
pub const L1 = struct {
    instruction: Cache(2),
    data: Cache(4),

    /// Both caches at the part's sizes, empty.
    pub fn init(part: core.Part) L1 {
        return .{ .instruction = .init(part.instruction), .data = .init(part.data) };
    }
};
