# Library glossary

This glossary fixes one name per concept for `core`, the Zig emulator library that puts a processor,
its memory map and its system blocks around the `isa` instruction-set package, for Arm Cortex-M and
Espressif RV32 parts. It covers the library's own vocabulary first --- the processor, the bus and
the folded caches, regions and devices, spans, stops and run limits, the trace ring, maps and
images --- then the measurement vocabulary a contributor meets under `bench/`, and last the Arm and
RISC-V terms the library leans on, with core's particular use of each. One name per concept: where a
word could mean two things, the entry says which meaning core keeps and why. Links are relative to
the repository root and point at the declaration where there is a single one.

## Access

The comptime record core passes to [span](#span) and to the `access` lane beneath it, saying what
the memory operation is: `.kind` is `.fetch`, `.read`, `.write` or `.vector`, and `.bytes` is its
size in bytes. Core declares the type where `isa` builds it anonymously at each call site, so both
halves of core agree on the field names.

`Access`, [src/contract.zig](src/contract.zig), with `Kind` at
[src/contract.zig](src/contract.zig) and `Failure`, the errors the lane may raise, at
[src/contract.zig](src/contract.zig).

`.vector` is core's own fifth kind, the read of an exception vector, which the Arm half needs
because a vector read that no memory answers must lock the core rather than be forgiven by
`BFHFNMIGN`. RISC-V folds `.vector` onto `.read`.

See also: [Span](#span), [Touch](#touch), [Host contract](#host-contract), [Width](#width).

## Alternative

One measured implementation the [bench](#machine) drives, written into the `alt` column of a
[row](#row) under its own name. Core has one, `folded-tree`, named for the [Folded](#folded) cache
in front of the generated decode tree.

`alt`, [bench/run.zig](bench/run.zig); the column is `Row.alt`,
[bench/harness/metrics.zig](bench/harness/metrics.zig).

See also: [Row](#row), [Machine](#machine), [Null ISA](#null-isa), [Stub host](#stub-host).

## Architecture

One M-profile architecture version, `isa`'s enum. A [Spec](#spec) names one, and it is what the
processor answers to `isa`'s `architecture` contract entry; it decides whether unaligned single
accesses are answered, which APSR bits an MSR write reaches, and which decode groups the tree is
pruned to.

The field is `Spec.architecture`, [src/arm/system/core.zig](src/arm/system/core.zig).

RISC-V has no architecture; an ESP32-C part is described by its group set alone, `Spec.groups` at
[src/riscv/system/core.zig](src/riscv/system/core.zig).

See also: [Spec](#spec), [Core](#core), [Family](#family).

## Bus

The comptime type the [processor](#processor) reaches memory through: whatever the consumer passes
as `Options.Bus`. [Regions](#regions) is the one core ships, and a consumer may pass anything with
the same `lookup`, `folded`, `peek`, `poke`, `parcel`, `follow`, `untilDue`, `interrupts` and
`asserted` surface.

`Options.Bus`, [src/arm/system/processor.zig](src/arm/system/processor.zig) and
[src/riscv/system/processor.zig](src/riscv/system/processor.zig).

The type is `Bus` and the field that holds one is `Processor.memory`. The bench uses "bus" for a
third thing, the function that builds a `Regions` out of a [map](#map) and an
[image](#image), `consumer.bus` at
[bench/harness/consumer.zig](bench/harness/consumer.zig); that use is confined to `bench/`.

See also: [Regions](#regions), [Processor](#processor), [Options](#options), [Folded](#folded).

## Charge

To add cycles to the processor's own count, and the only way that count moves. Charging is also what
services the bus: once the count passes the standing attention point, the [devices](#device) are
ticked, [SysTick](#systick) is advanced and the [deadline](#deadline) is re-checked.

`Processor.charge`, [src/arm/system/processor.zig](src/arm/system/processor.zig) and
[src/riscv/system/processor.zig](src/riscv/system/processor.zig).

[Clock](#clock) has a `charge` of its own that converts cycles to picoseconds
([src/memory/clock.zig](src/memory/clock.zig)); the two are the same verb over the same
quantity, one counting cycles and one counting time.

See also: [Run](#run), [Step](#step), [Clock](#clock), [Deadline](#deadline).

## Clock

The conversion between cycles and wall time, kept as picoseconds so a frequency that does not divide
a second exactly loses nothing: `hz`, `per` picoseconds per cycle, `rem` the leftover, `owed` the
running fraction and `ps` the picoseconds spent.

`Clock`, [src/memory/clock.zig](src/memory/clock.zig), built by `Clock.at(hz)` at
[src/memory/clock.zig](src/memory/clock.zig).

`Clock.bank` ([src/memory/clock.zig](src/memory/clock.zig)) changes the frequency and keeps
the picoseconds already spent. It is an unrelated use of the word core otherwise keeps for the
Arm banked registers.

See also: [Charge](#charge), [Deadline](#deadline).

## Core

A part this library models, by name: `m0`, `m0plus`, `m1`, `m23`, `m3`, `m4`, `m7`, `m33`, `m55`,
`m85`, `esp32c3`, `esp32c6`. The [family](#family) enum is the union of both halves; each half has
its own narrower enum.

`core.Core`, [src/family.zig](src/family.zig); `core.arm.Core`,
[src/arm/system/core.zig](src/arm/system/core.zig); `core.riscv.Core`,
[src/riscv/system/core.zig](src/riscv/system/core.zig).

The word also names the library itself, and the bench's [divergence registers](#divergence-register)
write `core=` for the library's answer. A `Core` value is always the part.

See also: [Family](#family), [Spec](#spec), [Options](#options).

## Corpus

The firmware the library is run against and the manifest that pins what each image must retire,
where it must stop and what it must print. `corpus/src` holds the C programs, `corpus/maps` the
[maps](#map) they run on, `corpus/port` the two startup ports, and `corpus/diag` the diagnosis cases
whose expected explanations are checked line by line.

`corpus/manifest.zon` and `corpus/diag/manifest.zon`, read by
[bench/run.zig](bench/run.zig).

See also: [Tier](#tier), [Oracle](#oracle), [Row](#row), [Map](#map).

## Deadline

A cycle count a run must not pass. `Limit.cycles` sets one relative to the processor's current
count; [Regions](#regions) and [SysTick](#systick) each answer the next cycle at which they want
attention, and the processor keeps the soonest of the three.

`Limit.cycles`, [src/arm/system/processor.zig](src/arm/system/processor.zig);
`Regions.untilDue`, [src/memory/regions.zig](src/memory/regions.zig);
`SysTick.deadline`, [src/arm/system/systick.zig](src/arm/system/systick.zig).

A run that reaches one answers `Ended.deadline`. "Deadline" is always a cycle count, never a time;
the picoseconds live in the [Clock](#clock).

See also: [Limit](#limit), [Ended](#ended), [Charge](#charge), [Run](#run).

## Device

Something in the address space that is not memory: a set of five function pointers over an opaque
context, `read` and `write` at an offset from its own base, an optional `tick` that keeps time, and
an optional `asserted` that says which [lines](#line-and-lines) it holds high. `read` and `write`
answer `null` to refuse; `tick` answers the cycles until it next wants to be ticked, zero for the
next cycle, and `null` for never.

`Device`, [src/memory/regions.zig](src/memory/regions.zig).

`map.Device` ([src/memory/map.zig](src/memory/map.zig)) is the entry in a [map](#map) that
asks for one by model name; the built object is this `Device`.

See also: [Regions](#regions), [Line and lines](#line-and-lines), [Raise word](#raise-word),
[Map](#map), [Width](#width).

## Divergence register

The pinned file naming every [probe](#probe) line on which the library and the outside model
disagree, with the manual section that decides each and which side it decides for. The comparison
takes the listed lines out of the diff and fails if one of them ever stops disagreeing, so the file
describes the baseline as it is rather than as it was.

[oracle/arm_divergences.txt](oracle/arm_divergences.txt) and
[oracle/intc_divergences.txt](oracle/intc_divergences.txt), read as `register` by
[oracle/probecmp.sh](oracle/probecmp.sh).

"Register" here is the ledger, not a processor register; the word carries that sense only inside
`oracle/probecmp.sh` and this entry.

See also: [Probe](#probe), [Oracle](#oracle), [Tier](#tier).

## Ended

Which bound stopped a [run](#run): `budget` when the instruction count ran out, `deadline` when the
cycle count did, `stopped` when the core halted. It is the one answer that always distinguishes the
three, because a run that ends on its budget and a run that ends on a stop both come back with
instructions retired.

`Ended`, [src/arm/system/processor.zig](src/arm/system/processor.zig) and
[src/riscv/system/processor.zig](src/riscv/system/processor.zig).

See also: [Run](#run), [Limit](#limit), [Stop](#stop), [Deadline](#deadline).

## Exception

An entry the processor takes on its own between two instructions, rather than as part of one: an
Arm exception or a RISC-V interrupt or [trap](#trap). Both halves count them in `Processor.exceptions`
and count the interrupt subset in `Processor.irqs`; the Arm half also accumulates the cycles spent
entering and leaving in `Processor.latency`, and reports them as `Run.latency`.

`Run.latency`, [src/arm/system/processor.zig](src/arm/system/processor.zig). The RISC-V
`Run` has no such field, [src/riscv/system/processor.zig](src/riscv/system/processor.zig),
because no ESP32-C reference publishes an entry latency.

An entry appears in the [trace](#trace) as a [record](#record) whose note kind is `.entry` or
`.irq`, [src/trace/text.zig](src/trace/text.zig).

See also: [Trap](#trap), [Stop](#stop), [NVIC and SCB](#nvic-and-scb),
[Interrupt matrix](#interrupt-matrix), [Record](#record).

## Family

Which instruction set a [core](#core) belongs to, `arm` or `riscv`, and the word for each half of
the library. `core.arm` and `core.riscv` are the two family modules, and every type that exists once
per family --- `Processor`, `Options`, `Step`, `Run`, `Limit`, `Ended`, `Core`, `Stop`, `trace`
--- is reached through one of them.

`Family`, [src/family.zig](src/family.zig); `family.of`, [src/family.zig](src/family.zig),
re-exported as `core.familyOf`, [src/core.zig](src/core.zig).

The prose says "family", never "architecture", which is Arm's word for a version of the instruction
set and the name of [Architecture](#architecture).

See also: [Core](#core), [Architecture](#architecture), [Processor](#processor).

## Folded

The three one-block caches the [processor](#processor) fetches, loads and stores through: one
`Block` per access kind, each holding the base, the length and the host pointer of the largest run
of addresses that answers the same way. A hit is a subtraction and a compare; anything else refolds.
A refused run is remembered too, in `refused`, so a hole is not looked up twice.

`Folded`, [src/memory/regions.zig](src/memory/regions.zig); the cache lives in
`Regions.folded` and is emptied by `Folded.unfold`,
[src/memory/regions.zig](src/memory/regions.zig).

Folding is what makes a whole [span](#span) safe to answer in place: everything that could refuse
the access --- the [MPU](#mpu) or [PMP](#pmp), the [PPB](#ppb) or [interrupt matrix](#interrupt-matrix)
window, the region's own bounds, whether it is writable --- has already been asked once for the whole
block. Anything that could change an answer must unfold.

See also: [Span](#span), [Regions](#regions), [Found](#found), [Bus](#bus).

## Found

What a [Regions](#regions) lookup answers: the base and length of the entry that holds the address,
its host bytes if it is memory, whether it is writable, and the index of the [device](#device) if it
is one. A lookup that lands in a hole answers the bounds of the hole with no host bytes, which is
what lets a refusal be [folded](#folded) as wide as the hole.

`Found`, [src/memory/regions.zig](src/memory/regions.zig), answered by `Regions.lookup`,
[src/memory/regions.zig](src/memory/regions.zig).

See also: [Regions](#regions), [Folded](#folded), [Device](#device).

## Gate

In `bench/`, a correctness column a [row](#row) must hold before its status may be `pass`: both
[oracle](#oracle) comparisons, both [probe](#probe) comparisons, the [corpus](#corpus) and diagnosis
counts, the burst equivalence and the invariant violations.

`metrics.gated`, [bench/harness/metrics.zig](bench/harness/metrics.zig).

The word means two other things elsewhere and both are local. `Intc.best` takes a `gate`, the word
of enabled interrupt ids ([src/riscv/system/intc.zig](src/riscv/system/intc.zig)), and
each processor has a private comptime `gate` or `leaf_gate`, the group set a one-core build prunes
the decode tree to.

See also: [Row](#row), [Oracle](#oracle), [Probe](#probe), [Tier](#tier).

## Hart

RISC-V's hardware thread: the one register file, program counter and privilege mode an ESP32-C part
has. Core models exactly one, and the RISC-V half's prose says "hart" wherever the RISC-V specs do,
in particular for the CSRs that belong to the hart as against the [PMP](#pmp) registers that belong
to the platform and the [interrupt matrix](#interrupt-matrix) that belongs to the chip.

The state is `isa`'s `riscv.State`, held as `Processor.state`,
[src/riscv/system/processor.zig](src/riscv/system/processor.zig).

The Arm half says "core" for the same idea, after Arm's own word.

See also: [Core](#core), [PMP](#pmp), [Trap](#trap), [Interrupt matrix](#interrupt-matrix).

## Host contract

What `isa` requires of whatever runs its rows, and what core's [processor](#processor) answers: the
three memory declarations `span`, `access` and `touch`, plus the configuration, notification and
floating-point answers each architecture asks for. Core does not declare the list --- `isa` does ---
but `bench/` spells it out entry by entry with the reason each is answered the way it is, and counts
the entries into the row's `isa_decls_required` and `isa_decls_optional`.

`isa_requirements`, [bench/arm/machine.zig](bench/arm/machine.zig), counted by `required` and
`optional`, [bench/harness/contract.zig](bench/harness/contract.zig). The helpers the
two memory entries are written in terms of are `contract.read` and `contract.write`,
[src/contract.zig](src/contract.zig) and [src/contract.zig](src/contract.zig).

An individual entry is a requirement.

See also: [Access](#access), [Span](#span), [Touch](#touch), [Processor](#processor),
[Machine](#machine).

## Image

A firmware binary a region is loaded from. A [map](#map) names one per region by path, and the ELF
loader places every `PT_LOAD` segment of an executable at its physical address, zeroing the rest of
each segment's memory size.

`map.Image`, the two ways a named image can fail,
[src/memory/map.zig](src/memory/map.zig); `elf.load`,
[src/memory/elf.zig](src/memory/elf.zig), with `elf.Failure` at
[src/memory/elf.zig](src/memory/elf.zig).

The bench also calls the ELF it runs an image, and a [corpus](#corpus) manifest entry is one; that
is the same thing seen from outside.

See also: [Map](#map), [Regions](#regions), [Corpus](#corpus).

## Interrupt matrix

The Espressif block in front of the [hart](#hart): a table that routes each of the part's sources to
one of thirty-two CPU interrupts, with per-id enable, type, priority and threshold registers, and on
the C6 a software register a program raises its own interrupt through. Core models its registers, its
level and edge latches and its priority choice, and answers CSR reads of `mip` from it where the part
has one.

`Intc`, [src/riscv/system/intc.zig](src/riscv/system/intc.zig); the per-part register
addresses are `Layout`, [src/riscv/system/intc.zig](src/riscv/system/intc.zig), named by
`Spec.intc`.

A *source* is a device's [line](#line-and-lines), numbered as the part numbers it; an *id* is the
CPU interrupt it is routed to, and is what the vector is chosen by. `Intc.routed` maps one to the
other, [src/riscv/system/intc.zig](src/riscv/system/intc.zig).

See also: [Line and lines](#line-and-lines), [Raise word](#raise-word), [Hart](#hart),
[Exception](#exception).

## Limit

What a [run](#run) is bounded by: `instructions`, which has no default and is the reason `run` was
called, and `cycles`, a relative cycle budget that defaults to no bound at all.

`Limit`, [src/arm/system/processor.zig](src/arm/system/processor.zig) and
[src/riscv/system/processor.zig](src/riscv/system/processor.zig).

`Limit.cycles` is counted from where the processor already is, not from zero; the absolute cycle it
becomes is the run's [deadline](#deadline).

See also: [Run](#run), [Ended](#ended), [Deadline](#deadline), [Charge](#charge).

## Line and lines

One interrupt line a [device](#device) can raise, and the word of two hundred and forty of them that
carries a set. A line is a number in `Line`; a set of lines is a `Lines`. Both halves of the library
use the same pair, so one device model can sit on either.

`lines`, `Lines` and `Line`, [src/memory/regions.zig](src/memory/regions.zig) through
[src/memory/regions.zig](src/memory/regions.zig), re-exported as `core.memory.Lines` and
`core.memory.Line`.

On Arm a line is an IRQ number, offset by sixteen from the exception number the [NVIC](#nvic-and-scb)
registers use. On RISC-V it is an [interrupt matrix](#interrupt-matrix) source, which the matrix
routes to an id. `Processor.pend` takes a `Lines`, a whole set; `Processor.enabled` takes a `Line`, a
single number.

See also: [Device](#device), [Raise word](#raise-word), [NVIC and SCB](#nvic-and-scb),
[Interrupt matrix](#interrupt-matrix).

## Machine

In `bench/`, the wrapper that puts one measured [processor](#processor) behind the one command-line
program every measurement drives: it loads a [map](#map) and an [image](#image), runs, steps, bursts,
snapshots, explains, and answers the size and interface constants the [row](#row) reports. One per
family.

`Machine`, [bench/arm/machine.zig](bench/arm/machine.zig) and
[bench/riscv/machine.zig](bench/riscv/machine.zig); the comptime check is
`assertMachine`, [bench/harness/facade.zig](bench/harness/facade.zig), and the program over
it is `Consumer`, [bench/harness/consumer.zig](bench/harness/consumer.zig).

A machine is not a [host](#host-contract): a host answers the instruction set, a machine answers the
harness.

See also: [Stub host](#stub-host), [Null ISA](#null-isa), [Row](#row), [Alternative](#alternative).

## Map

The description of one board: which [core](#core) it carries, which regions of memory it has and what
each is loaded from, which [devices](#device) sit where, and optionally the ELF to run. A map is data
--- the corpus keeps them as `.zon` --- and `map.build` turns one into [Regions](#regions) over an
arena.

`Map`, [src/memory/map.zig](src/memory/map.zig); `map.build`,
[src/memory/map.zig](src/memory/map.zig).

A `map.Region` ([src/memory/map.zig](src/memory/map.zig)) is the *request*; a
`Regions.Memory` ([src/memory/regions.zig](src/memory/regions.zig)) is the built entry. The
device models a map may name live in a `Registry`,
[src/memory/map.zig](src/memory/map.zig), and whatever the builder refused is left behind in
a `Blame`, [src/memory/map.zig](src/memory/map.zig), for the caller to report.

See also: [Regions](#regions), [Image](#image), [Device](#device), [Core](#core).

## MPU

Arm's Memory Protection Unit. Core models the v7-M and v8-M forms in one block and asks it twice:
once per access on the slow path, and once per [fold](#folded) to bound the block a [span](#span) may
run over. How many regions a part has is a [Spec](#spec) field, and a part with none is a unit that
is never enabled.

`Mpu`, [src/arm/system/mpu.zig](src/arm/system/mpu.zig), reached as `Processor.mpu` and
`Processor.mpu_ns`; `Spec.mpu_regions`,
[src/arm/system/core.zig](src/arm/system/core.zig).

`mpu.regions` ([src/arm/system/mpu.zig](src/arm/system/mpu.zig)) is the count of protection
regions, which is a different thing from the [Regions](#regions) that are the address map. The
protection ones are always qualified in prose.

See also: [PMP](#pmp), [SAU](#sau), [Folded](#folded), [Spec](#spec).

## Null ISA

A stand-in for the `isa` package with the same shape and no instruction semantics, so the library can
be built and measured without the instruction set in it. `-Disa=null` links it everywhere; otherwise
it is linked only into the size probe and the `machine-null-*` binaries, whose object sizes are what
the real ones are subtracted from.

[bench/nullisa/root.zig](bench/nullisa/root.zig), selected at
[build.zig](build.zig).

See also: [Machine](#machine), [Stub host](#stub-host), [Row](#row).

## NVIC and SCB

Arm's Nested Vectored Interrupt Controller and System Control Block: the enable, pending, active and
priority words for up to two hundred and forty interrupts, and the identity, control, vector-table
and fault-status registers beside them. Core models both, banks the SCB for a part with the Security
Extension, and takes the highest-priority pending exception at each service point.

`Nvic`, [src/arm/system/nvic.zig](src/arm/system/nvic.zig), and `Scb`,
[src/arm/system/scb.zig](src/arm/system/scb.zig), reached as `Processor.nvic`,
`Processor.scb` and `Processor.scb_ns`. Which SCB registers a part has is a `Profile`,
[src/arm/system/scb.zig](src/arm/system/scb.zig).

The NVIC counts in [lines](#line-and-lines), from IRQ 0; the processor counts in exception numbers,
where IRQ 0 is 16 and the Non-secure aliases begin above them all. How many priority bits a part
implements is `Spec.priority_bits`,
[src/arm/system/core.zig](src/arm/system/core.zig).

See also: [Line and lines](#line-and-lines), [Exception](#exception), [PPB](#ppb), [Spec](#spec),
[Interrupt matrix](#interrupt-matrix).

## Options

The comptime configuration of a [Processor](#processor): `cores`, the list of [cores](#core) one
build answers for, and `Bus`, the memory type it reaches through. A build naming one core prunes the
decode tree to that core's groups; the default names every core of the family, which builds the
widest tree.

`Options`, [src/arm/system/processor.zig](src/arm/system/processor.zig) and
[src/riscv/system/processor.zig](src/riscv/system/processor.zig).

`cores` is the set a build can be *initialised* with; `Processor.init` takes the one it *is*.

See also: [Processor](#processor), [Core](#core), [Bus](#bus), [Spec](#spec).

## Oracle

An outside authority the library is compared against, and the pinned files holding its answers: QEMU
for the Arm traces and probe, Espressif's QEMU and Sail for the RISC-V ones. Every comparison is
against a file in `oracle/`, never against a tool run at measurement time, and a
[divergence register](#divergence-register) records where the two are known to differ and why.

[oracle/](oracle/); the trace pins are `oracle/trace_*.txt` and the probe pins
`oracle/probe_arm.txt` and `oracle/probe_riscv.txt`.

See also: [Probe](#probe), [Divergence register](#divergence-register), [Tier](#tier),
[Corpus](#corpus).

## Peek and poke

The two ways to reach memory from outside an instruction: `peek` reads a word of the given byte width
and answers `null` if nothing did, `poke` writes one and answers `null` if nothing took it. Both
exist on the [processor](#processor), where they go through the [MPU](#mpu) or [PMP](#pmp) and the
peripheral windows, and on [Regions](#regions), where they do not.

`Processor.peek` and `Processor.poke`,
[src/arm/system/processor.zig](src/arm/system/processor.zig) and
[src/arm/system/processor.zig](src/arm/system/processor.zig);
`Regions.peek` and `Regions.poke`,
[src/memory/regions.zig](src/memory/regions.zig) and
[src/memory/regions.zig](src/memory/regions.zig).

Their first parameter is a [width](#width) in bytes, not bits.

See also: [Width](#width), [Span](#span), [Regions](#regions), [Processor](#processor).

## PMP

RISC-V's Physical Memory Protection unit: sixteen entries of configuration and address, in `off`,
`tor`, `na4` or `napot` mode. Core answers `isa`'s `readPmp` and `writePmp` from it, asks it once per
access on the slow path and once per [fold](#folded), and empties the folded cache on every write,
since one write can change every answer.

`Pmp`, [src/riscv/system/pmp.zig](src/riscv/system/pmp.zig), reached as `Processor.pmp`;
`Processor.readPmp` and `writePmp`,
[src/riscv/system/processor.zig](src/riscv/system/processor.zig).

Whether an entry's priority is static or the highest-numbered match wins is a part property,
`Spec.pmp_static_priority`,
[src/riscv/system/core.zig](src/riscv/system/core.zig).

See also: [MPU](#mpu), [Folded](#folded), [Hart](#hart), [Spec](#spec).

## PPB

Arm's Private Peripheral Bus, the megabyte at `0xe0000000` that holds the system blocks: the
[SCB](#nvic-and-scb), the [NVIC](#nvic-and-scb), [SysTick](#systick), the [DWT](#systick), the
[MPU](#mpu), the [SAU](#sau) and the Non-secure aliases of the banked ones. Core routes an access by
address to the block that answers it, and never [folds](#folded) any of it, so a peripheral read is
always a call.

`ppb.region`, [src/arm/system/ppb.zig](src/arm/system/ppb.zig), over the `Region` enum at
[src/arm/system/ppb.zig](src/arm/system/ppb.zig).

The RISC-V half's equivalent is `Intc.region`,
[src/riscv/system/intc.zig](src/riscv/system/intc.zig), over the two
[interrupt matrix](#interrupt-matrix) windows; both enums have a `.memory` member meaning "not a
peripheral".

See also: [NVIC and SCB](#nvic-and-scb), [SysTick](#systick), [Folded](#folded),
[Interrupt matrix](#interrupt-matrix).

## Probe

A firmware that reads every system register the part has and prints one `name=value` line per
register, run on both the library and the [oracle](#oracle) and compared line by line. It measures
the register model, where the [tier](#tier)-two traces measure the running core.

[oracle/probe/](oracle/probe/), compared by
[oracle/probecmp.sh](oracle/probecmp.sh) and counted by
[bench/run.zig](bench/run.zig).

A probe line is either agreed, known --- listed in the [divergence register](#divergence-register)
--- or fixed, where the register names a value the oracle is corrected to. `sizeprobe` is an unrelated
object built to be measured, [bench/harness/sizeprobe.zig](bench/harness/sizeprobe.zig).

See also: [Oracle](#oracle), [Divergence register](#divergence-register), [Tier](#tier),
[Row](#row).

## Processor

The core of the library: one comptime-configured struct holding the [isa](#host-contract) state, the
[spec](#spec) of the part it is, the system blocks, the [bus](#bus), the pending and active exception
sets, the cycle count and the [trace ring](#ring). It answers every [host contract](#host-contract)
entry the instruction set asks, so the instruction set never sees anything else.

`Processor`, [src/arm/system/processor.zig](src/arm/system/processor.zig) and
[src/riscv/system/processor.zig](src/riscv/system/processor.zig); built by `init`,
[src/arm/system/processor.zig](src/arm/system/processor.zig), and put into its reset state
by `reset`, [src/arm/system/processor.zig](src/arm/system/processor.zig).

The prose says "processor" for the whole thing and "core" for the part it models; the bench calls its
wrapper a [machine](#machine). The variable is `cpu` in the examples and the bench.

See also: [Options](#options), [Spec](#spec), [Run](#run), [Step](#step), [Bus](#bus).

## Raise word

The `*Lines` a [device](#device) is handed on every call, which it sets bits in to ask for an
interrupt. Nothing is taken at the moment of the write: the [bus](#bus) holds the word, the processor
collects it at its next service point, and only then does a line become pending.

The parameter is `raise`, [src/memory/regions.zig](src/memory/regions.zig); the word the bus
accumulates into is `Regions.raised`, and `Regions.interrupts`
([src/memory/regions.zig](src/memory/regions.zig)) hands it to the processor and clears it.

A device that holds a line high rather than pulsing it answers `Regions.asserted`
([src/memory/regions.zig](src/memory/regions.zig)) instead; raising is the edge and
asserting is the level.

See also: [Line and lines](#line-and-lines), [Device](#device), [Regions](#regions),
[Exception](#exception).

## Record

One line of the [trace ring](#ring): the address, the [code](#step) if one was fetched, the registers
whose values changed and what they became, the first address the instruction touched, the cycle count
at the time, and a note saying whether it retired, entered a handler, took an interrupt, returned or
was refused.

`Record`, [src/arm/trace.zig](src/arm/trace.zig) and
[src/riscv/trace.zig](src/riscv/trace.zig); the note is `Note`,
[src/trace/text.zig](src/trace/text.zig).

The register names a record is rendered against are `register_names`,
[src/arm/trace.zig](src/arm/trace.zig) and
[src/riscv/trace.zig](src/riscv/trace.zig). The Arm list is `r0` to `r12`, the selected stack
pointer, `lr` and `xpsr`; the RISC-V list is the ABI names of `x1` to `x31`, so the two halves index
their own registers differently.

See also: [Ring](#ring), [Trace](#trace), [Step](#step), [Stop](#stop).

## Regions

The address map, and the [bus](#bus) core ships: a sorted, non-overlapping list of memory blocks and
[devices](#device), a binary search over it, the [folded](#folded) caches, the device schedule and the
[raise word](#raise-word). It is built once from a [map](#map) or by hand, and it is what a
[Processor](#processor) is given.

`Regions`, [src/memory/regions.zig](src/memory/regions.zig), built by `Regions.adopt`,
[src/memory/regions.zig](src/memory/regions.zig), which sorts the entries it is given and
refuses an empty, wrapping or overlapping one.

The word is plural because the thing is the whole map; one element is a `Regions.Entry`,
[src/memory/regions.zig](src/memory/regions.zig). The [MPU](#mpu)'s protection regions are a
different thing with the same word.

See also: [Map](#map), [Device](#device), [Folded](#folded), [Found](#found), [Bus](#bus).

## Ring

The fixed, allocation-free history the [trace](#trace) is kept in: the caller hands the processor a
slice of [records](#record) at `init`, and the ring keeps the newest of them and counts every one
ever written. A zero-length slice means the processor does not trace at all, which is the fast path.

`Ring`, [src/trace/ring.zig](src/trace/ring.zig), re-exported as `core.trace.Ring`
([src/trace/root.zig](src/trace/root.zig)) and instantiated per family as
`core.arm.trace.Ring` ([src/arm/trace.zig](src/arm/trace.zig)) and
`core.riscv.trace.Ring` ([src/riscv/trace.zig](src/riscv/trace.zig)).

`Ring.written` is how many records have been written, not how many are held; `Ring.at(0)` is the
newest and `Ring.at(n)` counts backwards. `Ring.init` refuses a slice whose length is not a power of
two.

See also: [Record](#record), [Trace](#trace), [Processor](#processor).

## Row

In `bench/`, one line of `bench/summary.tsv` or `bench/release-metrics.tsv`: provenance, every
correctness [gate](#gate), nanoseconds per instruction at each [tier](#tier), the sizes, the build
times and the interface counts. A row is written even when a gate fails, with `status` set to `fail`,
so a regression stays in the history.

`Row`, [bench/harness/metrics.zig](bench/harness/metrics.zig); the header and line renderers
are [bench/harness/metrics.zig](bench/harness/metrics.zig) and
[bench/harness/metrics.zig](bench/harness/metrics.zig).

`bench/detail.tsv` holds one line per image rather than per run; its header is
[bench/run.zig](bench/run.zig). A "row" of the `isa` package's instruction table is a
different thing entirely, and core never uses the word that way.

See also: [Gate](#gate), [Tier](#tier), [Alternative](#alternative), [Machine](#machine).

## Run

What a run of the core produced: the instructions retired, the cycles charged, the [stop](#stop) if
there was one, and the [Ended](#ended) reason that says which bound it hit. Every count is *for that
run*, not a running total; the totals are the processor's own fields.

`Run`, [src/arm/system/processor.zig](src/arm/system/processor.zig) and
[src/riscv/system/processor.zig](src/riscv/system/processor.zig); the function is
`Processor.run`, [src/arm/system/processor.zig](src/arm/system/processor.zig) and
[src/riscv/system/processor.zig](src/riscv/system/processor.zig).

`run` is the loop, `Run` is what it answers and [Limit](#limit) is what bounds it. The Arm `Run`
carries a `latency` the RISC-V one does not.

See also: [Limit](#limit), [Ended](#ended), [Step](#step), [Stop](#stop), [Charge](#charge).

## SAU

Arm's Security Attribution Unit: eight regions saying which addresses are Non-secure and which are
Non-secure callable. Core models it for parts whose [spec](#spec) has `security`, answers `isa`'s
`attribute` entry from it, and reports its answer as an `Attribution`.

`Sau`, [src/arm/system/sau.zig](src/arm/system/sau.zig), reached as `Processor.sau`;
`Attribution`, [src/arm/system/sau.zig](src/arm/system/sau.zig).

See also: [MPU](#mpu), [Spec](#spec), [NVIC and SCB](#nvic-and-scb).

## Semihosting

The Arm convention by which firmware asks whoever is running it to do the I/O: a trapping instruction
with an operation number in one register and a parameter block address in another. Core implements
the console subset --- `SYS_OPEN` of `:tt`, `WRITEC`, `WRITE0`, `WRITE`, `ISTTY`, `EXIT` and
`EXIT_EXTENDED` --- once, over `peek`, and each family says only how the call is recognised and which
registers carry it.

`calls.call`, [src/semihosting/calls.zig](src/semihosting/calls.zig); the family wrappers are
[src/arm/semihosting.zig](src/arm/semihosting.zig) and
[src/riscv/semihosting.zig](src/riscv/semihosting.zig).

`trapped` is the test that the core stopped on a semihosting call rather than an ordinary
breakpoint: on Arm it is `BKPT 0xab` ([src/arm/semihosting.zig](src/arm/semihosting.zig)), on
RISC-V the three-instruction `EBREAK` sequence
([src/riscv/semihosting.zig](src/riscv/semihosting.zig)). Handling the call does not step over
it; the next [run](#run) does.

See also: [Stop](#stop), [Peek and poke](#peek-and-poke), [Run](#run).

## Span

The bytes the [bus](#bus) answers for from a given address onwards, and the name of the
[host contract](#host-contract) entry that returns them. An empty answer sends the instruction set to
the `access` lane instead. Because a span runs to the end of the [folded](#folded) block, a load
multiple and a two-parcel fetch cost one lookup.

`Processor.span`, [src/arm/system/processor.zig](src/arm/system/processor.zig) and
[src/riscv/system/processor.zig](src/riscv/system/processor.zig), over `Folded.span`,
[src/memory/regions.zig](src/memory/regions.zig).

"Span" means the slice of bytes and nothing else on the library surface. Two other uses are local:
`Regions.place` takes a `span` that is a byte count, the memory size of an ELF segment
([src/memory/regions.zig](src/memory/regions.zig)), and the bench's `--span` is a burst
length in instructions ([bench/harness/consumer.zig](bench/harness/consumer.zig)).

See also: [Access](#access), [Folded](#folded), [Touch](#touch), [Host contract](#host-contract).

## Spec

Everything core knows about one [core](#core) as a value: its [architecture](#architecture) or group
set, its published cycle table or `null` where no reference publishes one, its identity registers,
its reset defaults and which optional blocks it has. It is comptime data, selected by `spec(core)`,
and the [processor](#processor) holds a copy of the one it was built as.

`Spec`, [src/arm/system/core.zig](src/arm/system/core.zig) and
[src/riscv/system/core.zig](src/riscv/system/core.zig); `spec`,
[src/arm/system/core.zig](src/arm/system/core.zig) and
[src/riscv/system/core.zig](src/riscv/system/core.zig).

`Spec.cycles` is what one instruction of each class costs and `Spec.taken` what a taken branch adds;
both are `null` for a part whose reference publishes no table, and a processor built from such a spec
charges one cycle an instruction. `Spec.model`
([src/riscv/system/core.zig](src/riscv/system/core.zig)) is the RISC-V CSR implementation,
which is `isa`'s word, not a model of the part.

See also: [Core](#core), [Architecture](#architecture), [Charge](#charge), [Step](#step).

## Step

What one turn of the core produced: the address it ran at, the instruction [class](#spec) if one
retired, the cycles that class costs, the cycles actually charged, whether the fetch followed the one
before it, whether the core is asleep, and the [stop](#stop) if it halted.

`Step`, [src/arm/system/processor.zig](src/arm/system/processor.zig) and
[src/riscv/system/processor.zig](src/riscv/system/processor.zig); the function is
`Processor.step`, [src/arm/system/processor.zig](src/arm/system/processor.zig) and
[src/riscv/system/processor.zig](src/riscv/system/processor.zig).

`Step.cycles` is what the table says and is *not* charged --- stepping is how a chip that decides its
own timing drives the core, and it charges what it decided through
[`charge`](#charge). `Step.charged` is what the step itself already charged, which is the exception
entry and the sleep, not the instruction. `Run` charges both.

See also: [Run](#run), [Charge](#charge), [Spec](#spec), [Stop](#stop).

## Stop

Why the core is standing still instead of retiring: `isa`'s enum, re-exported by each family, and
also the [processor](#processor) field that holds the standing one. Arm has seventeen; RISC-V has
three, because everything else is a [trap](#trap) the core has already taken.

`core.arm.Stop`, [src/arm/root.zig](src/arm/root.zig), and `core.riscv.Stop`,
[src/riscv/root.zig](src/riscv/root.zig).

A `Run.stop` is the stop *that run* reached; `Processor.stop` is the one the core is standing at,
which the next run steps over if it is a breakpoint. The bench has a third, deliberately small `Stop`
that crosses the machine boundary,
[bench/harness/snapshot.zig](bench/harness/snapshot.zig), and it carries a `budget` member
core's does not, because there it stands for the whole reason a run ended.

See also: [Run](#run), [Ended](#ended), [Trap](#trap), [Step](#step), [Machine](#machine).

## Stub host

A bench machine that answers the [host contract](#host-contract) with constants over a flat window
and no system blocks at all, so a measurement of it is the instruction set and the loop alone. What a
row's own numbers are read against.

`stubhost.Arm` and `stubhost.Riscv`,
[bench/harness/stubhost.zig](bench/harness/stubhost.zig) and
[bench/harness/stubhost.zig](bench/harness/stubhost.zig).

Its inner type is called `Bus`, after the [bus](#bus) parameter it stands in for, though what it
answers is the instruction set's host contract rather than core's bus surface.

See also: [Machine](#machine), [Null ISA](#null-isa), [Host contract](#host-contract),
[Row](#row).

## SysTick

Arm's 24-bit system timer, and with it the DWT cycle counter: the two blocks whose value is a
function of the cycle count rather than of anything written to them. Core advances SysTick when it
services the bus and derives `DWT_CYCCNT` from the processor's own count, so neither costs anything
between service points.

`SysTick`, [src/arm/system/systick.zig](src/arm/system/systick.zig), advanced by
[src/arm/system/systick.zig](src/arm/system/systick.zig); `Dwt`,
[src/arm/system/dwt.zig](src/arm/system/dwt.zig).

`SysTick.deadline` ([src/arm/system/systick.zig](src/arm/system/systick.zig)) is the cycles
until it next wants attention, in the same sense as a [device](#device)'s `tick`.

See also: [Deadline](#deadline), [Charge](#charge), [PPB](#ppb), [Device](#device).

## Tier

How much of the library one measurement exercises. Tier one is the instruction set alone, the images
whose manifest entry says `source = "isa"`; tier two is the same run with the system blocks, the
devices and the interrupts in it. A [row](#row) reports nanoseconds per instruction for each.

`tierOf`, [bench/run.zig](bench/run.zig).

The columns are `fw_ns_per_instr` for tier one and `sys_ns_per_instr` for tier two,
[bench/harness/metrics.zig](bench/harness/metrics.zig).

See also: [Row](#row), [Corpus](#corpus), [Gate](#gate), [Probe](#probe).

## Touch

The [host contract](#host-contract) entry told the address a lookup was made at, once per lookup
rather than once per word. It is what feeds the fault address registers --- `MMFAR` and `BFAR` on
Arm, `mtval` on RISC-V --- and the [record](#record)'s access field.

`Processor.touch`, [src/arm/system/processor.zig](src/arm/system/processor.zig) and
[src/riscv/system/processor.zig](src/riscv/system/processor.zig).

The two halves do different work in it: the Arm one records only when the [ring](#ring) is
recording, the RISC-V one also breaks the LR/SC reservation.

See also: [Span](#span), [Access](#access), [Record](#record), [Host contract](#host-contract).

## Trace

The per-family module that turns core state into [records](#record) and records into text: the
register list, the snapshot, the ring type, the line renderer, and `explain`, which says in a
sentence why the core stopped and then prints the last lines that led there.

`core.arm.trace`, [src/arm/root.zig](src/arm/root.zig), and `core.riscv.trace`,
[src/riscv/root.zig](src/riscv/root.zig); the shared rendering is
[src/trace/text.zig](src/trace/text.zig).

`Processor.explain` ([src/arm/system/processor.zig](src/arm/system/processor.zig)) is the
processor's own wrapper, which adds what the system blocks say: the fault status registers on Arm,
the trap CSRs and the unrouted sources on RISC-V.

See also: [Record](#record), [Ring](#ring), [Stop](#stop).

## Trap

A RISC-V synchronous exception a row raised and the core has already taken, named for what happened
rather than for its `mcause` code. Core turns one into an `mcause` and an `mtval`, enters the handler
through `mtvec`, and remembers it for `explain`. Arm has no equivalent: an Arm fault is a
[stop](#stop) or an exception the processor takes for itself.

The remembered one is `Taken`,
[src/riscv/system/processor.zig](src/riscv/system/processor.zig); the enum it is made from is
`isa`'s `Trap`, and the codes are `isa`'s `csr.Cause`.

A trap that cannot be taken --- one raised at the handler's own first instruction --- becomes the
`unrecoverable_trap` [stop](#stop), which is the RISC-V counterpart of Arm lockup.

See also: [Stop](#stop), [Exception](#exception), [Hart](#hart).

## Width

A byte count, in every place core spells it `width`: `Device.read` and `Device.write` take the
`Width` enum, whose values *are* the byte counts, and `peek`, `poke` and `Word` take a plain `u8` of
bytes.

`Width`, [src/memory/regions.zig](src/memory/regions.zig); `contract.Word`,
[src/contract.zig](src/contract.zig).

The `isa` package uses `width` for a count of bits and `bytes` for a count of bytes. Core uses
`width` for bytes throughout and has no bit-counted parameter, so `peek(4, at)` is a 32-bit read.

See also: [Access](#access), [Peek and poke](#peek-and-poke), [Device](#device).
