const std = @import("std");
const core = @import("core");

const Lines = core.memory.Lines;
const Width = core.memory.Width;

pub const registry: core.memory.map.Registry = .{ .models = &.{
    .{ .name = "probe-timer", .make = Timer.make },
} };

const at = struct {
    const ctrl: u32 = 0x00;
    const reload: u32 = 0x04;
    const count: u32 = 0x08;
    const status: u32 = 0x0c;
    const line: u32 = 0x10;
    const data: u32 = 0x14;
};

const Timer = struct {
    ctrl: u32 = 0,
    reload: u32 = 0,
    count: u32 = 0,
    status: u32 = 0,
    line: u8 = 0,
    data: u32 = 0,

    const enable: u32 = 1 << 0;
    const auto: u32 = 1 << 1;
    const raised: u32 = 1 << 0;

    fn read(context: *anyopaque, offset: u32, _: Width, _: *Lines) ?u32 {
        const self: *Timer = @ptrCast(@alignCast(context));
        return switch (offset & ~@as(u32, 3)) {
            at.ctrl => self.ctrl,
            at.reload => self.reload,
            at.count => self.count,
            at.status => self.status,
            at.line => self.line,
            at.data => self.data,
            else => 0,
        };
    }

    fn write(context: *anyopaque, offset: u32, _: Width, value: u32, _: *Lines) ?void {
        const self: *Timer = @ptrCast(@alignCast(context));
        switch (offset & ~@as(u32, 3)) {
            at.ctrl => {
                self.ctrl = value & (enable | auto);
                self.count = self.reload;
            },
            at.reload => {
                self.reload = value;
                self.count = value;
            },
            at.status => if (value & raised != 0) {
                self.status &= ~raised;
            },
            at.line => if (value < @bitSizeOf(Lines)) {
                self.line = @intCast(value);
            },
            at.data => self.data = value,
            else => {},
        }
    }

    fn tick(context: *anyopaque, cycles: u32, raise: *Lines) ?u32 {
        const self: *Timer = @ptrCast(@alignCast(context));
        if (self.ctrl & enable == 0 or self.reload == 0) return null;
        if (cycles < self.count) {
            self.count -= cycles;
            return self.count;
        }
        self.status |= raised;
        self.data +%= 1;
        raise.* |= @as(Lines, 1) << self.line;
        if (self.ctrl & auto == 0) {
            self.ctrl &= ~enable;
            self.count = 0;
            return null;
        }
        self.count = self.reload - (cycles - self.count) % self.reload;
        return self.count;
    }

    fn asserted(context: *anyopaque) Lines {
        const self: *const Timer = @ptrCast(@alignCast(context));
        if (self.status & raised == 0) return 0;
        return @as(Lines, 1) << self.line;
    }

    fn make(arena: std.mem.Allocator) std.mem.Allocator.Error!core.memory.Device {
        const self = try arena.create(Timer);
        self.* = .{};
        return .{ .context = self, .read = read, .write = write, .tick = tick, .asserted = asserted };
    }
};

pub const Event = struct {
    at: u64,
    unit: u8,
    kind: Kind,
    offset: u32,
    value: u32,

    pub const Kind = enum { read, write, raise };
};

pub const events = struct {
    pub const units_max = 32;

    const Unit = struct { model: usize = 0 };

    var ring: core.trace.Ring(Event) = .{};
    var clock: ?*const u64 = null;
    var units: [units_max]Unit = @splat(.{});
    var made: u8 = 0;

    pub fn open(records: []Event) core.trace.Ring(Event).Misshapen!void {
        ring = try .init(records);
        made = 0;
    }

    pub fn follow(cycles: *const u64) void {
        clock = cycles;
    }

    pub fn count() u64 {
        return @min(ring.written, ring.records.len);
    }

    pub fn at(back: u64) ?Event {
        return ring.at(back);
    }

    pub fn nameOf(unit: u8) []const u8 {
        return registry.models[units[unit].model].name;
    }

    pub fn registerOf(unit: u8, offset: u32) ?[]const u8 {
        if (units[unit].model != 0) return null;
        const which = offset / 4;
        return if (which < timer_registers.len) timer_registers[which] else null;
    }

    fn named(model: usize) u8 {
        if (made == units_max) return units_max - 1;
        units[made] = .{ .model = model };
        made += 1;
        return made - 1;
    }

    fn log(unit: u8, kind: Event.Kind, offset: u32, value: u32) void {
        if (!ring.recording()) return;
        ring.reserve().* = .{ .at = if (clock) |c| c.* else 0, .unit = unit, .kind = kind, .offset = offset, .value = value };
    }

    fn raised(unit: u8, before: Lines, after: Lines) void {
        var fresh = after & ~before;
        while (fresh != 0) : (fresh &= fresh - 1) {
            log(unit, .raise, 0, @ctz(fresh));
        }
    }
};

const timer_registers = [_][]const u8{ "ctrl", "reload", "count", "status", "line", "data" };

pub const watching: core.memory.map.Registry = .{ .models = &watched };

const watched = blk: {
    var out: [registry.models.len]core.memory.map.Registry.Model = undefined;
    for (registry.models, 0..) |model, i| out[i] = .{ .name = model.name, .make = Watch(i).make };
    break :blk out;
};

fn Watch(comptime i: usize) type {
    return struct {
        fn make(arena: std.mem.Allocator) std.mem.Allocator.Error!core.memory.Device {
            const inner = try registry.models[i].make(arena);
            const self = try arena.create(Watched);
            self.* = .{ .inner = inner, .unit = events.named(i) };
            return .{
                .context = self,
                .read = Watched.read,
                .write = Watched.write,
                .tick = if (inner.tick != null) Watched.tick else null,
                .asserted = if (inner.asserted != null) Watched.asserted else null,
            };
        }
    };
}

const Watched = struct {
    inner: core.memory.Device,
    unit: u8,

    fn read(context: *anyopaque, offset: u32, width: Width, raise: *Lines) ?u32 {
        const self: *Watched = @ptrCast(@alignCast(context));
        const before = raise.*;
        const value = self.inner.read(self.inner.context, offset, width, raise);
        events.log(self.unit, .read, offset, value orelse 0);
        events.raised(self.unit, before, raise.*);
        return value;
    }

    fn write(context: *anyopaque, offset: u32, width: Width, value: u32, raise: *Lines) ?void {
        const self: *Watched = @ptrCast(@alignCast(context));
        const before = raise.*;
        self.inner.write(self.inner.context, offset, width, value, raise) orelse return null;
        events.log(self.unit, .write, offset, value);
        events.raised(self.unit, before, raise.*);
    }

    fn tick(context: *anyopaque, cycles: u32, raise: *Lines) ?u32 {
        const self: *Watched = @ptrCast(@alignCast(context));
        const before = raise.*;
        const next = self.inner.tick.?(self.inner.context, cycles, raise);
        events.raised(self.unit, before, raise.*);
        return next;
    }

    fn asserted(context: *anyopaque) Lines {
        const self: *const Watched = @ptrCast(@alignCast(context));
        return self.inner.asserted.?(self.inner.context);
    }
};
