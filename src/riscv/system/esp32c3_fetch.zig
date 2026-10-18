const std = @import("std");

const never = std.math.maxInt(u64);
const cap = 4;
const low = 2;

pub fn Fetch(comptime Ports: type) type {
    return struct {
        const Self = @This();

        ports: Ports = .{},
        cycle: u64 = 0,
        next: u64 = 1,
        fp: u32 = 0,
        head: u32 = 0,
        ready: [8]u64 = @splat(0),
        paused: bool = false,
        redirect: u64 = never,
        target: u32 = 0,
        expect: u32 = 0,
        data: u64 = never,
        port: u8 = 0,
        frozen: u64 = never,

        pub fn issue(self: *Self, pc: u32, wide: bool, cost: u32, landed: bool, to: ?u32, port: u8) u32 {
            const start = self.next;
            if (pc != self.expect) self.flush(@max(start - 1, self.cycle), pc);
            const extra = @intFromBool(landed);
            const end = pc +% @as(u32, if (wide) 4 else 2);
            const first = pc & ~@as(u32, 3);
            const last = (end -% 1) & ~@as(u32, 3);
            var d = start + extra;
            while (true) : (d += 1) {
                self.upto(d);
                if (self.readyAt(first) <= d and self.readyAt(last) <= d and self.frozen != d) break;
            }
            self.head = @max(self.head, end & ~@as(u32, 3));
            var e = d + cost - extra;
            var sent = false;
            while (self.data <= e) {
                const at = self.data;
                if (to) |target| if (e - 1 <= at and self.cycle <= e - 1) {
                    self.flush(e - 1, target);
                    sent = true;
                };
                self.upto(at);
                if (self.frozen == at) e += 1;
            }
            if (to) |target| if (!sent or self.cycle <= e - 1) self.flush(@max(e - 1, self.cycle), target);
            self.next = e;
            self.expect = to orelse end;
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
            return if (word -% self.head < self.fp -% self.head) self.ready[word >> 2 & 7] else never;
        }

        fn upto(self: *Self, c: u64) void {
            while (self.cycle <= c) self.step();
        }

        fn step(self: *Self) void {
            const c = self.cycle;
            if (self.redirect <= c) {
                self.fp = self.target & ~@as(u32, 3);
                self.head = self.fp;
                self.paused = false;
                self.redirect = never;
            }
            const held = (self.fp -% self.head) >> 2;
            if (held >= cap) self.paused = true;
            if (self.paused and held <= low) self.paused = false;
            var fetching = !self.paused;
            const fport = if (fetching) Ports.of(self.fp) else 0;
            if (self.data <= c) {
                const won = !(fetching and fport == self.port and self.ports.dataLast(self.port));
                if (won) {
                    if (fetching and fport == self.port) fetching = false;
                    self.ports.granted(self.port, true);
                    self.data = never;
                } else {
                    self.frozen = c;
                    self.data = c + 1;
                }
            }
            if (fetching) {
                if (fport != 0) self.ports.granted(fport, false);
                self.ready[self.fp >> 2 & 7] = c + 1;
                self.fp +%= 4;
            }
            self.cycle = c + 1;
        }
    };
}
