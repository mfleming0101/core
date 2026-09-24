//! The two enums that span both halves of the library: every core by name, and the family a
//! core belongs to. core.zig re-exports all three as Core, Family and familyOf. Each family
//! module keeps its own narrower Core enum.
/// Every part this library models, by name, across both families.
pub const Core = enum { m0, m0plus, m1, m23, m3, m4, m7, m33, m55, m85, esp32c3, esp32c6 };

/// Which instruction set a core belongs to, and which half of the library runs it.
pub const Family = enum { arm, riscv };

/// Answers the family a core belongs to.
pub fn of(c: Core) Family {
    return switch (c) {
        .m0, .m0plus, .m1, .m23, .m3, .m4, .m7, .m33, .m55, .m85 => .arm,
        .esp32c3, .esp32c6 => .riscv,
    };
}
