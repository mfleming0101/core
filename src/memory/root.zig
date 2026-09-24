//! The bus half of the library, gathered for core.memory. Regions and the types a consumer
//! builds one from, the clock, the map builder and the ELF loader. A processor is given one
//! bus and reaches every byte through it.
const regions = @import("regions.zig");

/// The address map the library ships: sorted memory blocks and devices, with the device schedule.
pub const Regions = regions.Regions;
/// A context pointer and the three or four functions something other than memory answers with.
pub const Device = regions.Device;
/// The size of a device access, in bytes.
pub const Width = regions.Width;
/// A set of interrupt lines, one bit each.
pub const Lines = regions.Lines;
/// One interrupt line, numbered as its family numbers it.
pub const Line = regions.Line;
/// The three one-block caches a processor fetches, loads and stores through.
pub const Folded = regions.Folded;
/// One folded block: its base, its length and the host bytes behind it, if any.
pub const Block = regions.Block;
/// What a lookup answers: the block an address falls in, and the device that owns it.
pub const Found = regions.Found;

/// The conversion between cycles and wall time, for a caller that runs the core against one.
pub const Clock = @import("clock.zig").Clock;

/// Turning a board described as data into a Regions over an arena.
pub const map = @import("map.zig");
/// Loading the segments of a firmware executable into memory.
pub const elf = @import("elf.zig");
