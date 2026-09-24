# core

`core` is a Zig library that runs firmware for small embedded cores on the host: the
processor, its system peripherals, and a bus the caller fills with memory and devices.
Instructions execute through the [`isa`](https://github.com/mfleming0101/isa) library;
`core` adds everything a program needs around them.

## Cores

| Family | Cores | Modelled |
|---|---|---|
| Arm | Cortex-M0, M0+, M1, M3, M4, M7, M23, M33, M55, M85 | Exception entry and return, NVIC, SysTick, SCB, MPU, SAU and the Security Extension, DWT, the cycle tables each Technical Reference Manual publishes, semihosting |
| RISC-V | Espressif ESP32-C3 (RV32IMC), ESP32-C6 (RV32IMAC) | Machine-mode traps, the interrupt matrix and controller, PMP, semihosting |

The library is checked against QEMU, the Sail RISC-V model, Espressif's QEMU fork and a corpus
of 67 firmware images in a [container](Dockerfile) pinned by digest.

## Key features

### 1. Firmware runs and tests on the host

No board, no debugger. Load the ELF, fill a bus with memory and your own devices, and run to a
breakpoint, a semihosting exit, an instruction budget or a cycle deadline. A firmware test is an
ordinary `zig build test` that finishes in milliseconds, so it can gate every commit.

- [`run_arm.zig`](examples/run_arm.zig): a CRC-32 firmware runs to its breakpoint; the result
  is checked in r0.
- [`console.zig`](examples/console.zig): what the program prints over semihosting, and its
  exit status.
- [`first_program_arm.zig`](examples/first_program_arm.zig): the whole loop in three
  hand-encoded instructions.

### 2. A crash tells you why, in the manual's own words

On a board a HardFault is a lockup and a stack to reconstruct by hand. Here every stop keeps the
fault registers, the faulting access and the last instructions retired, and `explain` prints
them:

```
The core took a UsageFault at pc=000005ba as UsageFault: the access to 00201009 is not
aligned to its size and CCR.UNALIGN_TRP is set.
CFSR=01000000 (UNALIGNED) HFSR=00000000 MMFAR=00000000 BFAR=00000000
```

```
The hart took a trap at pc=0000038c: load access fault reaching 000003a4, which the PMP
refused: pmpcfg0=00001b1c.
mtvec=00000101 mcause=00000005 mepc=0000038c mtval=000003a4
```

The trace ring behind it is sized by the caller and costs nothing when off.

- [`crash.zig`](examples/crash.zig): a load from an address nothing answers locks a
  Cortex-M3 up, and `explain` says so.

### 3. Peripherals and interrupts, tested the same way

Driver and ISR code never gets unit-tested because it needs the hardware to raise the line.
Here a device is a context and three functions: read, write and tick. The bus clocks it, it
raises a line, and the NVIC or the interrupt matrix delivers the exception into the handler with
the vector table, priorities and masking the firmware configured. A UART, a DMA controller or a
timer in a few dozen lines of Zig puts the driver, its ISR and the sleep-and-wake path under
test on both families.

- [`timer_arm.zig`](examples/timer_arm.zig), [`timer_riscv.zig`](examples/timer_riscv.zig):
  one Zig timer device ([`timer_device.zig`](examples/timer_device.zig)) interrupts the core
  five times while the firmware sleeps in `WFI`.
- [`output_port.zig`](examples/output_port.zig): the smallest device there is.

## Examples

Each file under [`examples/`](examples/) is a test that `zig build examples` runs.

### Without a toolchain

A few hand-encoded instructions placed in memory.

| Example | Shows |
|---|---|
| [`first_program_arm.zig`](examples/first_program_arm.zig) | A vector table and three Thumb instructions; a Cortex-M0+ runs them to the breakpoint |
| [`first_program_riscv.zig`](examples/first_program_riscv.zig) | The same three instructions at the ESP32-C3 reset address |
| [`step_by_step.zig`](examples/step_by_step.zig) | `step` runs one instruction and reports its address, class, cost and whether it was sequential |
| [`budgets.zig`](examples/budgets.zig) | A run ends at its instruction budget, its cycle deadline or a breakpoint; the next run carries on |
| [`memory_map.zig`](examples/memory_map.zig) | Regions on a bus: `peek`, `poke`, an unmapped address, a read-only region, the overlap check in `adopt` |
| [`output_port.zig`](examples/output_port.zig) | One register whose stores come out as text on the host side |
| [`which_core.zig`](examples/which_core.zig) | One processor type built for three cores; the same program costs different cycles on each, and `spec` shows why |

### With a C firmware

Each runs a C file beside it, cross-compiled by `zig cc` during the build.

| Example | Shows |
|---|---|
| [`run_arm.zig`](examples/run_arm.zig) | A Cortex-M0+ runs a CRC-32 firmware from an ELF to its breakpoint; then the same run with a trace ring renders its last two records |
| [`run_riscv.zig`](examples/run_riscv.zig) | An ESP32-C3 leaves the same checksum in a0 |
| [`console.zig`](examples/console.zig) | A program prints over semihosting and exits with a status; the host loop that serves the calls |
| [`timer_arm.zig`](examples/timer_arm.zig) | A Zig timer device interrupts the core five times through the NVIC while the program sleeps in `WFI` |
| [`timer_riscv.zig`](examples/timer_riscv.zig) | The same device and firmware on an ESP32-C3, routed through the interrupt matrix |
| [`profile.zig`](examples/profile.zig) | Single-stepping attributes every cycle to an instruction class and finds the address that ran most |
| [`crash.zig`](examples/crash.zig) | A load from an address nothing answers locks a Cortex-M3 up; `explain` prints the fault, the last trace lines and the status registers |
| [`zon_map.zig`](examples/zon_map.zig) | The timer board described in `.zon` and built through a device registry |

## Building

### Tests

Requires Zig 0.16.0 and nothing else. The `isa` dependency is fetched by git URL and hash from
`build.zig.zon`.

```sh
zig build test        # unit and example tests
zig build examples    # the examples alone
```

### Container

The oracle comparisons, the firmware corpus and the timing bench run in a container image
pinned by digest. It clones `isa` at the pinned tag to build the shared corpus and needs no tool
but Zig inside.

```sh
docker build -t core .
docker run --rm core    # zig build harness && zig build metrics
```

`zig build metrics` prints one row: every correctness gate, nanoseconds per instruction over
the corpus with and without the system layers, the cost of a data access, the size of the
processor and the build times. The rows measured at each release are in
[bench/release-metrics.tsv](bench/release-metrics.tsv).

## Documentation

| Document | For |
|---|---|
| [INTERFACE.md](INTERFACE.md) | Embedding the library: the processor, the bus, devices, maps, ELF loading, tracing, semihosting, explaining a stop |
| [DESIGN.md](DESIGN.md) | How it is built: the layers between an instruction and the bus, the folded access path, scheduling, the tests and the container |
| [LIBRARY_GLOSSARY.md](LIBRARY_GLOSSARY.md) | One name per concept, for the library and for the Arm and RISC-V terms it leans on |

## Layout

| Path | What |
|---|---|
| `src/core.zig` | The module root: `arm`, `riscv`, `memory`, `trace`, `contract` and the `Core` enum |
| `src/arm/` | The Arm processor, its system blocks, its trace record and semihosting |
| `src/riscv/` | The RISC-V processor, the interrupt matrix, PMP, its trace record and semihosting |
| `src/memory/` | `Regions`, the device interface, the clock, the `.zon` map builder and the ELF loader |
| `src/trace/` | The record ring and the line renderer both families share |
| `src/contract.zig` | The access kinds, the failure set and the two helpers a bus is reached through |
| `test/` | The unit tests, mirroring `src/` |
| `examples/` | The runnable examples and the firmware they run |
| `bench/` | The measurement harness, the machines it drives, the stub host and the null ISA |
| `corpus/` | The system firmware sources, the diagnosis cases, the maps and the pinned manifest |
| `oracle/` | Pinned reference outputs and the scripts that regenerate them |
