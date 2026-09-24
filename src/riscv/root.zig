//! Public surface of the RISC-V half, reached as core.riscv. Re-exports the processor and
//! everything a caller names around it: its options, what a step and a run produce, the
//! limits and end reasons, the part enum and its spec, the stops, and the trace and
//! semihosting modules.

/// The RISC-V hart: the isa host, the interrupt matrix, the PMP, the clock and the bus.
pub const Processor = @import("system/processor.zig").Processor;
/// The comptime configuration of a Processor: the cores it answers for and the bus type.
pub const Options = @import("system/processor.zig").Options;
/// What one step produced: the address, the class, its cost, what was charged and the stop.
pub const Step = @import("system/processor.zig").Step;
/// What one run produced: the instructions retired, the cycles charged, the stop and which bound it hit.
pub const Run = @import("system/processor.zig").Run;
/// What a run is bounded by: an instruction budget, a relative cycle deadline, and whether a sleep ends it.
pub const Limit = @import("system/processor.zig").Limit;
/// Which bound ended a run: its budget, its deadline, the core stopping, or the core sleeping.
pub const Ended = @import("system/processor.zig").Ended;
/// The Espressif parts this half models.
pub const Core = @import("system/core.zig").Core;
/// The spec of a part, selected at compile time.
pub const spec = @import("system/core.zig").spec;
/// Why the hart is standing still: isa's three, everything else being a trap it already took.
pub const Stop = @import("isa").riscv.Stop;
/// The instruction class a step reports, which the cycle table is indexed by.
pub const Class = @import("isa").riscv.instruction.Class;
/// isa's decode groups, which a Spec names and a one-core build prunes the tree to.
pub const decode = @import("isa").riscv.decode;
/// The record, the ring, the line renderer and explain for this family.
pub const trace = @import("trace.zig");
/// Recognising and performing a semihosting call made through EBREAK.
pub const semihosting = @import("semihosting.zig");
