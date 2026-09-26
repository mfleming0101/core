//! Public surface of the Arm half, reached as core.arm. Re-exports the processor and
//! everything a caller names around it: its options, what a step and a run produce, the
//! limits and end reasons, the exception numbering, the core enum and its spec, the
//! stop enum, and the trace and semihosting modules.

/// The Arm core: the isa host, the private peripheral bus, the exceptions, the clock and the bus.
pub const Processor = @import("system/processor.zig").Processor;
/// The comptime configuration of a Processor: the cores it answers for and the bus type.
pub const Options = @import("system/processor.zig").Options;
/// What one step produced: the address, the class, its cost, what was charged and the stop.
pub const Step = @import("system/processor.zig").Step;
/// What one run produced, including the cycles spent in exception entry and return.
pub const Run = @import("system/processor.zig").Run;
/// What a run is bounded by: an instruction budget, a relative cycle deadline, and whether a sleep ends it.
pub const Limit = @import("system/processor.zig").Limit;
/// Which bound ended a run: its budget, its deadline, the core stopping, or the core sleeping.
pub const Ended = @import("system/processor.zig").Ended;
/// A set of exception numbers, one bit each.
pub const Set = @import("system/processor.zig").Set;
/// The set holding one exception number.
pub const one = @import("system/processor.zig").one;
/// The NMI exception number.
pub const nmi = @import("system/processor.zig").nmi;
/// The PendSV exception number.
pub const pendsv = @import("system/processor.zig").pendsv;
/// The SysTick exception number.
pub const systick = @import("system/processor.zig").systick;
/// The exception number of IRQ 0, which every line is offset by.
pub const first_interrupt = @import("system/processor.zig").first_interrupt;
/// Where the Non-secure aliases of the exception numbers begin.
pub const ns_base = @import("system/processor.zig").ns_base;
/// The Cortex-M cores this half models.
pub const Core = @import("system/core.zig").Core;
/// The spec of a core, selected at compile time.
pub const spec = @import("system/core.zig").spec;
/// What a part was built with, which Processor.init takes.
pub const Part = @import("system/core.zig").Part;
/// Why the core is standing still: isa's seventeen reasons a step halted.
pub const Stop = @import("isa").arm.Stop;
/// The instruction class a step reports, which the cycle table is indexed by.
pub const Class = @import("isa").arm.instruction.Class;
/// isa's decode groups and the selection an architecture runs with.
pub const decode = @import("isa").arm.decode;
/// The record, the ring, the line renderer and explain for this family.
pub const trace = @import("trace.zig");
/// Recognising and performing a semihosting call made through BKPT 0xab.
pub const semihosting = @import("semihosting.zig");
