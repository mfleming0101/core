const std = @import("std");

const never = std.math.maxInt(u64);
const cap = 4;
const low = 2;

pub fn Fetch(comptime Ports: type) type {
    return struct {
        const Self = @This();

        ports: Ports = .{},
        next: u64 = 1,
        expect: u32 = 0,
        head: u32 = 0,
        cycle: u64 = 0,
        fp: u32 = 0,
        at: u64 = 0,
        halt: u64 = never,
        swept: u32 = 0,
        block: Ports.Block = .{ .lo = 0, .hi = 0, .id = 0, .banks = 0 },
        ready: [8]u64 = @splat(0),
        redirect: u64 = never,
        target: u32 = 0,
        data: u64 = never,
        port: u8 = 0,
        frozen: u64 = never,

        pub fn issue(self: *Self, pc: u32, wide: bool, cost: u32, landed: bool, branched: bool, to: u32, port: u8) u32 {
            const start = self.next;
            const extra = @intFromBool(landed);
            const end = pc +% @as(u32, if (wide) 4 else 2);
            const last = (end -% 1) & ~@as(u32, 3);
            const d = start + extra;
            if (self.data > d and pc == self.expect) {
                if (self.redirect <= d) self.redirected(self.redirect);
                if (self.redirect == never) {
                    const ahead: i32 = @bitCast(last -% self.fp);
                    const ready = if (ahead < 0) self.ready[last >> 2 & 7] else self.at + @as(u32, @intCast(ahead >> 2)) + 1;
                    if (ready <= d and self.frozen != d) {
                        self.cycle = @max(self.cycle, d + 1);
                        return self.decoded(d, end, start, cost, extra, branched, to, port);
                    }
                }
            }
            return self.slow(pc, d, end, last, start, cost, extra, branched, to, port);
        }

        noinline fn slow(self: *Self, pc: u32, from: u64, end: u32, last: u32, start: u64, cost: u32, extra: u1, branched: bool, to: u32, port: u8) u32 {
            @branchHint(.cold);
            var d = from;
            if (pc != self.expect) self.flush(@max(start - 1, self.cycle), pc);
            const first = pc & ~@as(u32, 3);
            while (true) {
                self.upto(d);
                const ready = @max(self.readyAt(first), self.readyAt(last));
                if (ready > d) {
                    d = @min(ready, self.redirect, self.data);
                } else if (self.frozen == d) {
                    d += 1;
                } else break;
            }
            return self.decoded(d, end, start, cost, extra, branched, to, port);
        }

        inline fn decoded(self: *Self, d: u64, end: u32, start: u64, cost: u32, extra: u1, branched: bool, to: u32, port: u8) u32 {
            const stop = self.pauseAt();
            if (self.halt == never and stop <= d) self.halt = stop;
            self.head = @max(self.head, end & ~@as(u32, 3));
            if (self.halt != never and (self.frontier(d) -% self.head) >> 2 <= low) {
                @branchHint(.unlikely);
                self.keep(d);
                self.at = d + 1;
                self.halt = never;
            }
            var e = d + cost - extra;
            var sent = false;
            while (self.data <= e) {
                const at = self.data;
                if (branched and e - 1 <= at and self.cycle <= e - 1) {
                    self.flush(e - 1, to);
                    sent = true;
                }
                if (self.redirect <= at) self.upto(at) else {
                    const paused = self.pauseAt();
                    if (self.halt == never and paused <= at) self.halt = paused;
                    self.arbitrate(at);
                    self.cycle = @max(self.cycle, at + 1);
                }
                if (self.frozen == at) e += 1;
            }
            if (branched and (!sent or self.cycle <= e - 1)) self.flush(@max(e - 1, self.cycle), to);
            self.next = e;
            self.expect = if (branched) to else end;
            if (port != 0) {
                self.data = e + 1;
                self.port = port;
            }
            return @intCast(e - start);
        }

        fn flush(self: *Self, at: u64, target: u32) void {
            self.redirect = at;
            self.target = target;
        }

        fn readyAt(self: *const Self, word: u32) u64 {
            if (@as(i32, @bitCast(word -% self.head)) < 0) return never;
            const ahead: i32 = @bitCast(word -% self.fp);
            if (ahead < 0) return self.ready[word >> 2 & 7];
            const at = self.at + @as(u32, @intCast(ahead >> 2));
            return if (at < @min(self.halt, self.pauseAt())) at + 1 else never;
        }

        fn pauseAt(self: *const Self) u64 {
            const held: i32 = @as(i32, @bitCast(self.fp -% self.head)) >> 2;
            return self.at + @as(u32, @intCast(@max(cap - held, 0)));
        }

        fn frontier(self: *const Self, c: u64) u32 {
            return self.fp +% @as(u32, @intCast(@min(c, self.halt) - self.at)) * 4;
        }

        inline fn keep(self: *Self, c: u64) void {
            const k = @min(c, self.halt) - self.at;
            var i = k -| cap;
            while (i < k) : (i += 1) self.ready[(self.fp >> 2) +% @as(u32, @intCast(i)) & 7] = self.at + i + 1;
            self.fp +%= @as(u32, @intCast(k)) * 4;
        }

        inline fn sweep(self: *Self, c: u64) void {
            const end = self.frontier(c);
            if (self.ports.data != 0) {
                const b = self.block;
                if (self.swept >= b.lo and end <= b.hi) {
                    if (b.banks != 0) {
                        const words = (end - self.swept) >> 2;
                        const all = (@as(u64, 1) << @intCast(b.banks)) - 1;
                        const run = if (words >= b.banks) all else ((@as(u64, 1) << @intCast(words)) - 1) << @intCast(((self.swept - b.lo) >> 2) % b.banks);
                        self.ports.data &= ~(((run | run >> @intCast(b.banks)) & all) << @intCast(b.id));
                    }
                } else {
                    self.ports.fetched(self.swept, end);
                    self.block = Ports.blockOf(end);
                }
            }
            self.swept = end;
        }

        fn portOf(self: *const Self, word: u32) u8 {
            const b = self.block;
            if (word < b.lo or word >= b.hi) return Ports.of(word);
            return if (b.banks == 0) 0 else b.id + @as(u8, @intCast(((word - b.lo) >> 2) % b.banks));
        }

        fn redirected(self: *Self, t: u64) void {
            const stop = self.pauseAt();
            if (self.halt == never and stop <= t) self.halt = stop;
            self.restart(t);
        }

        inline fn restart(self: *Self, t: u64) void {
            self.sweep(t);
            self.fp = self.target & ~@as(u32, 3);
            self.head = self.fp;
            self.swept = self.fp;
            self.halt = never;
            self.at = t;
            self.redirect = never;
        }

        fn upto(self: *Self, c: u64) void {
            while (true) {
                const t = @min(self.redirect, self.data);
                if (t > c) break;
                const stop = self.pauseAt();
                if (self.halt == never and stop <= t) self.halt = stop;
                if (self.redirect == t) self.restart(t);
                if (self.data == t) self.arbitrate(t);
            }
            self.cycle = @max(self.cycle, c + 1);
        }

        inline fn arbitrate(self: *Self, t: u64) void {
            const word = self.frontier(t);
            self.sweep(t);
            if (self.halt == never and self.portOf(word) == self.port) {
                @branchHint(.unlikely);
                if (self.ports.dataLast(self.port)) {
                    self.frozen = t;
                    self.data = t + 1;
                    return;
                }
                self.keep(t);
                self.at = t + 1;
            }
            self.ports.granted(self.port);
            self.data = never;
        }
    };
}
