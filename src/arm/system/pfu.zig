//! The M7 prefetch unit's reads, TRM 1.2.2 and Table 5-3: one read outstanding, an INCR burst to
//! the line's end, held until left. It reads the next line or predicted target once fetch passes
//! the end, after a turn into a held line, or ahead of a later data read, but not until decode
//! settled two cycles into the held line and the last uncached data access returned. The predictor
//! turns one branch a cycle, at most eight doublewords ahead; a predicted table branch's table
//! read follows the next read. A wrong prediction reads the guessed path until resolved.
const std = @import("std");

const none = std.math.maxInt(u32);
const never = std.math.maxInt(u64);
const pass: u64 = 2;
const lead: u64 = 2;
const settle: u64 = 2;

/// A taken branch: when it resolved, whether predicted early, and whether the target's line turns again.
pub const Turn = struct { at: u64, early: bool, within: bool = false };

/// The line held, when each of its doublewords arrived, and the branch turning the fetch.
pub const Stream = struct {
    line: u32 = none,
    from: u32 = 0,
    beats: [4]u64 = @splat(0),
    done: u64 = 0,
    ahead: u64 = 0,
    last: u64 = 0,
    since: u64 = 0,
    decoded: [8]u64 = @splat(0),
    newest: u3 = 0,
    dword: u32 = none,
    turn: ?Turn = null,
    guess: u32 = 1,
    turned: bool = false,
    back: u32 = none,
    decoding: u32 = none,
    strayed: bool = false,
    table: u32 = none,
    table_at: u64 = 0,
    release: u64 = 0,
    entered: u64 = 0,

    /// The cycles decode waits at `now` for the word at `word` from `hook`.
    pub fn fetch(self: *Stream, hook: anytype, word: u32, now: u64) u32 {
        const line = word >> 5;
        const index = word >> 3 & 3;
        const behind = self.decoded[self.newest +% 1];
        const strayed = self.strayed;
        self.strayed = false;
        if (word >> 3 != self.dword) {
            self.dword = word >> 3;
            self.newest +%= 1;
            self.decoded[self.newest] = now;
        }
        if (line == self.back and self.turn == null) return 0;
        self.back = none;
        const entering = line != self.decoding;
        self.decoding = line;
        const held = line == self.line and index >= self.from;
        if (entering and held and self.turn == null) self.entered = now + settle;
        const next = self.line +% 1;
        if (self.turn) |t| {
            self.turn = null;
            if (t.early) {
                self.since = @max(self.since + 1, self.last, behind);
                if (held) {
                    self.ahead = if (t.within) never else @max(self.done, self.since);
                } else self.read(hook, line, index, @max(self.done, self.since));
            } else {
                const passed = !strayed and t.at > self.ahead and self.line != none;
                if (passed) self.read(hook, next, 0, self.ahead);
                if (strayed) while (t.at > self.done) self.cut(hook, self.line +% 1, self.done - pass, t.at);
                self.since = @max(if (strayed) self.done - pass else self.done, t.at);
                const covered = strayed and line == self.line and index >= self.from;
                if (!covered and !(passed and line == next)) self.read(hook, line, index, self.since);
            }
        } else if (!held) self.read(hook, line, index, if (line == next and self.ahead != never) self.sequel() else @max(self.done, now));
        self.last = self.beats[index];
        return @intCast(self.beats[index] -| now);
    }

    /// A wrongly predicted taken branch issued at `at`: fetch reads on from `target`, or `onward` if held, until resolved.
    pub fn stray(self: *Stream, hook: anytype, target: u32, onward: u32, at: u64) void {
        const line = target >> 5;
        const index = target >> 3 & 3;
        const start = @max(self.done, self.last, at -| lead);
        const held = line == self.line and index >= self.from;
        self.strayed = !held or onward >> 5 != line;
        if (held and self.strayed) self.read(hook, onward >> 5, onward >> 3 & 3, start) else self.read(hook, line, index, start);
    }

    /// A data read at `at` queues behind the read of `onward`, the line's predicted target or next line, begun before then.
    pub fn advance(self: *Stream, hook: anytype, onward: u32, at: u64) void {
        const start = self.sequel();
        if (self.turn != null or self.line == none or self.decoding != self.line or start > at or onward >> 5 == self.line) return;
        self.back = self.line;
        self.read(hook, onward >> 5, onward >> 3 & 3, start);
    }

    /// A predicted branch issued at `from` falls through at `at`: a guessed target read begun before then still runs.
    pub fn restart(self: *Stream, hook: anytype, target: u32, from: u64, at: u64) void {
        const start = @max(self.done, self.last, from -| lead);
        if (target != 1 and target >> 5 != self.line and start < at) self.read(hook, target >> 5, target >> 3 & 3, start);
        self.ahead = @max(self.done, at);
        self.since = at;
    }

    fn sequel(self: *const Stream) u64 {
        return @max(self.ahead, @max(self.entered, self.release));
    }

    fn cut(self: *Stream, hook: anytype, line: u32, at: u64, until: u64) void {
        var t = at + hook.wait(.fetch, line << 5, at);
        var j: u32 = 1;
        while (j < 4 and t < until) : (j += 1) t += hook.wait(.burst, line << 5 | j << 3, t);
        self.line = if (j == 4) line else none;
        self.from = 0;
        self.done = t + pass;
        self.ahead = t + pass;
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
        if (self.table != none) self.lookup(hook);
    }

    fn lookup(self: *Stream, hook: anytype) void {
        _ = hook.wait(.fetch, self.table, self.table_at);
        self.table = none;
    }
};
