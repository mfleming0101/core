# Embedding the library

For a reader who wants to run firmware on a core inside their own program. The
[README](README.md) says what the library is; [DESIGN.md](DESIGN.md) says how it is built.
Every fragment below has a runnable counterpart under [`examples/`](examples/).

```zig
const core = @import("core");
```

| Export | What |
|---|---|
| `core.arm`, `core.riscv` | `Processor`, `Options`, `Step`, `Run`, `Limit`, `Ended`, `Stop`, `Core`, `spec`, `trace`, `semihosting`, and `decode` from `isa` |
| `core.memory` | `Regions`, `Device`, `Width`, `Line`, `Lines`, `Clock`, `map`, `elf` |
| `core.trace` | `Ring`, the record ring both families instantiate |
| `core.contract` | `Kind`, `Access`, `Failure`, `Word`: the vocabulary a bus is reached with |
| `core.Core`, `core.Family`, `core.familyOf` | Every core of both families in one enum, and which family a core belongs to |

## What you bring

### A core

A `core.arm.Core` (`m0`, `m0plus`, `m1`, `m3`, `m4`, `m7`, `m23`, `m33`, `m55`, `m85`) or a
`core.riscv.Core` (`esp32c3`, `esp32c6`).

`core.arm.spec(.m4)` is the table a core is built from:

- Arm: architecture, the cycle counts per instruction class its Technical Reference Manual
  publishes, exception entry and exit cycles, priority bits, CPUID, reset CCR, and which of
  the Security, floating-point, MVE and PACBTI extensions it has.
- RISC-V: instruction groups, reset PC, flat memory layout, CSR implementation, interrupt
  matrix layout and PMP priority rule.

### A bus

The type the processor reads and writes through. `core.memory.Regions` is the one the library
ships ([below](#the-bus)). Any type with these members works:

| Member | What the processor asks |
|---|---|
| `lookup(address) Found` | The block an address falls in: base, length, host pointer if memory backs it, whether it is writable, and the index of the device if one answers |
| `folded: Folded` | The three-lane cache of the last block answered for fetch, read and write |
| `peek(bytes, address) ?Word`, `poke(bytes, address, value) ?void` | One access of one, two or four bytes; `null` where nothing answers |
| `parcel(address) ?u16` | One halfword of code |
| `follow(clock, attention)`, `untilDue()`, `interrupts() ?Lines`, `asserted() Lines` | The device schedule: the cycle counter to follow, cycles until a device is due, lines raised since the last call, lines held high now |

### A trace ring, or none

`core.arm.trace.Ring` and `core.riscv.trace.Ring` are `core.trace.Ring` over the family's
record. `Ring.init(records)` takes a slice whose length is a power of two, else
`error.NotPowerOfTwo`. `.{}` is a ring that records nothing and costs nothing on the
instruction path. See [Tracing](#tracing).

## The processor

### Building the type

```zig
const Cpu = core.arm.Processor(.{ .cores = &.{.m0plus}, .Bus = core.memory.Regions });
var cpu = Cpu.init(&board.memory, .m0plus, .{}, .{});
```

- `cores` lists every core the type must run as. The decode tree holds only the rows those
  cores need, so a one-core build is the smallest and fastest. There is no default.
- `init` takes the bus, the core and the trace ring, and leaves the core at reset. On Arm the
  stack pointer and entry come from the vector table at address 0, so memory must be loaded
  first. On RISC-V the PC is the part's reset address.
- On Arm, `init` also takes the part after the core: what the part was built with, which the
  core leaves to it. That is the cache sizes, and on the M7 also the TCM and AHBP sizes and
  reset enables and whether the caches carry ECC. It is also the MPU region count of each
  Security state, `mpu_regions` and `mpu_ns_regions`, the SAU region count `sau_regions`, the
  `priority_bits` and the number of external `interrupts`, each lowered to a value the core's
  TRM lists or clamped to its range. Left null, the core keeps its default: 8 MPU and SAU
  regions, or no MPU on the M0 and M1; 2 priority bits on the M0, M0+, M1 and M23, 4 on the
  rest; and 32 interrupts on the M0, M0+ and M1 and 240 on the rest, which is also the most
  any core but the M33, M55 and M85 may have; those three take up to 480. On the M55 and M85
  it is also `revidr`, the REVIDRNUM the part ties off, which REVIDR reads. On the M7, M23,
  M33, M55 and M85 it is also `vtor` and `vtor_ns`, the vector tables VTOR and VTOR_NS reset
  to, which the core resets out of; the rest reset VTOR to zero. An M7 given
  `.{ .data = .kb32, .instruction = .kb32, .itcm = .{ .size = .kb64, .enabled = true } }`
  reports those, `.{}` is a part with none of them, and a core without the registers a field
  sets ignores that field.
- `reset()` returns a running core to that state, as an Arm SYSRESETREQ does.

### Running

```zig
const ran = cpu.run(.{ .instructions = 10_000 });
```

| `Run.ended` | Meaning | `Run.stop` |
|---|---|---|
| `.budget` | `Limit.instructions` retired | `null` |
| `.deadline` | The cycle counter reached `Limit.cycles` | `null` |
| `.stopped` | The core cannot continue | The `Stop` |

`Run.instructions` and `Run.cycles` count this run; `cpu.instructions` and `cpu.cycles` are
totals. The Arm `Run` also carries `latency`, the cycles spent in exception entry and return.

### Stops

A stopped core stays stopped: `cpu.stop` holds the reason and later runs do nothing. The
exception is a breakpoint, `BKPT` or `EBREAK`: the next `run` or `step` continues past it.

The stops are `isa`'s, re-exported as `core.arm.Stop` and `core.riscv.Stop`:

| Family | Stops | Rule |
|---|---|---|
| Arm | `breakpoint`, `undefined_instruction`, `unimplemented`, `not_t32_state`, `fetch_fault`, `data_fault`, `unaligned_access`, `divide_by_zero`, `no_coprocessor`, `authentication_failure`, `not_branch_target`, `exception_return`, `unrecoverable_exception`, `secure_fault`, `fetch_violation`, `data_violation`, `tail_predication` | A fault the core can handle is not a stop: it enters the handler and runs on. A fault with no handler, or one taken already in HardFault, is a lockup and the stop names the original fault |
| RISC-V | `breakpoint`, `unimplemented`, `unrecoverable_trap` | Every trap is taken through `mtvec`. A trap raised at the trap vector itself, so the handler cannot begin, is unrecoverable |

### Stepping

```zig
const one = cpu.step();
```

`step` runs one instruction, or one exception entry when one is due:

| `Step` field | What |
|---|---|
| `address` | The PC the step began at |
| `class` | The instruction's class from `isa`; `null` for an exception entry, a return or nothing (asleep, stopped) |
| `cost` | What the core's published cycle table charges the class; `null` on a core with no table (M1, M7, M33, M55, M85, both ESP32s) |
| `charged` | Cycles added to `cpu.cycles`: the cost plus any entry or return overhead |
| `sequential` | Whether the fetch followed the previous instruction, for a prefetch model |
| `asleep` | The core is in WFI or WFE and nothing woke it |
| `stop` | The standing stop, if any |

`cpu.charge(cycles)` adds cycles the caller's own timing model decided on, such as wait states,
and services the clock the way a run does.

### Interrupt lines

Devices on a `Regions` bus raise lines themselves. Devices outside the bus pend them directly:

| Call | What |
|---|---|
| `pend(line)` | One line: an Arm IRQ number or a RISC-V interrupt matrix source |
| `pendAll(mask)` | A `Lines` mask, one bit per line |
| `enabled(line)` | Arm: the NVIC enable bit is set. RISC-V: the source is routed, unmasked and above the threshold |

On the bus and on RISC-V, `Line` is a `u8` and `Lines` a `u240`. An Arm `Processor` type
takes a `u9` line and has its own `Lines`, with `Set`, `one` and `ns_base` over the exception
numbers beside it: a `u240` where its cores carry at most 240 external interrupts, and a
`u480` where one of them is an M33, M55 or M85. A bus device raises the first 240; `pend`,
`pendAll`, NVIC_ISPR and STIR reach the rest. A line beyond the part's `interrupts` never
pends; the ESP32-C3 has 62 matrix sources and the C6 77.

### Peek and poke

`cpu.peek(4, address)` and `cpu.poke(2, address, value)` read and write one, two or four bytes
through the path the core's own loads and stores take: the bus, the private peripheral bus on
Arm or the interrupt controller on RISC-V, and the protection units as the core's current
privilege and security state see them. Both answer `null` where nothing answers or the access
is refused. Neither raises a fault.

### Explaining a stop

```zig
try cpu.explain(writer, 4);
```

Prints why the core is where it is:

1. The stop, and the last four trace records if a ring is attached.
2. The fault, with the address or code that caused it and the manual's reason.
3. The status registers: CFSR, HFSR, MMFAR, BFAR on Arm; mtvec, mcause, mepc, mtval on RISC-V.
4. On Arm, any interrupt that is pending but can never be taken.

## The bus

### Regions

A sorted array of entries the caller owns:

```zig
var entries = [_]core.memory.Regions.Entry{
    .{ .memory = .{ .base = 0, .bytes = &flash, .writable = false } },
    .{ .memory = .{ .base = 0x2000_0000, .bytes = &ram, .writable = true } },
    .{ .device = .{ .base = 0x4001_0000, .size = 0x100, .device = timer.device() } },
};
var memory = try core.memory.Regions.adopt(&entries);
```

- `adopt` sorts the slice in place and keeps it, so the array must outlive the `Regions`.
- It refuses an entry with no size, one past the end of the address space, or two that overlap
  (`Malformed`).
- A memory entry is a byte slice at a base; the same slice at two bases is two entries.
- An address no entry covers answers nothing, which the core reports as a bus or access fault.

### Devices

A context pointer and three functions, plus an optional fourth:

```zig
pub const Device = struct {
    context: *anyopaque,
    read: *const fn (context, offset: u32, width: Width, raise: *Lines) ?u32,
    write: *const fn (context, offset: u32, width: Width, value: u32, raise: *Lines) ?void,
    tick: ?*const fn (context, cycles: u32, raise: *Lines) ?u32 = null,
    asserted: ?*const fn (context) Lines = null,
};
```

| Function | Contract |
|---|---|
| `read`, `write` | Take the offset from the device's base and the width (`byte`, `half`, `word`). `null` for an offset or width the device lacks, which the core takes as a fault |
| `tick` | Called with the cycles elapsed since the last call. Answers cycles until the next call, zero for the next cycle, `null` for none. Also called with zero cycles after every write, so a register write can arm or disarm a timer |
| `asserted` | The lines the device holds high now, for level-sensitive interrupts |

Any function may set bits in `raise` to pend those lines. The bus follows the processor's cycle
counter: `run`, `step` and `charge` service the devices that are due, collect the lines they
raised and pend them. Nothing needs calling between runs.

### Maps in `.zon`

The same bus written as data:

```zig
.{
    .core = .m3,
    .regions = .{
        .{ .base = 0x00000000, .size = 0x100000, .writable = false, .image = "firmware.bin" },
        .{ .base = 0x20000000, .size = 0x10000, .writable = true },
    },
    .devices = .{
        .{ .model = "timer", .base = 0x40010000, .size = 0x100 },
    },
}
```

Parse it with `std.zon.parse` into `core.memory.map.Map`, then build it:

```zig
var blame: core.memory.map.Blame = .{};
var memory = try core.memory.map.build(arena, registry, map, &images, &blame);
```

- `registry` names the device models the program has, each a `make(arena)` returning a
  `Device`.
- `images` is anything with `load(name, bytes) !usize` that fills a region from a named image.
- A region may carry an `alias`, a second base the same bytes answer at.
- On failure `blame` names the region or device and `map.message(fault)` says why.

### Loading an ELF

```zig
try core.memory.elf.load(firmware, &memory);
```

Copies every `PT_LOAD` segment of a 32-bit little-endian Arm or RISC-V executable into the
memory covering its physical address and zero-fills the rest of each segment. Works on any type
with `place(address, bytes, size) bool`. `elf.message(failure)` says why a load failed.

### The clock

`core.memory.Clock.at(hz)` converts cycles to picoseconds and back, for a caller running the
core against wall time or another clock. `charge(cycles)` advances it, `cyclesTo(ps)` answers
how many cycles reach a time, and `bank(hz)` changes the frequency keeping the time spent. The
processor counts cycles itself and never consults it.

## Tracing

With a ring attached, every retired instruction, exception entry, interrupt entry and return
writes one record: PC, code, the cycle the instruction began at, the registers it changed with
their new values, the data address it touched, and a note saying which of the four it was, with
the entry's number and latency.

```zig
var records: [16]core.arm.trace.Record = undefined;
var cpu = Cpu.init(&board.memory, .m0plus, .{}, try .init(&records));
_ = cpu.run(.{ .instructions = 10_000 });
try core.arm.trace.writeLast(&out, &cpu.trace, 2, cpu.groups());
```

```
at    741  pc=00000036 code=43c0 mvns r0, r0 ; r0=cbf43926 xpsr=a1000000
at    742  pc=00000038 code=be00 bkpt #0
at    431  pc=00000130 code=---- ; sp=20000fe0 lr=fffffff9 xpsr=01000021 irq=17 latency=15
at    461  pc=0000012e code=---- ; return latency=10
```

- `ring.last()` and `ring.at(back)` read records; `ring.written` counts every record ever
  written, of which the last `records.len` are held.
- `writeLine` renders one record.
- `trace.register_names` (r0 to r12, sp, lr, xpsr on Arm; ra to t6 on RISC-V) index
  `Record.values` and the bits of `Record.changed`.

A run with a ring takes a separate copy of the loop, so a run without one pays nothing.

## Semihosting

The Arm `BKPT 0xAB`, and the RISC-V `EBREAK` between its two marker `slli`/`srai`
instructions, stop the core like any breakpoint. `Cpu.semihosting` recognises them:

```zig
if (Cpu.semihosting.trapped(&cpu)) {
    if (try Cpu.semihosting.call(&cpu, console)) |exit| return exit.status;
}
```

- `trapped` says whether the standing breakpoint is a semihosting call.
- `call` performs it, writes the result register, and answers the exit status when the call
  was `SYS_EXIT`. The next `run` continues past the breakpoint.
- Answered: `SYS_OPEN` of `:tt`, `SYS_CLOSE`, `SYS_WRITEC`, `SYS_WRITE0`, `SYS_WRITE`,
  `SYS_ISTTY`, `SYS_EXIT`, `SYS_EXIT_EXTENDED`. Enough for `printf` over the console; anything
  else answers failure.

## The two families side by side

| | Arm | RISC-V |
|---|---|---|
| Exceptions | NVIC with priorities, grouping, banking and the Security Extension; SysTick; SVCall and PendSV; faults through CFSR and friends | Machine-mode traps through `mtvec`; the interrupt matrix routes sources to interrupts with priorities and a threshold |
| Protection | MPU with the part's regions per security state, 8 by default; SAU with the part's regions, 8 by default | PMP with 16 entries |
| Private registers | The private peripheral bus at `0xE000_0000`: SysTick, NVIC, SCB, MPU, SAU, DWT | The interrupt matrix and controller windows of the part |
| `Run.latency` | Present | Absent |
| Sleep | `WFI` and `WFE`, with `SEV` and the event register | `WFI` |
| Semihosting trap | `BKPT 0xAB` | `EBREAK` between the two marker instructions |
