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
says: architecture, cycle counts per instruction class and the extra cost of a taken branch,
exception entry and exit cycles, priority bits, id registers, reset CCR, extensions fitted, and
for RISC-V the CSR implementation, interrupt matrix layout and reset address.

`Processor(.{ .cores })` builds a table of these at compile time and the union of their
instruction groups, which prunes the decode tree. A core with no published cycle table (M1, M7,
M33, M55, M85, the ESP32s) reports `null` costs and charges one cycle an instruction.

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
oracles were run once, and what they said is pinned under `oracle/`.

### The gates

| Layer | Oracle | Reference | Gate |
|---|---|---|---|
| Lockstep | QEMU 10.0.13 `mps2-an385` (Arm), Sail 0.14 (RISC-V) | `oracle/trace_*.txt`: one hash of the architectural state per 65536 retired instructions of each corpus image | Every window equal: 3949 Arm, 4308 RISC-V |
| Probe | QEMU (Arm), Espressif's QEMU fork (RISC-V) | `oracle/probe_*.txt`: a firmware that reads and writes the system registers and prints what it saw, 107 Arm lines and 91 RISC-V | Each line agrees with the oracle, or is in the divergence register with the manual section that decides for the library, or is a QEMU behaviour the register records as fixed |
| Corpus | The programs themselves | `corpus/manifest.zon`: 67 images with retired count, stop and checksum of console output | Count, stop and checksum equal |
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
| `M23 TRM` | Cortex-M23 Technical Reference Manual, r1p0 | Arm DDI 0550C |
| `M33 TRM` | Cortex-M33 Technical Reference Manual, r1p0 | Arm 100230_0100_08_en |
| `M55 TRM` | Cortex-M55 Technical Reference Manual, r1p1 | Arm 101051_0101_03_en |
| `M85 TRM` | Cortex-M85 Technical Reference Manual, r1p1 | Arm 101924_0101_07_en |
| `Glossary` | Arm Glossary | Arm AEG 0014G |
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
| Two | 19 system images: interrupt storm, context switch, sleep and wake, fault recovery, semihosting I/O, device polling, tickless timer, self-modifying code on both architectures; PMP, traps and the interrupt matrix on RISC-V | `corpus/build.sh` from `corpus/src` | With the bench's timer device | The system path |

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

Each exclusion applies to every class of its family, so one `sys_ns_*` column compares with
another. What is left is `recover`, `semihost_io`, `tickless` and `smc` on Arm and `recover`,
`semihost_io`, `smc`, `pmp` and `trap` on RISC-V.

### The metrics row

`zig build metrics` runs every layer and appends one row to `bench/summary.tsv`, or to
[bench/release-metrics.tsv](bench/release-metrics.tsv) with `--release`. The row is written
even when a gate fails, with `status` set to `fail`, so a regression stays visible. The timing
columns come from the `machine` programs under `bench/arm` and `bench/riscv`, driven by
`bench/run.zig`.

#### Classes

A machine is built per equivalence class of code paths, not per family. What a core changes in
the built processor is its architecture, which prunes the decode tree, and whether the Security
Extension is fitted; everything else in a `core.zig` entry is a table read at run time. So the
classes are the architectures:

| Class | Architecture | Shares its paths with |
|---|---|---|
| M0+ | Armv6-M | M0, M1 |
| M23 | Armv8-M Baseline | |
| M3 | Armv7-M | |
| M4 | Armv7E-M | M7 |
| M33 | Armv8-M Mainline | |
| M55 | Armv8.1-M Mainline | M85 |
| ESP32-C3 | RV32IMC | |
| ESP32-C6 | RV32IMAC with a static-priority PMP | |

M0, M1 and M7 differ from their representatives only in published cycle counts and MPU region
counts, and M85 from M55 only by the pointer authentication flag. The oracle-gated columns stay
on M3 and the ESP32-C3, the only cores a lockstep oracle exists for.

#### Columns

| Column | What it measures |
|---|---|
| `fw_ns_per_instr` | Geometric mean over tier one of wall nanoseconds per retired instruction, best of the runs |
| `sys_ns_per_instr` | The same over tier two: the system layers under load |
| `chip_ns_per_instr` | Tier two in bursts against a clock, as a chip model would drive it |
| `debug_ns_per_instr`, `debug_chip_ns_per_instr` | The two above with a 65536-record trace ring attached |
| `stubhost_ns` | The `isa` step loop alone over a flat memory, in `bench/*/stubhost.zig`: the floor the processor is measured against |
| `access_ns`, `ppb_ns` | Nanoseconds per data read from memory and per system register read |
| `irq_entry_cycles`, `latency_cycles_per_kinstr` | Exception entry cost and the share of the corpus spent in entry and return |
| `fw_ns_m3`, `_m4`, `_m33`, `_m55`, `_c3`, `_c6` | `fw_ns_per_instr` for one class over the whole of tier one |
| `sys_ns_m3` and the rest | The same over the tier-two images every class of the family runs |
| `irq_entry_cycles_m3`, `_m4`, `_m33`, `_m55` | Exception entry cost on that class, over every tier-two image that raises a line and never halts, including the ones left out of the timing set. Arm only: no RISC-V system image both ESP32s run raises a line |
| `class_checks`, `class_checks_pass` | Per class: every image reproduced, and every tier-one image run, stepped, bursted and traced over its first two million instructions, agreeing |
| `processor_bytes`, `table_bytes`, `heap_peak_bytes` | `@sizeOf` the machine and the bus, and the peak heap of a run |
| `processor_bytes_m0plus` and the rest, `obj_text_*`, `obj_rodata_*` | The same sizes for one class. They barely move: what a core selects is selected inside `isa` |
| `link_delta_bytes_m0plus` and the rest | That class's machine minus the same machine linked against `bench/nullisa`: the decode tree its architecture keeps, the one size a class does change |
| `build_s_*`, `rss_mb_*` | Wall time and memory of `zig build` for the library alone and for everything, at one and twelve jobs |
| `isa_decls_required`, `isa_decls_optional` | The host contract entries the Arm processor answers |
| `date`, `commit`, `alt`, `variant`, `target`, `optimize`, `zig`, `cpu_mhz` | Which tree was measured and where |
| `status`, `oracle_arm_*`, `oracle_rv_*`, `probe_arm_*`, `probe_rv_*`, `corpus_*`, `diag_*`, `burst_equiv_pass`, `invariant_violations` | The gates above, each as what agreed out of what was checked; `status` is `pass` only when every one did |
| `harness_sha`, `corpus_sha`, `oracle_sha` | Digests of the bench sources, the corpus with its images, and `oracle/` |

`bench/nullisa` is an `isa` module with the same surface that executes nothing. Linking against
it separates the processor from the instruction sets. Only rows from the same machine and Zig
compare.

## Sizes

At the last release row the two processors together compile to about 100 KB of text, a one-core
Arm machine is 1616 bytes, and the system layers cost 1.3 ns an instruction over the instruction
set alone on the corpus.
