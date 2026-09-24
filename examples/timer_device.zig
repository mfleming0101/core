const core = @import("core");

const Lines = core.memory.Lines;
const Width = core.memory.Width;

pub const Timer = struct {
    line: u8,
    enabled: bool = false,
    reload: u32 = 0,
    remaining: u32 = 0,
    raised: bool = false,
    fired: u32 = 0,

    pub fn device(self: *Timer) core.memory.Device {
        return .{ .context = self, .read = read, .write = write, .tick = tick };
    }

    fn read(context: *anyopaque, offset: u32, _: Width, _: *Lines) ?u32 {
        const self: *Timer = @ptrCast(@alignCast(context));
        return switch (offset) {
            0x0 => @intFromBool(self.enabled),
            0x4 => self.reload,
            0x8 => @intFromBool(self.raised),
            else => null,
        };
    }

    fn write(context: *anyopaque, offset: u32, _: Width, value: u32, _: *Lines) ?void {
        const self: *Timer = @ptrCast(@alignCast(context));
        switch (offset) {
            0x0 => {
                self.enabled = value & 1 != 0;
                self.remaining = self.reload;
            },
            0x4 => self.reload = value,
            0x8 => self.raised = false,
            else => return null,
        }
    }

    fn tick(context: *anyopaque, cycles: u32, raise: *Lines) ?u32 {
        const self: *Timer = @ptrCast(@alignCast(context));
        if (!self.enabled or self.reload == 0) return null;
        if (cycles < self.remaining) {
            self.remaining -= cycles;
            return self.remaining;
        }
        self.raised = true;
        self.fired += 1;
        raise.* |= @as(Lines, 1) << self.line;
        self.remaining = self.reload;
        return self.remaining;
    }
};
