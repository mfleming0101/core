//! The vocabulary a bus is reached with, and the two helpers every access goes through.
//! read and write ask for a span first and fall to the slow access lane when the span cannot
//! answer, telling the caller which unit refused through its blamed declaration. Both
//! processors serve their own loads, stores, vector reads, peek and poke from here, so a
//! debugger read sees exactly what the core sees.
const std = @import("std");

/// What a memory operation is. Vector is core's own kind, the read of an exception vector.
pub const Kind = enum { fetch, read, write, vector };

/// What the access lane may refuse with: nothing answered, a protection unit, the SAU.
pub const Failure = error{ DataFault, Violation, Secure };

/// What an access is: its kind and its size in bytes, declared once so both halves agree.
pub const Access = struct {
    kind: Kind,
    bytes: u8,
};

/// The unsigned integer a byte count reads and writes as.
pub fn Word(comptime bytes: u8) type {
    return std.meta.Int(.unsigned, @as(u16, bytes) * 8);
}

/// Reads through the span, falling to the access lane when the span is short; null if refused.
pub fn read(comptime C: type, c: *C, at: u32, comptime a: Access) ?Word(a.bytes) {
    const span = C.span(c, at, a);
    if (span.len < a.bytes) return @truncate(C.access(c, at, a, 0) catch |err| {
        if (@hasDecl(C, "blamed")) C.blamed(c, a, err);
        return null;
    });
    return std.mem.readInt(Word(a.bytes), span[0..a.bytes], .little);
}

/// Writes through the span, falling to the access lane when the span is short; null if refused.
pub fn write(comptime C: type, c: *C, at: u32, comptime a: Access, value: Word(a.bytes)) ?void {
    const span = C.span(c, at, a);
    if (span.len < a.bytes) {
        _ = C.access(c, at, a, value) catch |err| {
            if (@hasDecl(C, "blamed")) C.blamed(c, a, err);
            return null;
        };
        return;
    }
    std.mem.writeInt(Word(a.bytes), span[0..a.bytes], value, .little);
}
