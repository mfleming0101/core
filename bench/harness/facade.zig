const contract = @import("contract.zig");
const snapshot = @import("snapshot.zig");

pub const Arch = enum { armv7m, rv32imc };

pub const armv7m_reset = struct {
    pub const lr: u32 = 0xffff_ffff;
    pub const xpsr: u32 = 1 << 24 | 1 << 30;
};

pub const Ran = struct {
    retired: u64 = 0,
    cycles: u64 = 0,
    stop: snapshot.Stop = .running,
    exceptions: u64 = 0,
    irqs: u64 = 0,
    latency: u64 = 0,
};

pub fn assertMachine(comptime M: type) void {
    const wanted = .{
        .{ "arch", Arch },
        .{ "result_register", u5 },
        .{ "isa_provides", []const contract.Requirement },
        .{ "table_bytes", u64 },
        .{ "processor_bytes", u64 },
    };
    inline for (wanted) |w| {
        if (!@hasDecl(M, w[0])) @compileError(@typeName(M) ++ " is missing pub const " ++ w[0]);
        if (@TypeOf(@field(M, w[0])) != w[1]) @compileError(@typeName(M) ++ "." ++ w[0] ++ " must be " ++ @typeName(w[1]));
    }
    inline for (.{ "init", "run", "step", "burst", "snapshot", "trap", "read32", "explain", "clock" }) |name| {
        if (!@hasDecl(M, name)) @compileError(@typeName(M) ++ " is missing fn " ++ name);
    }
}
