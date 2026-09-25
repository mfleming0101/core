# Library glossary

One name per concept for `core`, the Zig library that puts a processor, its memory map and its
system blocks around the `isa` instruction-set package. Where a word could mean two things, the
entry says which meaning core keeps. Links are relative to the repository root; a name living in
both halves is linked twice, as [arm](src/arm/system/processor.zig) and
[riscv](src/riscv/system/processor.zig).

| Section | Terms |
|---|---|
| [The processor](#the-processor) | Processor, Options, Core, Family, Architecture, Spec, Hart |
| [Running and stopping](#running-and-stopping) | Run, Step, Limit, Ended, Charge, Deadline, Clock, Stop, Exception, Trap |
| [Memory and the bus](#memory-and-the-bus) | Bus, Regions, Found, Folded, Span, Access, Touch, Peek and poke, Width, Host contract, Device, Line and lines, Raise word, Map, Image |
| [System blocks](#system-blocks) | PPB, NVIC and SCB, SysTick, MPU, SAU, Interrupt matrix, PMP, Semihosting |
| [Tracing](#tracing) | Trace, Ring, Record |
| [Measurement](#measurement) | Machine, Stub host, Null ISA, Row, Gate, Tier, Corpus, Oracle, Probe, Divergence register |

## The processor

### Processor

One comptime-configured struct holding the `isa` state, the [spec](#spec) of the part, the
system blocks, the [bus](#bus), the pending and active exception sets, the cycle count and the
[trace ring](#ring). It answers every [host contract](#host-contract) entry, so the instruction
set sees nothing else.

- `Processor`, built by `init`, put back by `reset`: [arm](src/arm/system/processor.zig),
  [riscv](src/riscv/system/processor.zig).
- "Processor" is the whole thing, "core" the part it models, the bench's wrapper a
  [machine](#machine); the variable is `cpu`.

### Options

The comptime configuration of a processor: `cores`, the [cores](#core) one build answers for,
and `Bus`, the memory type it reaches through. Neither has a default.

- `Options`: [arm](src/arm/system/processor.zig), [riscv](src/riscv/system/processor.zig).
- One core prunes the decode tree to that core's groups; several build the union, `allowed`.
- `cores` is the set a build can be *initialised* with; `Processor.init` takes the one it *is*.

### Core

A part this library models, by name: `m0`, `m0plus`, `m1`, `m23`, `m3`, `m4`, `m7`, `m33`,
`m55`, `m85`, `esp32c3`, `esp32c6`. The [family](#family) enum is the union of both halves; each
half has its own narrower one.

- `core.Core`, [src/family.zig](src/family.zig); `core.arm.Core`,
  [src/arm/system/core.zig](src/arm/system/core.zig); `core.riscv.Core`,
  [src/riscv/system/core.zig](src/riscv/system/core.zig).
- The word also names the library, and a [divergence register](#divergence-register) writes
  `core=` for its answer. A `Core` value is always the part.

### Family

Which instruction set a [core](#core) belongs to, `arm` or `riscv`, and the word for each half
of the library. Every type existing once per family, `Processor`, `Options`, `Step`, `Run`,
`Limit`, `Ended`, `Core`, `Stop` and `trace`, is reached through `core.arm` or `core.riscv`.

- `Family` and `family.of`, [src/family.zig](src/family.zig), re-exported as `core.familyOf`,
  [src/core.zig](src/core.zig).
- The prose says "family", never "architecture", Arm's word for a version of the instruction set
  and the name of [Architecture](#architecture).

### Architecture

One M-profile architecture version, `isa`'s enum. A [Spec](#spec) names one and the processor
answers it to `isa`'s `architecture` entry; it decides whether unaligned single accesses are
answered, which APSR bits an MSR write reaches, and which decode groups the tree is pruned to.

- `Spec.architecture`, [src/arm/system/core.zig](src/arm/system/core.zig).
- RISC-V has no architecture: an ESP32-C part is described by its group set alone,
  `Spec.groups`, [src/riscv/system/core.zig](src/riscv/system/core.zig).

### Spec

Everything core knows about one [core](#core) as a value: its [architecture](#architecture) or
group set, its cycle table or `null` where no reference publishes one, its identity registers,
its reset defaults and its optional blocks. Comptime data, selected by `spec(core)`; the
[processor](#processor) holds a copy of the one it was built as.

- `Spec` and `spec`: [arm](src/arm/system/core.zig), [riscv](src/riscv/system/core.zig).
- `Spec.cycles` is what an instruction of each class costs, `Spec.taken` what a taken branch
  adds; both `null` where no table is published, and such a processor charges one cycle an
  instruction.
- `Spec.model` is the RISC-V CSR implementation, `isa`'s word, not a model of the part.

### Hart

RISC-V's hardware thread: the one register file, program counter and privilege mode an ESP32-C
part has. Core models exactly one and says "hart" wherever the RISC-V specs do: the CSRs belong
to the hart, the [PMP](#pmp) registers to the platform, the
[interrupt matrix](#interrupt-matrix) to the chip.

- `isa`'s `riscv.State`, held as `Processor.state`,
  [src/riscv/system/processor.zig](src/riscv/system/processor.zig).
- The Arm half says "core" for the same idea, after Arm's own word.

## Running and stopping

### Run

What a run produced: the instructions retired, the cycles charged, the [stop](#stop) if there
was one, and the [Ended](#ended) reason. Every count is *for that run*; the totals are the
processor's own fields.

- `Run` and `Processor.run`: [arm](src/arm/system/processor.zig),
  [riscv](src/riscv/system/processor.zig).
- `run` is the loop, `Run` what it answers, [Limit](#limit) what bounds it. The Arm `Run`
  carries a `latency` the RISC-V one does not.

### Step

What one turn produced: the address it ran at, the instruction [class](#spec) if one retired,
the cycles that class costs, the cycles charged, whether the fetch followed the one before it,
whether the core is asleep, and the [stop](#stop) if it halted.

- `Step` and `Processor.step`: [arm](src/arm/system/processor.zig),
  [riscv](src/riscv/system/processor.zig).
- `Step.cost` is what the table says and is *not* charged: stepping is how a chip deciding its
  own timing drives the core, charging what it decided through [`charge`](#charge).
  `Step.charged` is what the step already charged, the exception entry and the sleep, not the
  instruction. A run charges both.

### Limit

What a [run](#run) is bounded by: `instructions`, with no default, the reason `run` was called;
`cycles`, a relative cycle budget defaulting to no bound; and `asleep`, which ends the run at a
WFI or WFE nothing wakes rather than waiting in it.

- `Limit`: [arm](src/arm/system/processor.zig), [riscv](src/riscv/system/processor.zig).
- `Limit.cycles` counts from where the processor already is, not from zero, and becomes the
  run's [deadline](#deadline).

### Ended

Which bound stopped a [run](#run): `budget` when the instruction count ran out, `deadline` when
the cycle count did, `stopped` when the core halted, `asleep` when a sleep nothing wakes ended
it. It is the one answer that always distinguishes them: a run ending on its budget and one
ending on a stop both come back with instructions retired.

- `Ended`: [arm](src/arm/system/processor.zig), [riscv](src/riscv/system/processor.zig).

### Charge

Adding cycles to the processor's own count, the only way that count moves. Charging services the
bus too: past the standing attention point the [devices](#device) are ticked,
[SysTick](#systick) is advanced and the [deadline](#deadline) re-checked.

- `Processor.charge`: [arm](src/arm/system/processor.zig),
  [riscv](src/riscv/system/processor.zig).
- [Clock](#clock) has a `charge` of its own converting cycles to picoseconds: the same verb over
  the same quantity, one counting cycles, one counting time.

### Deadline

A cycle count a run must not pass. [Regions](#regions) and [SysTick](#systick) each answer the
next cycle they want attention at, and the processor keeps the soonest of those and
`Limit.cycles`.

- `Limit.cycles`, [src/arm/system/processor.zig](src/arm/system/processor.zig);
  `Regions.untilDue`, [src/memory/regions.zig](src/memory/regions.zig); `SysTick.deadline`,
  [src/arm/system/systick.zig](src/arm/system/systick.zig).
- A run reaching one answers `Ended.deadline`. A deadline is always a cycle count, never a time:
  the picoseconds live in the [clock](#clock).

### Clock

The conversion between cycles and wall time, kept as picoseconds so a frequency that does not
divide a second exactly loses nothing: `hz`, `per` picoseconds per cycle, `rem` the leftover,
`owed` the running fraction and `ps` the picoseconds spent.

- `Clock`, built by `Clock.at(hz)`: [src/memory/clock.zig](src/memory/clock.zig).
- `Clock.bank` changes the frequency and keeps the picoseconds spent, an unrelated use of the
  word core otherwise keeps for the Arm banked registers.

### Stop

Why the core stands still instead of retiring: `isa`'s enum, re-exported by each family, and
also the [processor](#processor) field holding the standing one. Arm has seventeen, RISC-V
three, since everything else is a [trap](#trap) already taken.

- `core.arm.Stop`, [src/arm/root.zig](src/arm/root.zig); `core.riscv.Stop`,
  [src/riscv/root.zig](src/riscv/root.zig).
- `Run.stop` is the stop *that run* reached; `Processor.stop` the one the core stands at, which
  the next run steps over if it is a breakpoint.
- The bench has a third, deliberately small `Stop` crossing the machine boundary,
  [bench/harness/snapshot.zig](bench/harness/snapshot.zig); it carries a `budget` member core's
  does not, standing for the whole reason a run ended.

### Exception

An entry the processor takes on its own between two instructions rather than as part of one: an
Arm exception, or a RISC-V interrupt or [trap](#trap). Both halves count them in `Processor.exceptions` and the interrupt
subset in `Processor.irqs`; Arm also accumulates the cycles spent entering and leaving in
`Processor.latency`, reported as `Run.latency`.

- `Run.latency`, [src/arm/system/processor.zig](src/arm/system/processor.zig). The RISC-V `Run`
  has no such field, [src/riscv/system/processor.zig](src/riscv/system/processor.zig), because
  no ESP32-C reference publishes an entry latency.
- An entry appears in the [trace](#trace) as a [record](#record) whose note kind is `.entry` or
  `.irq`, [src/trace/text.zig](src/trace/text.zig).

### Trap

A RISC-V synchronous exception a row raised and the [hart](#hart) has already taken, named for
what happened rather than for its `mcause` code. Core turns one into an `mcause` and an `mtval`,
enters through `mtvec`, and remembers it for `explain`. Arm has no equivalent: an Arm fault is a
[stop](#stop) or an exception the processor takes for itself.

- The remembered one is `Taken`,
  [src/riscv/system/processor.zig](src/riscv/system/processor.zig), made from `isa`'s
  `step.Trap` with the codes of `isa`'s `csr.Cause`.
- A trap that cannot be taken, one raised at the handler's own first instruction, becomes the
  `unrecoverable_trap` [stop](#stop), the RISC-V counterpart of Arm lockup.

## Memory and the bus

### Bus

The comptime type the [processor](#processor) reaches memory through: whatever the consumer
passes as `Options.Bus`. [Regions](#regions) is the one core ships; anything with the same
`lookup`, `folded`, `peek`, `poke`, `parcel`, `follow`, `untilDue`, `interrupts` and `asserted`
surface serves.

- `Options.Bus`: [arm](src/arm/system/processor.zig), [riscv](src/riscv/system/processor.zig).
  The field holding one is `Processor.memory`.
- In `bench/` alone, `consumer.bus`, [bench/harness/consumer.zig](bench/harness/consumer.zig),
  is a third thing: the function building a `Regions` out of a [map](#map) and an
  [image](#image).

### Regions

The address map, and the [bus](#bus) core ships: a sorted, non-overlapping list of memory blocks
and [devices](#device), a binary search over it, the [folded](#folded) caches, the device
schedule and the [raise word](#raise-word). Built once from a [map](#map) or by hand, it is what
a [processor](#processor) is given.

- `Regions`, built by `Regions.adopt`, which sorts the entries given it and refuses an empty,
  wrapping or overlapping one: [src/memory/regions.zig](src/memory/regions.zig).
- The word is plural because the thing is the whole map; one element is a `Regions.Entry`. The
  [MPU](#mpu)'s protection regions are a different thing with the same word.

### Found

What a [Regions](#regions) lookup answers: the base and length of the entry holding the address,
its host bytes if it is memory, whether it is writable, and the index of the [device](#device)
if it is one. A lookup landing in a hole answers its bounds with no host bytes, so a refusal can
be [folded](#folded) as wide as the hole.

- `Found`, answered by `Regions.lookup`: [src/memory/regions.zig](src/memory/regions.zig).

### Folded

The three one-block caches the [processor](#processor) fetches, loads and stores through: one
`Block` per lane, holding the base, length and host pointer of the largest run of addresses
answering the same way. A hit is a subtraction and a compare; anything else refolds. A refused
run is remembered too, in `refused`, so a hole is not looked up twice.

- `Folded`, held as `Regions.folded`, emptied by `Folded.unfold`:
  [src/memory/regions.zig](src/memory/regions.zig).
- Folding makes a whole [span](#span) safe to answer in place: the [MPU](#mpu) or [PMP](#pmp),
  the [PPB](#ppb) or [interrupt matrix](#interrupt-matrix) window, the region's bounds and
  whether it is writable have been asked once for the whole block. Anything that could change an
  answer must unfold.

### Span

The bytes the [bus](#bus) answers for from an address onwards, and the name of the
[host contract](#host-contract) entry returning them. An empty answer sends the instruction set
to the `access` lane. Because a span runs to the end of the [folded](#folded) block, a load
multiple and a two-parcel fetch cost one lookup.

- `Processor.span`, [arm](src/arm/system/processor.zig),
  [riscv](src/riscv/system/processor.zig), over `Folded.reach`,
  [src/memory/regions.zig](src/memory/regions.zig).
- On the library surface a span is that slice and nothing else. Two local uses differ: the
  `span` of `Regions.place` is a byte count, the memory size of an ELF segment, and the bench's
  `--span` is a burst length in instructions,
  [bench/harness/consumer.zig](bench/harness/consumer.zig).

### Access

The comptime record core passes to [span](#span) and to the `access` lane beneath it: `.kind` is
`.fetch`, `.read`, `.write` or `.vector`, `.bytes` the size in bytes. Core declares the type
where `isa` builds it anonymously at each call site, so both halves agree on the field names.

- `Access`, with `Kind` and `Failure`, the errors the lane may raise:
  [src/contract.zig](src/contract.zig).
- `.vector` is core's own fourth kind, the read of an exception vector: Arm needs it because a
  vector read no memory answers must lock the core rather than be forgiven by `BFHFNMIGN`. Only
  Arm issues one, and the [folded](#folded) cache answers it from the `.read` lane.

### Touch

The [host contract](#host-contract) entry told the address a lookup was made at, once per lookup
rather than once per word. It feeds the fault address registers, `MMFAR` and `BFAR` on Arm,
`mtval` on RISC-V, and the [record](#record)'s access field.

- `Processor.touch`: [arm](src/arm/system/processor.zig),
  [riscv](src/riscv/system/processor.zig).
- The halves do different work in it: Arm records only while the [ring](#ring) is recording,
  RISC-V also breaks the LR/SC reservation.

### Peek and poke

The two ways to reach memory from outside an instruction: `peek` reads a word of the given byte
width, `poke` writes one, each answering `null` if nothing did. Both exist on the
[processor](#processor), where they go through the [MPU](#mpu) or [PMP](#pmp) and the peripheral
windows, and on [Regions](#regions), where they do not.

- `Processor.peek` and `Processor.poke`: [arm](src/arm/system/processor.zig),
  [riscv](src/riscv/system/processor.zig); `Regions.peek` and `Regions.poke`,
  [src/memory/regions.zig](src/memory/regions.zig).
- Their first parameter is a [width](#width) in bytes, not bits.

### Width

A byte count, everywhere core spells it `width`: `Device.read` and `Device.write` take the
`Width` enum, whose values *are* the byte counts; `peek`, `poke` and `Word` take a plain `u8` of
bytes.

- `Width`, [src/memory/regions.zig](src/memory/regions.zig); `contract.Word`,
  [src/contract.zig](src/contract.zig).
- `isa` uses `width` for bits and `bytes` for bytes. Core uses `width` for bytes throughout and
  has no bit-counted parameter, so `peek(4, at)` is a 32-bit read.

### Host contract

What `isa` requires of whatever runs its rows, and what core's [processor](#processor) answers:
the three memory declarations `span`, `access` and `touch`, plus the configuration, notification
and floating-point answers each architecture asks for. `isa` declares the list, not core, but
`bench/` spells it out entry by entry with the reason each is answered as it is, and counts the
entries into the [row](#row)'s `isa_decls_required` and `isa_decls_optional`.

- `isa_requirements`, [bench/arm/machine.zig](bench/arm/machine.zig), counted by `required` and
  `optional`, [bench/harness/contract.zig](bench/harness/contract.zig). The two memory entries
  are written in terms of `contract.read` and `contract.write`,
  [src/contract.zig](src/contract.zig).
- An individual entry is a requirement.

### Device

Something in the address space that is not memory: an opaque context and four function pointers,
`read` and `write` at an offset from its own base, an optional `tick` keeping time, and an
optional `asserted` naming the [lines](#line-and-lines) it holds high. `read` and `write` answer
`null` to refuse; `tick` answers the cycles until it next wants ticking, zero for the next
cycle, `null` for never.

- `Device`, [src/memory/regions.zig](src/memory/regions.zig).
- `map.Device`, [src/memory/map.zig](src/memory/map.zig), is the [map](#map) entry asking for
  one by model name; the built object is this `Device`.

### Line and lines

One interrupt line a [device](#device) can raise, and the word of two hundred and forty of them
carrying a set: a line is a number in `Line`, a set of lines a `Lines`. Both halves use the same
pair, so one device model can sit on either.

- `lines`, `Lines` and `Line`, [src/memory/regions.zig](src/memory/regions.zig), the last two
  re-exported as `core.memory.Lines` and `core.memory.Line`.
- On Arm a line is an IRQ number, sixteen below the exception number the [NVIC](#nvic-and-scb)
  registers use. On RISC-V it is an [interrupt matrix](#interrupt-matrix) source the matrix
  routes to an id.
- `Processor.pendAll` takes a `Lines`, a whole set; `Processor.pend` and `Processor.enabled`
  take a `Line`, a single number.

### Raise word

The `*Lines` a [device](#device) is handed on every call and sets bits in to ask for an
interrupt. Nothing is taken at the write: the [bus](#bus) holds the word, the processor collects
it at its next service point, and only then does a line become pending.

- The parameter is `raise`, the bus accumulates into `Regions.raised`, and `Regions.interrupts`
  hands it to the processor and clears it: [src/memory/regions.zig](src/memory/regions.zig).
- A device holding a line high rather than pulsing it answers `Regions.asserted` instead;
  raising is the edge, asserting the level.

### Map

One board described as data: which [core](#core) it carries, which regions of memory it has and
what each is loaded from, which [devices](#device) sit where, and optionally the ELF to run. The
corpus keeps maps as `.zon`, and `map.build` turns one into [Regions](#regions) over an arena.

- `Map` and `map.build`: [src/memory/map.zig](src/memory/map.zig).
- A `map.Region` is the *request*; a `Regions.Memory`,
  [src/memory/regions.zig](src/memory/regions.zig), the built entry.
- The device models a map may name live in a `Registry`; whatever the builder refused is left in
  a `Blame` for the caller to report.

### Image

A firmware binary a region is loaded from. A [map](#map) names one per region by name; the ELF
loader places every `PT_LOAD` segment of an executable at its physical address, zeroing the rest
of each segment's memory size.

- `map.Image`, the two ways a named image can fail, [src/memory/map.zig](src/memory/map.zig);
  `elf.load` and `elf.Failure`, [src/memory/elf.zig](src/memory/elf.zig).
- The bench also calls the ELF it runs an image, and a [corpus](#corpus) manifest entry is one:
  the same thing seen from outside.

## System blocks

### PPB

Arm's Private Peripheral Bus, the megabyte at `0xe0000000` holding the system blocks: the
[SCB](#nvic-and-scb), the [NVIC](#nvic-and-scb), [SysTick](#systick), the [DWT](#systick), the
[MPU](#mpu), the [SAU](#sau) and the Non-secure aliases of the banked ones. Core routes an
access by address to the block answering it and never [folds](#folded) any of it, so a
peripheral read is always a call.

- `ppb.region` over the `Region` enum: [src/arm/system/ppb.zig](src/arm/system/ppb.zig).
- The RISC-V equivalent is `Intc.region`,
  [src/riscv/system/intc.zig](src/riscv/system/intc.zig), over the two
  [interrupt matrix](#interrupt-matrix) windows; both enums have a `.memory` member meaning
  "not a peripheral".

### NVIC and SCB

Arm's Nested Vectored Interrupt Controller and System Control Block: the enable bits and
priority bytes for up to two hundred and forty interrupts, and the identity, control,
vector-table and fault-status registers beside them. Core models both, banks the SCB for a part
with the Security Extension, and takes the highest-priority pending exception at each service
point.

- `Nvic`, [src/arm/system/nvic.zig](src/arm/system/nvic.zig), and `Scb`,
  [src/arm/system/scb.zig](src/arm/system/scb.zig), reached as `Processor.nvic`, `Processor.scb`
  and `Processor.scb_ns`; which SCB registers a part has is a `Profile`.
- The pending and active sets are not in the NVIC: the processor keeps them over exception
  numbers, `Processor.pending` and `Processor.active`, and answers NVIC_ISPR, NVIC_ICPR and
  NVIC_IABR from them.
- The NVIC counts in [lines](#line-and-lines) from IRQ 0, the processor in exception numbers,
  where IRQ 0 is 16 and the Non-secure aliases begin above them all. Priority bits are
  `Spec.priority_bits`, [src/arm/system/core.zig](src/arm/system/core.zig).

### SysTick

Arm's 24-bit system timer, and with it the DWT cycle counter: the two blocks whose value follows
the cycle count rather than anything written to them. Core advances SysTick when it services the
bus and derives `DWT_CYCCNT` from the processor's own count, so neither costs anything between
service points.

- `SysTick`, advanced by `SysTick.advance`:
  [src/arm/system/systick.zig](src/arm/system/systick.zig); `Dwt`,
  [src/arm/system/dwt.zig](src/arm/system/dwt.zig).
- `SysTick.deadline` is the cycles until it next wants attention, in the same sense as a
  [device](#device)'s `tick`.

### MPU

Arm's Memory Protection Unit. Core models the v7-M and v8-M forms in one block and asks it
twice: once per access on the slow path, once per [fold](#folded) to bound the block a
[span](#span) may run over. How many regions a part has is a [Spec](#spec) field; a part with
none is a unit never enabled.

- `Mpu`, [src/arm/system/mpu.zig](src/arm/system/mpu.zig), reached as `Processor.mpu` and
  `Processor.mpu_ns`; `Spec.mpu_regions`, [src/arm/system/core.zig](src/arm/system/core.zig).
- `mpu.regions` is how many protection regions the library models, a different thing from the
  [Regions](#regions) that are the address map; the protection ones are always qualified in
  prose.

### SAU

Arm's Security Attribution Unit: eight regions saying which addresses are Non-secure and which
Non-secure callable. Core models it for parts whose [spec](#spec) has `security`, answers
`isa`'s `attribute` entry from it, and reports the answer as an `Attribution`.

- `Sau`, reached as `Processor.sau`, and `Attribution`:
  [src/arm/system/sau.zig](src/arm/system/sau.zig).

### Interrupt matrix

The Espressif block in front of the [hart](#hart): a table routing each of the part's sources to
one of thirty-two CPU interrupts, with per-id enable, type, clear, status, priority and
threshold registers, and on the C6 software registers a program raises its own source through.
Core models the registers, the level and edge latches and the priority choice, and answers CSR
reads of `mip` from it where the part has one.

- `Intc`, and the per-part register addresses `Layout`, named by `Spec.intc`:
  [src/riscv/system/intc.zig](src/riscv/system/intc.zig).
- A *source* is a device's [line](#line-and-lines), numbered as the part numbers it; an *id* is
  the CPU interrupt it is routed to, which chooses the vector. `Intc.routed` maps one to the
  other.

### PMP

RISC-V's Physical Memory Protection unit: sixteen entries of configuration and address, in
`off`, `tor`, `na4` or `napot` mode. Core answers `isa`'s `readPmp` and `writePmp` from it, asks
it once per access on the slow path and once per [fold](#folded), and empties the folded cache
on every write, since one write can change every answer.

- `Pmp`, [src/riscv/system/pmp.zig](src/riscv/system/pmp.zig), reached as `Processor.pmp`;
  `Processor.readPmp` and `writePmp`,
  [src/riscv/system/processor.zig](src/riscv/system/processor.zig).
- Whether the lowest-numbered matching entry decides, rather than any match that grants being
  enough, is a part property, `Spec.pmp_static_priority`,
  [src/riscv/system/core.zig](src/riscv/system/core.zig).

### Semihosting

The Arm convention by which firmware asks whoever runs it to do the I/O: a trapping instruction
with an operation number in one register and a parameter block address in another. Core
implements the console subset, `SYS_OPEN` of `:tt`, `CLOSE`, `WRITEC`, `WRITE0`, `WRITE`,
`ISTTY`, `EXIT` and `EXIT_EXTENDED`, once, over `peek`; each family says only how the call is
recognised and which registers carry it.

- `calls.call`, [src/semihosting/calls.zig](src/semihosting/calls.zig); the family wrappers are
  [src/arm/semihosting.zig](src/arm/semihosting.zig) and
  [src/riscv/semihosting.zig](src/riscv/semihosting.zig).
- `trapped` tests that the core stopped on a semihosting call rather than an ordinary
  breakpoint: on Arm `BKPT 0xab`, on RISC-V an `EBREAK` between the two marker instructions.
  Handling the call does not step over it; the next [run](#run) does.

## Tracing

### Trace

The per-family module turning core state into [records](#record) and records into text: the
register list, the snapshot, the ring type, the line renderer, and `explain`, which says in a
sentence why the core stopped and prints the last lines that led there.

- `core.arm.trace`, [src/arm/trace.zig](src/arm/trace.zig), and `core.riscv.trace`,
  [src/riscv/trace.zig](src/riscv/trace.zig); the shared rendering is
  [src/trace/text.zig](src/trace/text.zig), the shared record and ring
  [src/trace/family.zig](src/trace/family.zig).
- `Processor.explain`, [src/arm/system/processor.zig](src/arm/system/processor.zig), is the
  processor's wrapper, adding what the system blocks say: the fault status registers on Arm, the
  trap CSRs and unrouted sources on RISC-V.

### Ring

The fixed, allocation-free history the [trace](#trace) is kept in: the caller hands the
processor a slice of [records](#record) at `init`, and the ring keeps the newest and counts
every one ever written. A zero-length slice means no tracing at all, the fast path.

- `Ring`, [src/trace/ring.zig](src/trace/ring.zig), re-exported as `core.trace.Ring`,
  [src/trace/root.zig](src/trace/root.zig), and instantiated per family as `core.arm.trace.Ring`
  and `core.riscv.trace.Ring`.
- `Ring.written` is how many records have been written, not how many are held; `Ring.at(0)` is
  the newest and `Ring.at(n)` counts backwards. `Ring.init` refuses a slice whose length is not
  a power of two.

### Record

One line of the [trace ring](#ring): the address, the code if one was fetched, the registers
whose values changed and what they became, the first address the instruction touched, the cycle
count, and a note saying whether it retired, entered a handler, took an interrupt, returned or
was refused.

- `Record`, [src/arm/trace.zig](src/arm/trace.zig) and
  [src/riscv/trace.zig](src/riscv/trace.zig), both built from
  [src/trace/family.zig](src/trace/family.zig); the note is `Note`,
  [src/trace/text.zig](src/trace/text.zig).
- A record is rendered against `register_names`: on Arm `r0` to `r12`, the selected stack
  pointer, `lr` and `xpsr`; on RISC-V the ABI names of `x1` to `x31`. Each half indexes its own
  registers.

## Measurement

### Machine

In `bench/`, the wrapper putting one measured [processor](#processor) behind the one
command-line program every measurement drives: it loads a [map](#map) and an [image](#image),
runs, steps, bursts, snapshots, explains, and answers the size and interface constants the
[row](#row) reports. One per family.

- `Machine`, [bench/arm/machine.zig](bench/arm/machine.zig) and
  [bench/riscv/machine.zig](bench/riscv/machine.zig); the comptime check is `assertMachine`,
  [bench/harness/facade.zig](bench/harness/facade.zig), and the program over it `Consumer`,
  [bench/harness/consumer.zig](bench/harness/consumer.zig).
- A machine is not a [host](#host-contract): a host answers the instruction set, a machine the
  harness.

### Stub host

A bench machine answering the [host contract](#host-contract) with constants over a flat window
and no system blocks, so a measurement of it is the instruction set and the loop alone. What a
[row](#row)'s own numbers are read against.

- `stubhost.Arm` and `stubhost.Riscv`, [bench/harness/stubhost.zig](bench/harness/stubhost.zig).
- Its inner type is called `Bus`, after the [bus](#bus) parameter it stands in for, though it
  answers the instruction set's host contract rather than core's bus surface.

### Null ISA

A stand-in for the `isa` package with the same shape and no instruction semantics, so the
library can be built and measured without the instruction set in it. `-Disa=null` links it
everywhere; otherwise only into the size probe and the `machine-null-*` binaries, whose object
sizes the real ones are subtracted from.

- [bench/nullisa/root.zig](bench/nullisa/root.zig), selected at [build.zig](build.zig).

### Row

In `bench/`, one line of `bench/summary.tsv` or
[bench/release-metrics.tsv](bench/release-metrics.tsv): provenance, every correctness
[gate](#gate), nanoseconds per instruction at each [tier](#tier), the sizes, the build times and
the interface counts. A row is written even when a gate fails, with `status` set to `fail`, so a
regression stays in the history.

- `Row`, with the `header` and `line` renderers:
  [bench/harness/metrics.zig](bench/harness/metrics.zig).
- `bench/detail.tsv` holds one line per image rather than per run; its header is in
  [bench/run.zig](bench/run.zig). A "row" of the `isa` instruction table is a different thing,
  and core never uses the word that way.

### Gate

In `bench/`, a correctness column a [row](#row) must hold before its status may be `pass`: both
[oracle](#oracle) comparisons, both [probe](#probe) comparisons, the [corpus](#corpus) and
diagnosis counts, the burst equivalence, the per-class checks and the invariant violations.

- `metrics.gated`, [bench/harness/metrics.zig](bench/harness/metrics.zig).
- The word means two other things elsewhere, both local. `Intc.best` takes a `gate`, the word of
  enabled interrupt ids, [src/riscv/system/intc.zig](src/riscv/system/intc.zig); each processor
  has a private comptime `gate` or `leaf_gate`, the group set a one-core build prunes the decode
  tree to.

### Tier

How much of the library one measurement exercises. Tier one is the instruction set alone, the
images whose manifest entry says `source = "isa"`; tier two is the same run with the system
blocks, the devices and the interrupts in it. A [row](#row) reports nanoseconds per instruction
for each.

- `tierOf`, [bench/run.zig](bench/run.zig).
- The columns are `fw_ns_per_instr` for tier one and `sys_ns_per_instr` for tier two,
  [bench/harness/metrics.zig](bench/harness/metrics.zig).

### Corpus

The firmware the library is run against and the manifest pinning what each image must retire,
where it must stop and what it must print. `corpus/src` holds the C programs, `corpus/maps` the
[maps](#map) they run on, `corpus/port` the two startup ports, `corpus/diag` the diagnosis cases
whose expected explanations are checked line by line.

- `corpus/manifest.zon` and `corpus/diag/manifest.zon`, read by [bench/run.zig](bench/run.zig).

### Oracle

An outside authority the library is compared against, and the pinned files holding its answers:
QEMU for the Arm traces and probe, Espressif's QEMU and Sail for the RISC-V ones. Every
comparison is against a file in [oracle/](oracle/), never a tool run at measurement time, and a
[divergence register](#divergence-register) records where the two knowingly differ and why.

- The trace pins are `oracle/trace_*.txt`, the probe pins
  [oracle/probe_arm.txt](oracle/probe_arm.txt) and
  [oracle/probe_riscv.txt](oracle/probe_riscv.txt).

### Probe

A firmware reading every system register the part has and printing one `name=value` line per
register, run on both the library and the [oracle](#oracle) and compared line by line. It
measures the register model, where the [tier](#tier)-two traces measure the running core.

- [oracle/probe/](oracle/probe/), compared by [oracle/probecmp.sh](oracle/probecmp.sh) and
  counted by [bench/run.zig](bench/run.zig).
- A probe line is agreed, known, listed in the [divergence register](#divergence-register), or
  fixed, where the register names a value the oracle is corrected to.
- `sizeprobe` is an unrelated object built to be measured,
  [bench/harness/sizeprobe.zig](bench/harness/sizeprobe.zig).

### Divergence register

The pinned file naming every [probe](#probe) line on which the library and the outside model
disagree, with the manual section deciding each and the side it decides for. The comparison
takes the listed lines out of the diff and fails if one ever stops disagreeing, so the file
describes the baseline as it is rather than as it was.

- [oracle/arm_divergences.txt](oracle/arm_divergences.txt) and
  [oracle/intc_divergences.txt](oracle/intc_divergences.txt), read as `register` by
  [oracle/probecmp.sh](oracle/probecmp.sh).
- "Register" here is the ledger, not a processor register; the word carries that sense only
  inside `oracle/probecmp.sh` and this entry.
