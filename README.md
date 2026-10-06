# core

A Zig library that runs Arm Cortex-M and RISC-V firmware on the host: the processor, its system
peripherals, and a bus you fill with memory and devices. Instructions execute through
[`isa`](https://github.com/mfleming0101/isa).

## Features

- Cortex-M0, M0+, M1, M3, M4, M7, M23, M33, M55, M85; ESP32-C3 and ESP32-C6.
- M0+, M4 and M7 cycle counts fitted to board measurements.
- Exceptions, NVIC, SysTick, MPU, SAU, DWT, PMP, semihosting and DEMCR vector catch.
- `explain` turns a stop into the fault, its status registers and the last instructions run.
- A device is a context with read, write and tick.

## Example

```zig
const Cpu = core.arm.Processor(.{ .cores = &.{.m0plus}, .Bus = core.memory.Regions });

var memory = try core.memory.Regions.adopt(&entries);
try core.memory.elf.load(firmware, &memory);
var cpu = Cpu.init(&memory, .m0plus, .{}, .{});
const ran = cpu.run(.{ .instructions = 10_000 });
try std.testing.expectEqual(@as(?core.arm.Stop, .breakpoint), ran.stop);
```

[`examples/`](examples/) holds more; `zig build examples` runs them.

## Install

Requires Zig 0.16.0.

```sh
zig fetch --save "git+https://github.com/mfleming0101/core.git?ref=v0.7.0"
```

```zig
const core = b.dependency("core", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("core", core.module("core"));
```
