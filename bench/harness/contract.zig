pub const Requirement = struct {
    name: [:0]const u8,
    Signature: type,
    optional: bool = false,
    why: []const u8,
};

pub fn required(comptime reqs: []const Requirement) usize {
    comptime {
        var n: usize = 0;
        for (reqs) |r| n += @intFromBool(!r.optional);
        return n;
    }
}

pub fn optional(comptime reqs: []const Requirement) usize {
    comptime {
        var n: usize = 0;
        for (reqs) |r| n += @intFromBool(r.optional);
        return n;
    }
}
