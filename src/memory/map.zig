//! A board written as data, and the builder that turns one into a bus. A Map names the core,
//! the regions with the images that fill them, and the devices by model name; build allocates
//! the bytes over an arena, loads each image, makes each device out of the caller's registry
//! and adopts the result. The corpus keeps its maps as .zon files read straight into a Map.
const std = @import("std");
const regions = @import("regions.zig");
const Regions = regions.Regions;
const Core = @import("../family.zig").Core;

/// One board as data: the core it carries, its regions and devices, and the ELF to run.
pub const Map = struct {
    core: Core,
    regions: []const Region = &.{},
    devices: []const Device = &.{},
    elf: ?[]const u8 = null,
};

/// A request for one block of memory: where, how big, what fills it and where else it answers.
pub const Region = struct {
    base: u32,
    size: u32,
    image: ?[]const u8 = null,
    alias: ?u32 = null,
    writable: bool,
};

/// A request for one device by model name, at a base and size.
pub const Device = struct {
    base: u32,
    size: u32,
    model: []const u8,
};

/// The device models a program has built in, each able to make one over an arena.
pub const Registry = struct {
    models: []const Model = &.{},

    /// One model: the name a map asks for it by, and how to build it.
    pub const Model = struct {
        name: []const u8,
        make: *const fn (arena: std.mem.Allocator) std.mem.Allocator.Error!regions.Device,
    };

    /// The model of that name, or null.
    pub fn find(self: Registry, name: []const u8) ?Model {
        for (self.models) |model| {
            if (std.mem.eql(u8, model.name, name)) return model;
        }
        return null;
    }
};

/// The two ways a named image can fail to fill its region.
pub const Image = error{ Missing, TooLarge };

/// Everything building a map can fail with.
pub const Fault = Image || Regions.Malformed || error{ UnknownModel, OutOfMemory };

/// Which region or device the builder was on when it failed, left behind for the caller.
pub const Blame = struct { name: []const u8 = "", base: u32 = 0, size: u32 = 0 };

fn named(map: Map, base: u32, size: u32) Blame {
    for (map.regions) |region| {
        if (region.base == base or region.alias == base) return .{ .name = region.image orelse "", .base = base, .size = size };
    }
    for (map.devices) |device| {
        if (device.base == base) return .{ .name = device.model, .base = base, .size = size };
    }
    return .{ .base = base, .size = size };
}

/// Builds the map into Regions over the arena, loading each image and making each device.
pub fn build(arena: std.mem.Allocator, registry: Registry, map: Map, images: anytype, blame: *Blame) Fault!Regions {
    var count: usize = map.devices.len;
    for (map.regions) |region| count += if (region.alias == null) 1 else 2;
    const entries = try arena.alloc(Regions.Entry, count);
    var next: usize = 0;
    for (map.regions) |region| {
        blame.* = .{ .name = region.image orelse "", .base = region.base, .size = region.size };
        const bytes = try arena.alloc(u8, region.size);
        @memset(bytes, 0);
        if (region.image) |image| {
            const read = try images.load(image, bytes);
            std.debug.assert(read <= bytes.len);
        }
        entries[next] = .{ .memory = .{ .base = region.base, .bytes = bytes, .writable = region.writable } };
        next += 1;
        if (region.alias) |at| {
            entries[next] = .{ .memory = .{ .base = at, .bytes = bytes, .writable = region.writable } };
            next += 1;
        }
    }
    for (map.devices) |device| {
        blame.* = .{ .name = device.model, .base = device.base, .size = device.size };
        const model = registry.find(device.model) orelse return error.UnknownModel;
        entries[next] = .{ .device = .{ .base = device.base, .size = device.size, .device = try model.make(arena) } };
        next += 1;
    }
    const built = Regions.adopt(entries) catch |err| {
        if (Regions.culprit(entries)) |at| blame.* = named(map, at.base, at.size);
        return err;
    };
    blame.* = .{};
    return built;
}

/// The sentence a fault is reported to a user as.
pub fn message(fault: Fault) []const u8 {
    return switch (fault) {
        error.Missing => "cannot read the image",
        error.TooLarge => "the image does not fit the region",
        error.UnknownModel => "no device model of that name is built in",
        error.Empty => "the region has no size",
        error.Wraps => "the region runs past the end of the address space",
        error.Overlaps => "the region covers an address another already covers",
        error.OutOfMemory => "out of memory",
    };
}
