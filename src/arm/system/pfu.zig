//! The M7 prefetch unit's instruction reads outside the instruction cache, M7 TRM 1.2.2 and
//! Table 5-3: one read outstanding, an INCR burst of doublewords from the one wanted to the end
//! of its 32-byte line, which the unit holds until it leaves the line. It reads the next line once
//! its fetch passes the line's end, or ahead of a data read issued after the line arrived, unless
//! a predicted branch in the line turns it there. A wrong prediction first reads the guessed
//! target; a missed branch turns the fetch once resolved, after any next-line read under way.
const std = @import("std");

const none = std.math.maxInt(u32);
const never = std.math.maxInt(u64);
const pass: u64 = 2;
const lead: u64 = 2;

/// A taken branch: when it resolved, and whether the prediction turned the fetch before then.
pub const Turn = struct { at: u64, early: bool };

/// The line held, when each of its doublewords arrived, and the branch turning the fetch.
pub const Stream = struct {
    line: u32 = none,
    from: u32 = 0,
    beats: [4]u64 = @splat(0),
    done: u64 = 0,
    ahead: u64 = 0,
    last: u64 = 0,
    turn: ?Turn = null,
    guess: u32 = 1,
    turned: bool = false,
    back: u32 = none,
    decoding: u32 = none,

    /// The cycles decode waits at `now` for the word at `word` from `hook`.
    pub fn fetch(self: *Stream, hook: anytype, word: u32, now: u64) u32 {
        const line = word >> 5;
        const index = word >> 3 & 3;
        if (line == self.back and self.turn == null) return 0;
        self.back = none;
        self.decoding = line;
        const held = line == self.line and index >= self.from;
        const next = self.line +% 1;
        if (self.turn) |t| {
            self.turn = null;
            if (t.early) {
                if (held) {
                    self.ahead = never;
                } else self.read(hook, line, index, @max(self.done, self.last, t.at -| lead));
            } else {
                const passed = t.at > self.ahead and self.line != none;
                if (passed) self.read(hook, next, 0, self.ahead);
                if (!(passed and line == next)) self.read(hook, line, index, @max(self.done, t.at));
            }
        } else if (!held) self.read(hook, line, index, if (line == next and self.ahead != never) self.ahead else @max(self.done, now));
        self.last = self.beats[index];
        return @intCast(self.beats[index] -| now);
    }

    /// A wrongly predicted taken branch issued at `at`: fetch reads on from `target` until resolved.
    pub fn stray(self: *Stream, hook: anytype, target: u32, at: u64) void {
        const line = target >> 5;
        self.read(hook, line, target >> 3 & 3, @max(self.done, self.last, at -| lead));
    }

    /// A data read at `at` queues behind the next line's read if the unit started it before then.
    pub fn advance(self: *Stream, hook: anytype, at: u64) void {
        if (self.turn != null or self.line == none or self.decoding != self.line or self.ahead > at) return;
        self.back = self.line;
        self.read(hook, self.line +% 1, 0, self.ahead);
    }

    /// A predicted branch issued at `from` falls through at `at`: a guessed target read begun before then still runs.
    pub fn restart(self: *Stream, hook: anytype, target: u32, from: u64, at: u64) void {
        const start = @max(self.done, self.last, from -| lead);
        if (target != 1 and target >> 5 != self.line and start < at) self.read(hook, target >> 5, target >> 3 & 3, start);
        self.ahead = @max(self.done, at);
    }

    fn read(self: *Stream, hook: anytype, line: u32, index: u32, at: u64) void {
        var t = at + hook.wait(.fetch, line << 5 | index << 3, at);
        self.beats[index] = t + pass;
        for (index + 1..4) |j| {
            t += hook.wait(.burst, line << 5 | @as(u32, @intCast(j)) << 3, t);
            self.beats[j] = t + pass;
        }
        self.line = line;
        self.from = index;
        self.done = t + pass;
        self.ahead = t + pass;
    }
};
