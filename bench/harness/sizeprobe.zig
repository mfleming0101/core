const facade = @import("facade.zig");

pub fn attach(comptime M: type) void {
    comptime facade.assertMachine(M);

    const shim = struct {
        fn run(machine: *M, budget: u64) callconv(.c) u64 {
            const ran = machine.run(budget);
            return ran.retired << 8 | @intFromEnum(ran.stop);
        }

        fn explain(machine: *M, into: [*]u8, len: usize) callconv(.c) usize {
            return machine.explain(into[0..len]).len;
        }
    };

    @export(&shim.run, .{ .name = "machine_run" });
    @export(&shim.explain, .{ .name = "machine_explain" });
}
