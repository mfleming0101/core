//! The fixed, allocation-free history the trace is kept in. The caller hands the processor a
//! slice of records whose length is a power of two; the ring keeps the newest of them, counts
//! every one ever written and masks rather than divides to find a slot. A zero-length slice is
//! a ring that records nothing, which is what a processor built without tracing carries.
const std = @import("std");

/// A fixed ring of records over a caller-owned slice, keeping the newest and counting all.
pub fn Ring(comptime Record: type) type {
    return struct {
        records: []Record = &.{},
        mask: u64 = 0,
        written: u64 = 0,

        const Self = @This();

        /// The one shape a ring refuses: a slice whose length is not a power of two.
        pub const Misshapen = error{NotPowerOfTwo};

        /// A ring over the caller's slice, which must outlive it; an empty slice records nothing.
        pub fn init(records: []Record) Misshapen!Self {
            if (records.len == 0) return .{};
            if (!std.math.isPowerOfTwo(records.len)) return error.NotPowerOfTwo;
            return .{ .records = records, .mask = records.len - 1 };
        }

        /// Whether the ring has room, which is what the instruction path tests.
        pub fn recording(self: *const Self) bool {
            return self.records.len != 0;
        }

        /// Takes the next slot, overwriting the oldest record, and counts it as written.
        pub fn reserve(self: *Self) *Record {
            const slot: usize = @intCast(self.written & self.mask);
            self.written += 1;
            return &self.records[slot];
        }

        /// The record that many back from the newest, or null past what is held.
        pub fn at(self: *const Self, back: u64) ?Record {
            if (back >= self.written or back >= self.records.len) return null;
            return self.records[@intCast((self.written - 1 - back) & self.mask)];
        }

        /// The newest record, or null if nothing has been written.
        pub fn last(self: *const Self) ?Record {
            return self.at(0);
        }
    };
}
