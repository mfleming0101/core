# How the library is built

For a reader who wants to change the library or judge its claims. The [README](README.md) says
what it is; [INTERFACE.md](INTERFACE.md) says how to embed it.

## The pipeline

| Part | Where | Role |
|---|---|---|
| `isa` | dependency | Decodes and executes one instruction at a time; asks its host a fixed list of questions through a compile-time checked contract |
| `Processor` | `src/arm/system`, `src/riscv/system` | The host: answers from the core's system registers, owns the exceptions and the clock, reaches memory through the caller's bus |
| `Regions` | `src/memory` | The bus the library ships |
| bench, corpus, oracle | `bench/`, `corpus/`, `oracle/` | Measure the result; not part of the library |

## The access path

```
isa step loop           decode, execute, ask the host
  Processor             system registers, exceptions, the cycle counter
    contract.read/write the two helpers every access goes through
      Folded            three cached blocks: the last fetch, read and write answer
        describe        the block an address is in, narrowed by the protection units
          Bus.lookup    the caller's entries: memory bytes or a device
```

`isa` reaches memory through three host functions:

| Function | Answers |
|---|---|
| `span` | A byte slice the instruction may use directly |
| `access` | The slow lane, for anything a slice cannot answer |
| `touch` | The address a run of accesses began at, for the fault registers and the trace |

### The fast lane

`span` is answered from `Folded`: a subtract, a compare and a slice when the address is in the
last block answered for that kind of access, and an out-of-line refold when it is not.
Refolding asks `describe` for the block: the bus entry the address falls in, narrowed to the
edges of the private peripheral bus and, on Arm, the execute-never regions of the default map,
and narrowed again to the protection region covering the address, so a block never straddles a
permission change. A block no memory backs, or one a protection unit refuses, is published as a
refusal so the next access goes straight to the slow lane.

### The slow lane

`access` is where devices, the private peripheral bus and faults live. It asks the protection
units, then the device or system block that owns the address, and returns the failure the
instruction set stops for. `blamed` records which unit refused, so the fault can say so.

Both processors share the path through `Folded.reach`, passing their own `describe`. The same
`contract.read` and `contract.write` serve `peek`, `poke` and the vector table read, so a
debugger read sees what the core sees.

### The guard word

Most cores run with no protection unit enabled, so asking the MPU, SAU or PMP on every access
would be waste. The processor keeps:

- `guarding`: a word of the inputs that decide the answer, such as whether a unit is enabled,
  the privilege, the security state and the mask registers.
- `unguarded`: true when nothing can refuse.

`span` on an unguarded core never calls the unit. A write to any input recomputes both and
unfolds the cache.

## The processor

### What one core knows

`core.zig` in each family is a table, one entry per core, of what its Technical Reference Manual
says: architecture, exception entry and exit cycles, priority bits, id registers, reset CCR, extensions fitted, and for RISC-V the CSR
implementation, interrupt matrix layout and reset address.

`Processor(.{ .cores })` builds a table of these at compile time and the union of their
instruction groups, which prunes the decode tree. `setTiming` chooses what a processor charges:
`unknown`, one cycle an instruction with `null` costs, or `fitted`, a table of cycles per
instruction class, the extra when taken and, on Arm, per listed register, fitted to measurements
with the rules and issue model it needs (`fitOf`, for the M0+, the M4 and the M7). A processor
starts at `fitted` where its core has a fit and `unknown` where it has none, to which `fitted`
falls back.

The fitted issue model follows the previous instruction: which classes pair, the stalls on
registers it wrote, loads pipelined on one bus, the prefetch buffer, for the M4, IT and NOP
folding and SP-based accesses waiting on an SP write and, for the M7, dual issue, branch target
prediction, fetch words and store port hold. It reads each code's registers from its `isa` meta
entry, memoised per code in a 256-entry table.

### The run loop

`run` is one loop with a comptime `tracing` flag: a processor with a trace ring runs a second
copy, and one without pays nothing. Each turn checks a `due` word and, when it is zero, steps the
instruction set inline. The bits of `due` are what needs attention before the next instruction:

- an exception to enter, or a return to finish
- a sleep in progress
- a reset requested
- the cycle deadline reached
- the core stopped

Everything that can set a bit does so at the moment it happens, so the hot path tests one word.

### The clock and the schedule

The processor counts cycles, charged by the instruction set's cost table and by the exception
entry and exit sequences. It keeps an `attention` cycle, the earliest point at which anything
outside the instruction stream needs to run: SysTick wrapping, a device due to tick, or the
run's deadline. Charging past `attention` calls `service`, which advances SysTick, collects the
lines the bus's devices raised, pends them, and computes the next `attention`.

The bus follows the cycle counter through `follow`, so a device sees the cycles that passed
since it last ran and answers when it next wants to. A write to a device ticks it with zero
elapsed cycles, so a register write can arm a timer at once. Lines a device holds high are
polled on exception return on Arm and whenever a line is pended on RISC-V.

### Exceptions

`attend` runs when `due` is non-zero and takes whichever exception the NVIC or the interrupt
matrix ranks highest above the current execution priority.

- Arm: stacks the frame, including the floating-point half and the lazy-stacking bookkeeping,
  enters through the vector table and charges the entry cycles. A return unstacks, tail chains
  when something else is pending, and charges the exit cycles. A fault the core cannot take
  (handler not enabled, fault in a negative-priority handler, vector not a T32 address)
  escalates to HardFault and then to lockup, and the stop names the original fault.
- RISC-V: a trap enters through `mtvec`; a trap at the vector itself is unrecoverable.

The `latency` a run reports is the entry and exit cycles, counted separately so a run can say
how much of its time was exception machinery rather than program.

### Explaining

Every fault records what it was, where, and the address or code that caused it. `explain`
prints the stop, the last few trace records, the fault in the words of the manual, the status
registers, and on Arm any interrupt pending that can never be taken. This is the text the
diagnosis cases in the container check.

## The bus

`Regions` is a sorted array of entries, memory or device, found by binary search with the last
device answered cached in front. A memory entry answers `lookup` with its host pointer, which
`Folded` caches; a device entry answers with its index, which the slow lane uses to call it.

A device is three function pointers and a context rather than a Zig interface type, so it can
be written in any language that exports a C function, and so a map can be built from `.zon` at
run time.

The device schedule is two intrusive lists threaded through the entries: the devices that tick
and the devices that hold lines. Waking walks the first, polling the second, and a map with no
devices walks nothing.

## The tests

`zig build test` runs 450 unit tests under `test/`, which mirrors `src/`, and the tests in
`examples/`, with no dependency beyond Zig and `isa`.

- Processor tests run hand-assembled programs on every core: cycle tables, exception entry and
  return, SysTick, faults and lockups, MPU, SAU and PMP, tracing, breakpoints, semihosting.
- Memory tests cover the map, the ELF loader, devices and the schedule.

## The container

Everything that compares the library against something outside Zig runs in the image built from
`Dockerfile`. The image is pinned by digest, its apt archive by snapshot date and Zig by
SHA-256. It clones `isa` at the pinned tag to build the shared corpus and has no other tool: the
oracles were run once, and what they said is pinned under `oracle/` here and in `isa`.

### The gates

| Layer | Oracle | Reference | Gate |
|---|---|---|---|
| Lockstep | QEMU 10.0.13 `mps2-an385` (Arm), Sail 0.14 (RISC-V) | isa's `oracle/trace_arm.txt` and `trace_riscv.txt` for tier one, `oracle/trace_*_sys.txt` for tier two: one hash of the architectural state per 65536 retired instructions of each corpus image | Every window equal: 3688 Arm, 4002 RISC-V |
| Probe | QEMU (Arm), Espressif's QEMU fork (RISC-V) | `oracle/probe_*.txt`: a firmware that reads and writes the system registers and prints what it saw, 107 Arm lines and 91 RISC-V | Each line agrees with the oracle, or is in the divergence register with the manual section that decides for the library, or is a QEMU behaviour the register records as fixed |
| Corpus | The programs themselves | isa's `corpus/manifest.zon` and `corpus/manifest.zon`: 48 and 17 images with retired count, stop and checksum of console output | Count, stop and checksum equal |
| Diagnosis | The manuals | `corpus/diag/manifest.zon`: 11 programs that fault, each with the words its explanation must contain | Every case explained |
| Burst equivalence | The library itself | The system images as one run, as single steps and in bursts of 37 instructions against a clock; every tier-one image over its first two million instructions on every core class | The three agree, on every class |
| Invariants | The library itself | Every image with the trace ring and the event ring attached, on every core class | The result is unchanged |

### The divergence registers

`oracle/arm_divergences.txt` and `oracle/intc_divergences.txt` list the lines where the
library and the oracle disagree, each with the manual section that decides and which side it
decides for. The regeneration scripts fail if a listed line ever stops disagreeing, so the
registers describe the baseline as it is.

### The manuals

Each is cited here and in test names by its tag:

| Tag | Manual | Document |
|---|---|---|
| `v6-M` | Armv6-M Architecture Reference Manual | Arm DDI 0419E |
| `v7-M` | Armv7-M Architecture Reference Manual | Arm DDI 0403E.e |
| `v8-M` | Armv8-M Architecture Reference Manual | Arm DDI0553B.z |
| `M0 TRM` | Cortex-M0 Technical Reference Manual, r0p0 | Arm DDI 0432C |
| `M0+ TRM` | Cortex-M0+ Technical Reference Manual, r0p1 | Arm DDI 0484C |
| `M1 TRM` | Cortex-M1 Technical Reference Manual, r1p0 | Arm DDI 0413D |
| `M3 TRM` | Cortex-M3 Technical Reference Manual, r2p1 | Arm 100165_0201_02_en |
| `M4 TRM` | Cortex-M4 Technical Reference Manual, r0p1 | Arm 100166_0001_04_en |
| `M7 TRM` | Cortex-M7 Technical Reference Manual, r1p2 | Arm DDI 0489F |
| `M23 TRM` | Cortex-M23 Technical Reference Manual, r2p0 | Arm DDI 0550D |
| `M33 TRM` | Cortex-M33 Technical Reference Manual, r1p0 | Arm 100230_0100_08_en |
| `M55 TRM` | Cortex-M55 Technical Reference Manual, r1p1 | Arm 101051_0101_03_en |
| `M85 TRM` | Cortex-M85 Technical Reference Manual, r1p1 | Arm 101924_0101_07_en |
| `Glossary` | Arm Glossary | Arm 105565_200_03_en |
| `C3 TRM` | ESP32-C3 Technical Reference Manual | Espressif version 1.4 |
| `C6 TRM` | ESP32-C6 Technical Reference Manual | Espressif version 1.2 |
| `Privileged` | RISC-V Instruction Set Manual, Volume II, Privileged Architecture | RISC-V International version 20260120 |
| `Unprivileged` | RISC-V Instruction Set Manual, Volume I, Unprivileged Architecture | RISC-V International version 20260120 |

A bare B-, C-, D- or E-prefixed number is a section of the architecture manual of the core the
test builds, tagged where one test builds cores of more than one profile. Where a citation names
a register or a pseudocode function, `SAU_RLAR` or `DerivedLateArrival`, the name is the key:
revisions move the numbers and the name still finds the section.

### The corpus

| Tier | Images | Built by | Map | Measures |
|---|---|---|---|---|
| One | 48: five C programs, CoreMark and eighteen Embench benchmarks per architecture | `isa` | Flat, no devices | The instruction path |
| Two | 17 system images: interrupt storm, context switch, sleep and wake, fault recovery, semihosting I/O, device polling and tickless timer on both architectures; PMP, traps and the interrupt matrix on RISC-V | `corpus/build.sh` from `corpus/src` | With the bench's timer device | The system path |

Not every image runs on every core:

- Tier one is compiled `-mcpu=cortex_m3`, so M0+ and M23, whose decode tree is a T32 subset,
  stop on an undefined instruction within a few thousand instructions and are measured by size
  alone.
- `ctxswitch` programs the Armv7-M MPU through MPU_RASR, which is MPU_RLAR on Armv8-M.
- `irq_storm`, `devpoll` and `sleep` count interrupts and device ticks against the clock, and
  the cores charge differently: one cycle an instruction with no cycle table, and twelve cycles
  to return from an exception on the M3 against ten on the M4. The same program takes a
  different number of interrupts on each.
- The RISC-V system images reach the ESP32-C3 interrupt matrix at 0x600c2000, which on the
  ESP32-C6 is at 0x60010000 where the bench's timer sits. So `ctxswitch`, `irq_storm`,
  `sleep`, `tickless`, `devpoll` and `intc_matrix` are out on RISC-V.
- `floats` in isa's corpus needs the F extension, which neither the ESP32-C3 nor the C6 has, so
  the bench leaves it out.

Each exclusion applies to every class of its family, so one `sys_ns_*` column compares with
another. What is left is `recover`, `semihost_io` and `tickless` on Arm and `recover`, `semihost_io`,
`pmp` and `trap` on RISC-V.

### The metrics tables

`zig build metrics` runs every layer and appends rows to five tables in `bench/summary/`, or in
[bench/metrics/](bench/metrics/) with `--release`. The rows are written even when a gate fails,
with `status` set to `fail`, so a regression stays visible. Every table starts with `date` and
`commit`, which join them. A gate is written `pass/total`.

| Table | Rows per run | Holds |
|---|---|---|
| `run.tsv` | One | Which tree was measured and where: `target`, `zig`, `optimize`, `variant`, `cpu_mhz`, and digests of the bench sources, the corpus with its images, and `oracle/` |
| `correctness.tsv` | One | The gates: `oracle_arm`, `oracle_rv`, `probe_arm`, `probe_rv`, `corpus`, `diag`, `class_checks`, `burst_equivalent`, `trace_violations`; `status` is `pass` only when every one held |
| `speed.tsv` | One per timed class | `fw_ns_per_instr` over tier one and `sys_ns_per_instr` over the tier-two images the class runs, wall nanoseconds per retired instruction, geometric mean, best of five; `irq_entry_cycles` over the tier-two images that raise a line and never halt |
| `size.tsv` | One per class | `processor_bytes`, `@sizeOf` the machine; `text_bytes` and `rodata_bytes` of its size probe; `decode_bytes`, the machine minus the same machine linked against `bench/nullisa` |
| `build.tsv` | One | Wall time and memory of `zig build` for the library alone and for everything, at one and twelve jobs; the host contract entries the Arm processor answers; the bus size and the peak heap of a run |
| `accuracy.tsv` | One per fitted core | Appended by the private cycle-fitting repo: kernels and programs against their board records |

A class is timed when its machine runs with fitted timing and the class runs the corpus. Cores on
unknown timing charge one cycle an instruction, which runs faster than a fitted model and would
flatter the speed. The M0+ is fitted but not timed, since the corpus is built for Armv7-M.
`class_checks` covers every class that runs the corpus: every image reproduced, and every tier-one
image run, stepped, bursted and traced over its first two million instructions, agreeing.

#### Classes

A machine is built per equivalence class of code paths, not per family. What a core changes in
the built processor is mostly its architecture, which prunes the decode tree, and whether the
Security Extension is fitted; the rest of a `core.zig` entry is a table read at run time. So the
classes are the architectures, with the M7 apart:

| Class | Architecture | Shares its paths with |
|---|---|---|
| M0+ | Armv6-M | M0, M1 |
| M23 | Armv8-M Baseline | |
| M3 | Armv7-M | |
| M4 | Armv7E-M | |
| M7 | Armv7E-M, with caches and its fitted issue model | |
| M33 | Armv8-M Mainline | |
| M55 | Armv8.1-M Mainline | M85 |
| ESP32-C3 | RV32IMC | |
| ESP32-C6 | RV32IMAC with a static-priority PMP | |

M0 and M1 differ from their representatives only in published cycle counts and MPU region
counts, and M85 from M55 only by the pointer authentication flag. The oracle gates stay on M3 and
the ESP32-C3, the only cores a lockstep oracle exists for.

`bench/nullisa` is an `isa` module with the same surface that executes nothing. Linking against
it separates the processor from the instruction sets. Only rows from the same machine and Zig
compare.

## Sizes

The sizes at each release are in [bench/metrics/size.tsv](bench/metrics/size.tsv).
