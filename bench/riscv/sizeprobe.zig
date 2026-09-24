const harness = @import("harness");

comptime {
    harness.sizeprobe.attach(@import("machine.zig").Machine);
}
