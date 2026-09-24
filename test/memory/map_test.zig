const std = @import("std");
const map = @import("../../src/memory/map.zig");
const regions = @import("../../src/memory/regions.zig");

const Images = struct {
    named: []const struct { name: []const u8, bytes: []const u8 } = &.{},
    asked: usize = 0,

    pub fn load(self: *Images, name: []const u8, into: []u8) map.Image!usize {
        self.asked += 1;
        for (self.named) |image| {
            if (!std.mem.eql(u8, image.name, name)) continue;
            if (image.bytes.len > into.len) return error.TooLarge;
            @memcpy(into[0..image.bytes.len], image.bytes);
            return image.bytes.len;
        }
        return error.Missing;
    }
};

var ticks: u32 = 0;

fn read(_: *anyopaque, offset: u32, _: regions.Width, _: *regions.Lines) ?u32 {
    ticks += 1;
    return if (offset == 0) ticks else null;
}

fn write(_: *anyopaque, offset: u32, _: regions.Width, value: u32, _: *regions.Lines) ?void {
    if (offset != 0) return null;
    ticks = value;
}

fn make(_: std.mem.Allocator) std.mem.Allocator.Error!regions.Device {
    return .{ .context = @ptrCast(&ticks), .read = read, .write = write };
}

const registry: map.Registry = .{ .models = &.{.{ .name = "ticker", .make = make }} };

fn built(arena: std.mem.Allocator, m: map.Map, images: *Images) map.Fault!regions.Regions {
    var blame: map.Blame = .{};
    return map.build(arena, registry, m, images, &blame);
}

test "a map turns into regions, loads each image into its own, and mirrors an aliased region at both addresses" {
    var buffer: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var images: Images = .{ .named = &.{.{ .name = "boot.bin", .bytes = &.{ 1, 2, 3, 4 } }} };
    var r = try built(fixed.allocator(), .{
        .core = .m4,
        .regions = &.{
            .{ .base = 0x0800_0000, .size = 0x40, .image = "boot.bin", .alias = 0, .writable = false },
            .{ .base = 0x2000_0000, .size = 0x40, .writable = true },
        },
    }, &images);
    try std.testing.expectEqual(@as(usize, 1), images.asked);
    try std.testing.expectEqual(@as(?u32, 0x0403_0201), r.peek(4, 0x0800_0000));
    try std.testing.expectEqual(@as(?u32, 0x0403_0201), r.peek(4, 0));
    try std.testing.expectEqual(@as(?u32, 0), r.peek(4, 0x0800_0004));
    try std.testing.expectEqual(@as(?void, null), r.poke(4, 0, 9));
    try std.testing.expectEqual(@as(?void, {}), r.poke(4, 0x2000_0000, 9));
}

test "a device in the map is built by the model the registry names, and answers at its own base" {
    var buffer: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var images: Images = .{};
    var r = try built(fixed.allocator(), .{
        .core = .m4,
        .regions = &.{.{ .base = 0x2000_0000, .size = 0x40, .writable = true }},
        .devices = &.{.{ .base = 0x4000_0000, .size = 0x400, .model = "ticker" }},
    }, &images);
    ticks = 0;
    try std.testing.expectEqual(@as(?u32, 1), r.peek(4, 0x4000_0000));
    try std.testing.expectEqual(@as(?u32, 2), r.peek(4, 0x4000_0000));
    try std.testing.expectEqual(@as(?void, {}), r.poke(4, 0x4000_0000, 40));
    try std.testing.expectEqual(@as(?u32, 41), r.peek(4, 0x4000_0000));
    try std.testing.expectEqual(@as(?u32, null), r.peek(4, 0x4000_0004));
    try std.testing.expectEqual(@as(?void, {}), r.poke(4, 0x2000_0000, 9));
}

test "a device the registry does not name is refused, and so is a missing image, an oversized one, and regions that collide" {
    var buffer: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var images: Images = .{ .named = &.{.{ .name = "big.bin", .bytes = &.{ 1, 2, 3, 4, 5, 6, 7, 8 } }} };
    const ram: map.Region = .{ .base = 0x2000_0000, .size = 0x40, .writable = true };
    try std.testing.expectError(error.UnknownModel, built(fixed.allocator(), .{
        .core = .m4,
        .regions = &.{ram},
        .devices = &.{.{ .base = 0x4000_0000, .size = 0x400, .model = "uart" }},
    }, &images));
    try std.testing.expectError(error.Missing, built(fixed.allocator(), .{
        .core = .m4,
        .regions = &.{.{ .base = 0, .size = 0x40, .image = "absent.bin", .writable = false }},
    }, &images));
    try std.testing.expectError(error.TooLarge, built(fixed.allocator(), .{
        .core = .m4,
        .regions = &.{.{ .base = 0, .size = 4, .image = "big.bin", .writable = false }},
    }, &images));
    try std.testing.expectError(error.Overlaps, built(fixed.allocator(), .{
        .core = .m4,
        .regions = &.{ ram, .{ .base = 0x2000_0020, .size = 0x40, .writable = true } },
    }, &images));
    try std.testing.expectError(error.Overlaps, built(fixed.allocator(), .{
        .core = .m4,
        .regions = &.{ram},
        .devices = &.{.{ .base = 0x2000_0020, .size = 0x400, .model = "ticker" }},
    }, &images));
}

test "the name and base of whatever the map builder refused are left behind to report" {
    var buffer: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var images: Images = .{};
    var blame: map.Blame = .{};
    try std.testing.expectError(error.UnknownModel, map.build(fixed.allocator(), registry, .{
        .core = .m4,
        .regions = &.{.{ .base = 0, .size = 0x40, .writable = true }},
        .devices = &.{.{ .base = 0x4000_0000, .size = 0x400, .model = "uart" }},
    }, &images, &blame));
    try std.testing.expectEqualStrings("uart", blame.name);
    try std.testing.expectEqual(@as(u32, 0x4000_0000), blame.base);
}

test "the region the map builder was adding when the map turned out to overlap is left behind to report" {
    var buffer: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var images: Images = .{};
    var blame: map.Blame = .{};
    try std.testing.expectError(error.Overlaps, map.build(fixed.allocator(), registry, .{
        .core = .m4,
        .regions = &.{ .{ .base = 0, .size = 0x40, .writable = true }, .{ .base = 0x20, .size = 0x40, .writable = true } },
    }, &images, &blame));
    try std.testing.expectEqual(@as(u32, 0x20), blame.base);
    try std.testing.expectEqual(@as(u32, 0x40), blame.size);
}

test "the region blamed for an overlap is the later one by address, whichever order the map listed them in" {
    var buffer: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var images: Images = .{};
    var blame: map.Blame = .{};
    try std.testing.expectError(error.Overlaps, map.build(fixed.allocator(), registry, .{
        .core = .m4,
        .regions = &.{ .{ .base = 0x20, .size = 0x40, .writable = true }, .{ .base = 0, .size = 0x40, .writable = true } },
    }, &images, &blame));
    try std.testing.expectEqual(@as(u32, 0x20), blame.base);
    try std.testing.expectEqual(@as(u32, 0x40), blame.size);
}

test "every fault the map builder can report has a message of its own" {
    var seen: std.EnumSet(enum { missing, too_large, unknown, empty, wraps, overlaps, memory }) = .initEmpty();
    inline for (@typeInfo(map.Fault).error_set.?) |e| {
        const text = map.message(@field(anyerror, e.name));
        try std.testing.expect(text.len > 0);
        seen.insert(switch (@field(map.Fault, e.name)) {
            error.Missing => .missing,
            error.TooLarge => .too_large,
            error.UnknownModel => .unknown,
            error.Empty => .empty,
            error.Wraps => .wraps,
            error.Overlaps => .overlaps,
            error.OutOfMemory => .memory,
        });
    }
    try std.testing.expect(seen.count() == 7);
}
