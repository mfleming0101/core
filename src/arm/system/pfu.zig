//! The M7 prefetch unit's instruction reads outside the instruction cache, M7 TRM 1.2.2 and
//! Table 5-3: one read outstanding, an INCR burst of doublewords from the one wanted to the end
//! of its 32-byte line, which the unit holds until it leaves the line. Once the unit's fetch
//! passes the end of the line it reads the next one. A predicted branch turns the fetch where
//! the unit meets it, so a loop within the line never passes its end; a branch the prediction
//! missed turns it only once resolved, after any read of the next line already under way.
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

    /// The cycles decode waits at `now` for the word at `word` from `hook`.
    pub fn fetch(self: *Stream, hook: anytype, word: u32, now: u64) u32 {
        const line = word >> 5;
        const index = word >> 3 & 3;
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

    /// A wrongly predicted taken branch issued at `at`: fetch followed it to `target`'s line until resolved.
    pub fn stray(self: *Stream, hook: anytype, target: u32, at: u64) void {
        const line = target >> 5;
        if (line != self.line) self.read(hook, line, target >> 3 & 3, @max(self.done, self.last, at -| lead));
        self.ahead = never;
    }

    /// A predicted branch found not taken at `at`: the fetch resumes past it.
    pub fn restart(self: *Stream, at: u64) void {
        self.ahead = @max(self.done, at);
    }

    fn read(self: *Stream, hook: anytype, line: u32, index: u32, at: u64) void {
        var t = at + pass + hook.wait(.fetch, line << 5 | index << 3, at);
        self.beats[index] = t;
        for (index + 1..4) |j| {
            t += hook.wait(.burst, line << 5 | @as(u32, @intCast(j)) << 3, t);
            self.beats[j] = t;
        }
        self.line = line;
        self.from = index;
        self.done = t;
        self.ahead = t;
    }
};
