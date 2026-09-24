const std = @import("std");
const regions = @import("../../src/memory/regions.zig");
const Regions = regions.Regions;
const Kind = @import("../../src/contract.zig").Kind;

fn memory(base: u32, bytes: []u8, writable: bool) Regions.Entry {
    return .{ .memory = .{ .base = base, .bytes = bytes, .writable = writable } };
}

fn after(r: *Regions, clock: *u64, cycles: u32) ?regions.Lines {
    clock.* += cycles;
    return r.interrupts();
}

test "a region answers reads and writes inside its bounds, refuses writes when read-only, and leaves gaps and straddles unmapped" {
    var flash: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var ram: [4]u8 = @splat(0);
    var entries = [_]Regions.Entry{ memory(0x0800_0000, &flash, false), memory(0x2000_0000, &ram, true) };
    var r = try Regions.adopt(&entries);
    try std.testing.expectEqual(@as(?u32, 0x0403_0201), r.peek(4, 0x0800_0000));
    try std.testing.expectEqual(@as(?u16, 0x0807), r.peek(2, 0x0800_0006));
    try std.testing.expectEqual(@as(?u32, null), r.peek(4, 0x0800_0006));
    try std.testing.expectEqual(@as(?u8, null), r.peek(1, 0x0800_0008));
    try std.testing.expectEqual(@as(?u8, null), r.peek(1, 0x1000_0000));
    try std.testing.expectEqual(@as(?void, null), r.poke(1, 0x0800_0000, 9));
    try std.testing.expectEqual(@as(?void, {}), r.poke(4, 0x2000_0000, 0xdead_beef));
    try std.testing.expectEqual(@as(?u8, 0xef), r.peek(1, 0x2000_0000));
    try std.testing.expectEqual(@as(?void, null), r.poke(2, 0x2000_0003, 1));
}

test "an access that starts inside a region but runs past its end faults there instead of falling through to the next region" {
    var rom: [0x10]u8 = @splat(0xaa);
    var ram: [0x20]u8 = @splat(0);
    var entries = [_]Regions.Entry{ memory(0, &rom, false), memory(0x10, &ram, true) };
    var r = try Regions.adopt(&entries);
    try std.testing.expectEqual(@as(?void, null), r.poke(4, 0x0c, 0x55));
    try std.testing.expectEqual(@as(?void, null), r.poke(4, 0x0e, 0x55));
    try std.testing.expectEqual(@as(?u32, null), r.peek(4, 0x0e));
    try std.testing.expectEqual(@as(u8, 0), ram[0x0e]);
    try std.testing.expectEqual(@as(?u32, 0xaaaa_aaaa), r.peek(4, 0x0c));
    try std.testing.expectEqual(@as(?void, {}), r.poke(4, 0x10, 0x55));
    try std.testing.expectEqual(@as(?u32, 0x55), r.peek(4, 0x10));
}

test "the regions are taken in any order and sorted, and a region that covers an address another already covers is refused" {
    var low: [0x10]u8 = @splat(0xaa);
    var high: [0x10]u8 = @splat(0xbb);
    var reversed = [_]Regions.Entry{ memory(0x2000_0000, &high, true), memory(0, &low, false) };
    var r = try Regions.adopt(&reversed);
    try std.testing.expectEqual(@as(u32, 0), r.entries[0].memory.base);
    try std.testing.expectEqual(@as(?u32, 0xaaaa_aaaa), r.peek(4, 0));
    try std.testing.expectEqual(@as(?u32, 0xbbbb_bbbb), r.peek(4, 0x2000_0000));
    var same = [_]Regions.Entry{ memory(0x2000_0000, &low, false), memory(0x2000_0000, &high, true) };
    try std.testing.expectError(error.Overlaps, Regions.adopt(&same));
    var straddling = [_]Regions.Entry{ memory(0, &low, false), memory(0x08, &high, true) };
    try std.testing.expectError(error.Overlaps, Regions.adopt(&straddling));
}

test "a region with no bytes and a region that runs past the end of the address space are both refused" {
    var bytes: [0x10]u8 = @splat(0);
    var none = [_]Regions.Entry{ memory(0, &.{}, true), memory(0x10, &bytes, true) };
    try std.testing.expectError(error.Empty, Regions.adopt(&none));
    var wrapping = [_]Regions.Entry{memory(0xffff_fff8, &bytes, true)};
    try std.testing.expectError(error.Wraps, Regions.adopt(&wrapping));
}

test "place writes a loaded segment into the region that holds it, ignoring whether it is writable, and zeroes the span the file does not cover" {
    var flash: [8]u8 = @splat(0xff);
    var ram: [8]u8 = @splat(0xff);
    var entries = [_]Regions.Entry{ memory(0x0800_0000, &flash, false), memory(0x2000_0000, &ram, true) };
    var r = try Regions.adopt(&entries);
    try std.testing.expect(r.place(0x0800_0002, &.{ 1, 2, 3 }, 3));
    try std.testing.expectEqual([_]u8{ 0xff, 0xff, 1, 2, 3, 0xff, 0xff, 0xff }, flash);
    try std.testing.expect(r.place(0x2000_0000, &.{ 7, 8 }, 5));
    try std.testing.expectEqual([_]u8{ 7, 8, 0, 0, 0, 0xff, 0xff, 0xff }, ram);
    try std.testing.expect(!r.place(0x0800_0006, &.{ 1, 2, 3 }, 3));
    try std.testing.expect(!r.place(0x1000_0000, &.{1}, 1));
}

test "place refuses a source longer than the span it was given rather than writing past the region" {
    var ram: [8]u8 = @splat(0xff);
    var entries = [_]Regions.Entry{memory(0x2000_0000, &ram, true)};
    var r = try Regions.adopt(&entries);
    try std.testing.expect(!r.place(0x2000_0004, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, 4));
    try std.testing.expect(!r.place(0x2000_0000, &.{ 1, 2, 3, 4, 5 }, 4));
    try std.testing.expectEqual([_]u8{0xff} ** 8, ram);
    try std.testing.expect(r.place(0x2000_0000, &.{ 1, 2, 3, 4 }, 4));
    try std.testing.expectEqual([_]u8{ 1, 2, 3, 4, 0xff, 0xff, 0xff, 0xff }, ram);
}

test "a fetch, a load and a store keep separate folded spans, so the pattern firmware runs evicts none of them" {
    var flash: [0x10]u8 = @splat(0xaa);
    var ram: [0x10]u8 = @splat(0);
    var entries = [_]Regions.Entry{ memory(0, &flash, false), memory(0x2000_0000, &ram, true) };
    var r = try Regions.adopt(&entries);
    inline for ([_]Kind{ .fetch, .read }) |kind| r.folded.publish(kind, spanOf(r.lookup(0)));
    r.folded.publish(.write, spanOf(r.lookup(0x2000_0000)));
    try std.testing.expectEqual(@as(?u16, 0xaaaa), foldedHalf(&r, 0, .fetch));
    try std.testing.expectEqual(@as(?u16, 0xaaaa), foldedHalf(&r, 4, .read));
    r.folded.span(0x2000_0000, 4, .write)[0..4].* = .{ 7, 0, 0, 0 };
    try std.testing.expectEqual(@as(u64, flash.len), r.folded.span(0, 1, .fetch).len);
    try std.testing.expectEqual(@as(u64, ram.len), r.folded.span(0x2000_0000, 1, .write).len);
    try std.testing.expectEqual(@as(?u16, 0xaaaa), foldedHalf(&r, 2, .fetch));
    try std.testing.expectEqual(@as(?u32, 7), r.peek(4, 0x2000_0000));
    try std.testing.expectEqual(@as(?u16, null), foldedHalf(&r, 0x10, .fetch));
}

fn spanOf(found: regions.Found) regions.Block {
    return .{ .base = found.base, .len = found.len, .host = found.host };
}

fn foldedHalf(r: *Regions, address: u32, comptime kind: Kind) ?u16 {
    const bytes = r.folded.span(address, 2, kind);
    if (bytes.len < 2) return null;
    return std.mem.readInt(u16, bytes[0..2], .little);
}

test "a fetch answers by the same rules as a read, faulting off the end of the region that owns it and never crossing into the next" {
    var rom: [0x10]u8 = @splat(0xaa);
    var ram: [0x20]u8 = @splat(0x55);
    var entries = [_]Regions.Entry{ memory(0, &rom, false), memory(0x2000_0000, &ram, true) };
    var r = try Regions.adopt(&entries);
    try std.testing.expectEqual(@as(?u16, 0xaaaa), r.parcel(0x0e));
    try std.testing.expectEqual(@as(?u16, null), r.parcel(0x0f));
    try std.testing.expectEqual(@as(?u16, null), r.parcel(0x10));
    try std.testing.expectEqual(@as(?u16, null), r.parcel(0x1000_0000));
    try std.testing.expectEqual(@as(?u16, 0x5555), r.parcel(0x2000_0000));
}

test "the search finds a region wherever it sits in a long map" {
    var pages: [64][0x10]u8 = undefined;
    var entries: [64]Regions.Entry = undefined;
    for (&pages, &entries, 0..) |*page, *entry, i| {
        page.* = @splat(@intCast(i));
        entry.* = memory(@intCast(0x4000_0000 + i * 0x1000), page, true);
    }
    var r = try Regions.adopt(&entries);
    for (0..64) |i| {
        const at: u32 = @intCast(0x4000_0000 + i * 0x1000);
        try std.testing.expectEqual(@as(?u8, @intCast(i)), r.peek(1, at));
        try std.testing.expectEqual(@as(?u8, null), r.peek(1, at + 0x10));
    }
}

const Counter = struct {
    value: u32 = 0,
    reads: u32 = 0,
    writes: u32 = 0,
    offset: u32 = 0,
    width: regions.Width = .word,

    fn read(context: *anyopaque, offset: u32, width: regions.Width, _: *regions.Lines) ?u32 {
        const self: *Counter = @ptrCast(@alignCast(context));
        self.reads += 1;
        self.offset = offset;
        self.width = width;
        return if (offset == 0) self.value else null;
    }

    fn write(context: *anyopaque, offset: u32, width: regions.Width, value: u32, raise: *regions.Lines) ?void {
        const self: *Counter = @ptrCast(@alignCast(context));
        self.writes += 1;
        self.offset = offset;
        self.width = width;
        if (offset != 0) return null;
        self.value = value;
        raise.* |= value >> 16;
    }

    fn entry(self: *Counter, base: u32, size: u32) Regions.Entry {
        return .{ .device = .{ .base = base, .size = size, .device = .{ .context = self, .read = read, .write = write } } };
    }
};

test "a device answers reads and writes at its own offsets, is told the width, and can refuse an access" {
    var counter: Counter = .{};
    var ram: [0x10]u8 = @splat(0);
    var entries = [_]Regions.Entry{ counter.entry(0x4000_0000, 0x400), memory(0x2000_0000, &ram, true) };
    var r = try Regions.adopt(&entries);
    try std.testing.expectEqual(@as(?void, {}), r.poke(4, 0x4000_0000, 0xdead_beef));
    try std.testing.expectEqual(@as(u32, 0xdead_beef), counter.value);
    try std.testing.expectEqual(regions.Width.word, counter.width);
    try std.testing.expectEqual(@as(?u32, 0xdead_beef), r.peek(4, 0x4000_0000));
    try std.testing.expectEqual(@as(?u8, 0xef), r.peek(1, 0x4000_0000));
    try std.testing.expectEqual(regions.Width.byte, counter.width);
    try std.testing.expectEqual(@as(?u16, 0xbeef), r.peek(2, 0x4000_0000));
    try std.testing.expectEqual(@as(?u32, null), r.peek(4, 0x4000_0010));
    try std.testing.expectEqual(@as(u32, 0x10), counter.offset);
    try std.testing.expectEqual(@as(?void, null), r.poke(4, 0x4000_0010, 1));
    try std.testing.expectEqual(@as(u32, 2), counter.writes);
}

test "the bounds of a device are kept before its model is reached, and the model can still refuse an offset inside them" {
    var counter: Counter = .{};
    var entries = [_]Regions.Entry{counter.entry(0x4000_0000, 0x400)};
    var r = try Regions.adopt(&entries);
    try std.testing.expectEqual(@as(?u32, null), r.peek(4, 0x4000_03fe));
    try std.testing.expectEqual(@as(?u32, null), r.peek(4, 0x4000_0400));
    try std.testing.expectEqual(@as(?u8, null), r.peek(1, 0x4000_0400));
    try std.testing.expectEqual(@as(u32, 0), counter.reads);
    try std.testing.expectEqual(@as(?u8, null), r.peek(1, 0x4000_03ff));
    try std.testing.expectEqual(@as(u32, 1), counter.reads);
}

test "a device is a span of its own, which a core folds as a span that answers nothing rather than as memory" {
    var counter: Counter = .{};
    var flash: [0x10]u8 = @splat(0xaa);
    var ram: [0x10]u8 = @splat(0);
    var entries = [_]Regions.Entry{ memory(0, &flash, false), memory(0x2000_0000, &ram, true), counter.entry(0x4000_0000, 0x400) };
    var r = try Regions.adopt(&entries);
    try std.testing.expectEqual(@as(?u16, 0xaaaa), r.parcel(0));
    try std.testing.expectEqual(@as(?void, {}), r.poke(4, 0x2000_0000, 7));
    try std.testing.expectEqual(@as(?u32, 0xaaaaaaaa), r.peek(4, 4));
    try std.testing.expectEqual(@as(?u32, 0), r.peek(4, 0x4000_0000));
    try std.testing.expectEqual(@as(?[*]u8, null), r.lookup(0x4000_0000).host);
    try std.testing.expectEqual(@as(u32, 0x4000_0000), r.lookup(0x4000_0000).base);
    try std.testing.expectEqual(@as(u64, 0x400), r.lookup(0x4000_0000).len);
    try std.testing.expectEqual(@as(?u32, 7), r.peek(4, 0x2000_0000));
    try std.testing.expectEqual(@as(?u16, 0xaaaa), r.parcel(0));
}

test "a device holds no instructions to fetch and no memory for a segment to load into" {
    var counter: Counter = .{};
    var ram: [0x10]u8 = @splat(0);
    var entries = [_]Regions.Entry{ counter.entry(0, 0x400), memory(0x2000_0000, &ram, true) };
    var r = try Regions.adopt(&entries);
    try std.testing.expectEqual(@as(?u16, null), r.parcel(0));
    try std.testing.expectEqual(@as(u32, 0), counter.reads);
    try std.testing.expect(!r.place(0, &.{ 1, 2, 3 }, 3));
    try std.testing.expect(r.place(0x2000_0000, &.{ 1, 2, 3 }, 3));
}

test "a device overlapping a region is refused like any other overlap" {
    var counter: Counter = .{};
    var ram: [0x800]u8 = @splat(0);
    var entries = [_]Regions.Entry{ memory(0x4000_0000, &ram, true), counter.entry(0x4000_0400, 0x400) };
    try std.testing.expectError(error.Overlaps, Regions.adopt(&entries));
}

test "a map with no regions at all is built rather than refused, and answers nothing" {
    var none: [0]Regions.Entry = .{};
    var r = try Regions.adopt(&none);
    try std.testing.expectEqual(@as(?u8, null), r.peek(1, 0));
    try std.testing.expectEqual(@as(?u16, null), r.parcel(0));
    try std.testing.expect(!r.place(0, &.{1}, 1));
}

test "now counts every cycle the core reports, whether or not any device has a deadline" {
    var none: [0]Regions.Entry = .{};
    var r = try Regions.adopt(&none);
    var clock: u64 = 0;
    var attention: u64 = std.math.maxInt(u64);
    r.follow(&clock, &attention);
    try std.testing.expectEqual(@as(?regions.Lines, null), after(&r, &clock, 7));
    try std.testing.expectEqual(@as(?regions.Lines, null), after(&r, &clock, 5));
    try std.testing.expectEqual(@as(u64, 12), r.now);
}

test "a device asks for an interrupt through the word it is handed, and the memory holds it until it is taken" {
    var counter: Counter = .{};
    var entries = [_]Regions.Entry{counter.entry(0x4000_0000, 0x400)};
    var r = try Regions.adopt(&entries);
    var clock: u64 = 0;
    var attention: u64 = std.math.maxInt(u64);
    r.follow(&clock, &attention);
    try std.testing.expectEqual(@as(?regions.Lines, null), after(&r, &clock, 0));
    try std.testing.expectEqual(@as(?void, {}), r.poke(4, 0x4000_0000, 0x0005_0000));
    try std.testing.expectEqual(@as(?void, {}), r.poke(4, 0x4000_0000, 0x0002_0000));
    try std.testing.expectEqual(@as(?regions.Lines, 7), after(&r, &clock, 0));
    try std.testing.expectEqual(@as(?regions.Lines, null), after(&r, &clock, 0));
}

const Alarm = struct {
    period: u32,
    line: u32,
    rings: u32 = 0,

    fn read(context: *anyopaque, _: u32, _: regions.Width, _: *regions.Lines) ?u32 {
        const self: *Alarm = @ptrCast(@alignCast(context));
        return self.rings;
    }

    fn write(context: *anyopaque, _: u32, _: regions.Width, value: u32, _: *regions.Lines) ?void {
        const self: *Alarm = @ptrCast(@alignCast(context));
        self.period = value;
    }

    fn tick(context: *anyopaque, _: u32, raise: *regions.Lines) ?u32 {
        const self: *Alarm = @ptrCast(@alignCast(context));
        self.rings += 1;
        raise.* |= self.line;
        return if (self.period == 0) null else self.period;
    }

    fn entry(self: *Alarm, base: u32) Regions.Entry {
        return .{ .device = .{ .base = base, .size = 0x10, .device = .{ .context = self, .read = read, .write = write, .tick = tick } } };
    }
};

const Countdown = struct {
    left: u32 = 0,
    line: u32,

    fn read(context: *anyopaque, _: u32, _: regions.Width, _: *regions.Lines) ?u32 {
        const self: *Countdown = @ptrCast(@alignCast(context));
        return self.left;
    }

    fn write(context: *anyopaque, _: u32, _: regions.Width, value: u32, _: *regions.Lines) ?void {
        const self: *Countdown = @ptrCast(@alignCast(context));
        self.left = value;
    }

    fn tick(context: *anyopaque, cycles: u32, raise: *regions.Lines) ?u32 {
        const self: *Countdown = @ptrCast(@alignCast(context));
        if (self.left == 0) return null;
        if (cycles < self.left) {
            self.left -= cycles;
            return self.left;
        }
        self.left = 0;
        raise.* |= self.line;
        return null;
    }

    fn entry(self: *Countdown, base: u32) Regions.Entry {
        return .{ .device = .{ .base = base, .size = 0x10, .device = .{ .context = self, .read = read, .write = write, .tick = tick } } };
    }
};

test "a write settles the cycles that passed before it into every device first, so the written device counts from the write and not from the last wake" {
    var first: Countdown = .{ .line = 2 };
    var second: Countdown = .{ .line = 4 };
    var entries = [_]Regions.Entry{ first.entry(0x4000_0000), second.entry(0x4000_0100) };
    var r = try Regions.adopt(&entries);
    var clock: u64 = 0;
    var attention: u64 = std.math.maxInt(u64);
    r.follow(&clock, &attention);
    try std.testing.expectEqual(@as(?regions.Lines, null), after(&r, &clock, 1));
    try std.testing.expectEqual(@as(?void, {}), r.poke(4, 0x4000_0000, 100));
    try std.testing.expectEqual(@as(?regions.Lines, null), after(&r, &clock, 30));
    try std.testing.expectEqual(@as(?void, {}), r.poke(4, 0x4000_0100, 50));
    try std.testing.expectEqual(@as(u32, 50), r.due);
    try std.testing.expectEqual(@as(?regions.Lines, null), after(&r, &clock, 49));
    try std.testing.expectEqual(@as(?regions.Lines, 4), after(&r, &clock, 1));
    try std.testing.expectEqual(@as(?regions.Lines, null), after(&r, &clock, 19));
    try std.testing.expectEqual(@as(?regions.Lines, 2), after(&r, &clock, 1));
}

test "a device with no tick is never asked for one, and the memory says nothing is due" {
    var counter: Counter = .{};
    var entries = [_]Regions.Entry{counter.entry(0x4000_0000, 0x400)};
    var r = try Regions.adopt(&entries);
    var clock: u64 = 0;
    var attention: u64 = std.math.maxInt(u64);
    r.follow(&clock, &attention);
    try std.testing.expectEqual(@as(u32, 0), r.due);
    try std.testing.expectEqual(@as(?regions.Lines, null), after(&r, &clock, 1000));
}

test "a device that keeps time is ticked once its period has passed, however the cycles arrive" {
    var alarm: Alarm = .{ .period = 100, .line = 2 };
    var entries = [_]Regions.Entry{alarm.entry(0x4000_0000)};
    var r = try Regions.adopt(&entries);
    var clock: u64 = 0;
    var attention: u64 = std.math.maxInt(u64);
    r.follow(&clock, &attention);
    try std.testing.expectEqual(@as(?regions.Lines, 2), after(&r, &clock, 1));
    try std.testing.expectEqual(@as(u32, 100), r.due);
    for (0..99) |_| try std.testing.expectEqual(@as(?regions.Lines, null), after(&r, &clock, 1));
    try std.testing.expectEqual(@as(?regions.Lines, 2), after(&r, &clock, 1));
    try std.testing.expectEqual(@as(u32, 2), alarm.rings);
    try std.testing.expectEqual(@as(?regions.Lines, 2), after(&r, &clock, 400));
    try std.testing.expectEqual(@as(u32, 3), alarm.rings);
}

test "a device that asks for no further tick is left alone" {
    var alarm: Alarm = .{ .period = 0, .line = 4 };
    var entries = [_]Regions.Entry{alarm.entry(0x4000_0000)};
    var r = try Regions.adopt(&entries);
    var clock: u64 = 0;
    var attention: u64 = std.math.maxInt(u64);
    r.follow(&clock, &attention);
    try std.testing.expectEqual(@as(?regions.Lines, 4), after(&r, &clock, 1));
    try std.testing.expectEqual(@as(u32, 0), r.due);
    try std.testing.expectEqual(@as(?regions.Lines, null), after(&r, &clock, 1_000_000));
    try std.testing.expectEqual(@as(u32, 1), alarm.rings);
}

const Insistent = struct {
    rings: u32 = 0,

    fn read(context: *anyopaque, _: u32, _: regions.Width, _: *regions.Lines) ?u32 {
        const self: *Insistent = @ptrCast(@alignCast(context));
        return self.rings;
    }

    fn write(_: *anyopaque, _: u32, _: regions.Width, _: u32, _: *regions.Lines) ?void {}

    fn tick(context: *anyopaque, _: u32, raise: *regions.Lines) ?u32 {
        const self: *Insistent = @ptrCast(@alignCast(context));
        self.rings += 1;
        raise.* |= 8;
        return 0;
    }

    fn entry(self: *Insistent, base: u32) Regions.Entry {
        return .{ .device = .{ .base = base, .size = 0x10, .device = .{ .context = self, .read = read, .write = write, .tick = tick } } };
    }
};

test "a device that asks for its next tick in no cycles is ticked again on the next cycle rather than left alone" {
    var device: Insistent = .{};
    var entries = [_]Regions.Entry{device.entry(0x4000_0000)};
    var r = try Regions.adopt(&entries);
    var clock: u64 = 0;
    var attention: u64 = std.math.maxInt(u64);
    r.follow(&clock, &attention);
    try std.testing.expectEqual(@as(?regions.Lines, 8), after(&r, &clock, 1));
    try std.testing.expectEqual(@as(u32, 1), r.due);
    try std.testing.expectEqual(@as(?regions.Lines, 8), after(&r, &clock, 1));
    try std.testing.expectEqual(@as(u32, 2), device.rings);
}

test "a write to a device that keeps time reschedules it at once, even one that had asked for no further tick" {
    var alarm: Alarm = .{ .period = 0, .line = 4 };
    var entries = [_]Regions.Entry{alarm.entry(0x4000_0000)};
    var r = try Regions.adopt(&entries);
    var clock: u64 = 0;
    var attention: u64 = std.math.maxInt(u64);
    r.follow(&clock, &attention);
    try std.testing.expectEqual(@as(?regions.Lines, 4), after(&r, &clock, 1));
    try std.testing.expectEqual(@as(u32, 0), r.due);
    try std.testing.expectEqual(@as(?void, {}), r.poke(4, 0x4000_0000, 50));
    try std.testing.expectEqual(@as(u32, 50), r.due);
    try std.testing.expectEqual(@as(u32, 2), alarm.rings);
    try std.testing.expectEqual(@as(?regions.Lines, 4), after(&r, &clock, 0));
    try std.testing.expectEqual(@as(?regions.Lines, null), after(&r, &clock, 49));
    try std.testing.expectEqual(@as(?regions.Lines, 4), after(&r, &clock, 1));
    try std.testing.expectEqual(@as(u32, 3), alarm.rings);
}

test "a read of a device settles the elapsed cycles into every device first, so a counter read mid-period is current" {
    var counter: Countdown = .{ .line = 3 };
    var entries = [_]Regions.Entry{.{ .device = .{ .base = 0x4000_0000, .size = 4, .device = .{ .context = &counter, .read = Countdown.read, .write = Countdown.write, .tick = Countdown.tick } } }};
    var r = try Regions.adopt(&entries);
    var clock: u64 = 0;
    var attention: u64 = std.math.maxInt(u64);
    r.follow(&clock, &attention);
    try std.testing.expectEqual(@as(?void, {}), r.poke(4, 0x4000_0000, 100));
    try std.testing.expectEqual(@as(?regions.Lines, null), after(&r, &clock, 30));
    try std.testing.expectEqual(@as(?regions.Lines, null), after(&r, &clock, 20));
    try std.testing.expectEqual(@as(u32, 20), r.elapsed);
    try std.testing.expectEqual(@as(?u32, 50), r.peek(4, 0x4000_0000));
    try std.testing.expectEqual(@as(u32, 0), r.elapsed);
    try std.testing.expectEqual(@as(u32, 50), r.due);
    try std.testing.expectEqual(@as(?regions.Lines, null), after(&r, &clock, 49));
    try std.testing.expectEqual(@as(?regions.Lines, 3), after(&r, &clock, 1));
}

const Latch = struct {
    held: bool = false,

    fn read(_: *anyopaque, _: u32, _: regions.Width, _: *regions.Lines) ?u32 {
        return 0;
    }

    fn write(context: *anyopaque, _: u32, _: regions.Width, _: u32, _: *regions.Lines) ?void {
        const self: *Latch = @ptrCast(@alignCast(context));
        self.held = false;
    }

    fn asserted(context: *anyopaque) regions.Lines {
        const self: *Latch = @ptrCast(@alignCast(context));
        return if (self.held) 1 << 6 else 0;
    }
};

test "asserted() is the union of the lines the devices hold high, and a device without the query holds none" {
    var latch: Latch = .{ .held = true };
    var alarm: Alarm = .{ .period = 100, .line = 2 };
    var entries = [_]Regions.Entry{
        .{ .device = .{ .base = 0x4000_0000, .size = 4, .device = .{ .context = &latch, .read = Latch.read, .write = Latch.write, .asserted = Latch.asserted } } },
        alarm.entry(0x4000_1000),
    };
    var r = try Regions.adopt(&entries);
    try std.testing.expectEqual(@as(regions.Lines, 1 << 6), r.asserted());
    try std.testing.expectEqual(@as(?void, {}), r.poke(4, 0x4000_0000, 0));
    try std.testing.expectEqual(@as(regions.Lines, 0), r.asserted());
}

test "a write to a device that does not keep time leaves the schedule alone" {
    var counter: Counter = .{};
    var entries = [_]Regions.Entry{counter.entry(0x4000_0000, 0x400)};
    var r = try Regions.adopt(&entries);
    var clock: u64 = 0;
    var attention: u64 = std.math.maxInt(u64);
    r.follow(&clock, &attention);
    try std.testing.expectEqual(@as(?void, {}), r.poke(4, 0x4000_0000, 1));
    try std.testing.expectEqual(@as(u32, 0), r.due);
    try std.testing.expectEqual(@as(?regions.Lines, null), after(&r, &clock, 1_000_000));
}
