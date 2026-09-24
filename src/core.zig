//! The module root. Everything a consumer reaches is exported here: the two family modules,
//! the bus, the trace ring, the vocabulary a bus is reached with, and the enum naming every
//! core of both families. Each family module carries its own narrower Core enum beside its
//! processor; this one is the union of the two.
const family = @import("family.zig");

/// Every core of both families in one enum.
pub const Core = family.Core;
/// Which instruction set a core belongs to, arm or riscv.
pub const Family = family.Family;
/// Answers which family a core belongs to.
pub const familyOf = family.of;

/// The Arm half: the processor, its system blocks, its trace record and semihosting.
pub const arm = @import("arm/root.zig");
/// The RISC-V half: the processor, the interrupt matrix, PMP, its trace record and semihosting.
pub const riscv = @import("riscv/root.zig");

/// The access kinds, the failure set and the two helpers a bus is reached through.
pub const contract = @import("contract.zig");
/// The bus: Regions, the device interface, the clock, the map builder and the ELF loader.
pub const memory = @import("memory/root.zig");
/// The record ring both families instantiate.
pub const trace = @import("trace/root.zig");
