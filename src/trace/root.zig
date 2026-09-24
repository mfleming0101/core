//! The trace both families share, gathered for core.trace. The ring is the only export; the
//! record it holds and the line it renders as belong to the family module that instantiates it.
/// The record ring, over whichever record a family writes.
pub const Ring = @import("ring.zig").Ring;
