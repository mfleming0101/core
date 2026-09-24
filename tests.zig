comptime {
    _ = @import("test/arm/semihosting_test.zig");
    _ = @import("test/arm/system/dwt_test.zig");
    _ = @import("test/arm/system/mpu_test.zig");
    _ = @import("test/arm/system/nvic_test.zig");
    _ = @import("test/arm/system/ppb_test.zig");
    _ = @import("test/arm/system/processor_test.zig");
    _ = @import("test/arm/system/sau_test.zig");
    _ = @import("test/arm/system/scb_test.zig");
    _ = @import("test/arm/system/systick_test.zig");
    _ = @import("test/arm/trace_test.zig");
    _ = @import("test/memory/clock_test.zig");
    _ = @import("test/memory/map_test.zig");
    _ = @import("test/memory/regions_test.zig");
    _ = @import("test/riscv/semihosting_test.zig");
    _ = @import("test/riscv/system/intc_test.zig");
    _ = @import("test/riscv/system/pmp_test.zig");
    _ = @import("test/riscv/system/processor_test.zig");
    _ = @import("test/riscv/trace_test.zig");
}
