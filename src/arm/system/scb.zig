//! The System Control Block: the identity, vector table, control, priority and fault status
//! registers. Which registers a core has, what each resets to and which of its bits a program
//! may write are a Profile built from the core's spec at compile time, so the block itself is
//! one word per register and a pointer to that profile. A core with the Security Extension
//! keeps two blocks, the processor choosing by the state the access is made in.
const core = @import("core.zig");
const Stop = @import("isa").arm.Stop;

/// Where the System Control Block begins.
pub const base: u32 = 0xe000_ed00;
/// How wide the window is, the STIR, floating-point and cache maintenance registers and the M7 control block included.
pub const size: u32 = 0x2c0;

/// CPUID, at an offset from the base.
pub const cpuid: u32 = 0x00;
/// ICSR, which the processor answers from its own pending and active sets.
pub const icsr: u32 = 0x04;
/// VTOR, the base of the vector table.
pub const vtor: u32 = 0x08;
/// AIRCR, which carries the priority grouping, the reset request and the banking bits.
pub const aircr: u32 = 0x0c;
/// SCR, the sleep and SEVONPEND control.
pub const scr: u32 = 0x10;
/// CCR, whose reset value is a core property.
pub const ccr: u32 = 0x14;
/// SHPR1, the priorities of MemManage, BusFault and UsageFault.
pub const shpr1: u32 = 0x18;
/// SHPR2, the priority of SVCall.
pub const shpr2: u32 = 0x1c;
/// SHPR3, the priorities of PendSV and SysTick.
pub const shpr3: u32 = 0x20;
/// SHCSR, the enables of the configurable faults and the active bits beside them.
pub const shcsr: u32 = 0x24;
/// CFSR, the configurable fault status register.
pub const cfsr: u32 = 0x28;
/// HFSR, the hard fault status register.
pub const hfsr: u32 = 0x2c;
/// DFSR, the debug fault status register.
pub const dfsr: u32 = 0x30;
/// MMFAR, the address a MemManage fault reached.
pub const mmfar: u32 = 0x34;
/// BFAR, the address a BusFault reached.
pub const bfar: u32 = 0x38;
/// AFSR, the auxiliary fault status register.
pub const afsr: u32 = 0x3c;
/// ID_PFR0, the first of the fourteen feature registers that run to ID_ISAR5.
pub const id_pfr0: u32 = 0x40;
/// ID_MMFR0, whose TCM field on the M7 follows the part.
pub const id_mmfr0: u32 = 0x50;
/// CLIDR, the cache levels, none on a core without caches.
pub const clidr: u32 = 0x78;
/// CTR, the cache type.
pub const ctr: u32 = 0x7c;
/// CCSIDR, the geometry of the cache CSSELR selects.
pub const ccsidr: u32 = 0x80;
/// CSSELR, which selects the data or the instruction cache.
pub const csselr: u32 = 0x84;
/// CPACR, which enables the coprocessors.
pub const cpacr: u32 = 0x88;
/// NSACR, RES0 on the M23 for want of the Main Extension and RAZ/WI to the Non-secure state.
pub const nsacr: u32 = 0x8c;
/// Where the MPU registers begin within this window.
pub const mpu_type: u32 = 0x90;
/// Where the MPU registers end.
pub const mpu_end: u32 = 0xc8;
/// Where the debug registers begin, which the block swallows rather than models.
pub const dhcsr: u32 = 0xf0;
/// DEMCR, of which only TRCENA is kept.
pub const demcr: u32 = 0xfc;
/// STIR, which pends an interrupt by number.
pub const stir: u32 = 0x200;
/// FPCCR, the floating-point context control register.
pub const fpccr: u32 = 0x234;
/// FPCAR, the address a lazy floating-point frame was reserved at.
pub const fpcar: u32 = 0x238;
/// FPDSCR, the FPSCR a new context starts from.
pub const fpdscr: u32 = 0x23c;
/// MVFR0, a core property read back.
pub const mvfr0: u32 = 0x240;
/// MVFR1, a core property read back.
pub const mvfr1: u32 = 0x244;
/// MVFR2, a core property read back.
pub const mvfr2: u32 = 0x248;
/// ICIALLU, the first cache maintenance operation, which the block takes and ignores.
pub const iciallu: u32 = 0x250;
/// BPIALL, the last.
pub const bpiall: u32 = 0x278;
/// The CPACR field that enables the floating-point coprocessor.
pub const cp10: u32 = 0x3 << 20;
/// The NSACR bit that lets the Non-secure state reach the floating-point coprocessor, v8-M D1.2.181.
pub const nsacr_cp10: u32 = 1 << 10;
/// The FPCCR bit that saves floating-point state automatically on exception entry.
pub const aspen: u32 = 1 << 31;
/// The FPCCR bit that makes that saving lazy.
pub const lspen: u32 = 1 << 30;
/// The FPCCR bit that makes a lazy frame carry the callee-saved registers too.
pub const treat_as_secure: u32 = 1 << 26;
/// The FPCCR bit recording that the lazy frame was reserved in Thread mode.
pub const fp_thread: u32 = 1 << 3;
/// The FPCCR bit recording that it was reserved in the Secure state.
pub const fp_secure: u32 = 1 << 2;
/// The FPCCR bit recording that it was reserved unprivileged.
pub const fp_user: u32 = 1 << 1;
/// The FPCCR bit saying a lazy frame is reserved and not yet filled.
pub const lspact: u32 = 1 << 0;
/// The FPCCR bit recording that UsageFault could be taken when the frame was reserved.
pub const ufrdy: u32 = 1 << 10;
/// The same for SecureFault.
pub const sfrdy: u32 = 1 << 7;
/// The same for BusFault.
pub const bfrdy: u32 = 1 << 6;
/// The same for HardFault.
pub const hfrdy: u32 = 1 << 4;
/// The same for MemManage.
pub const mmrdy: u32 = 1 << 5;

/// The AIRCR bit a program resets the core with.
pub const sysresetreq: u32 = 1 << 2;
/// The AIRCR bit that hands BusFault, HardFault and NMI to the Non-secure state.
pub const bfhfnmins: u32 = 1 << 13;
/// The AIRCR bit that halves the Non-secure priority range.
pub const pris: u32 = 1 << 14;
/// The ICSR bit that routes SysTick to the Non-secure exception.
pub const sttns: u32 = 1 << 24;

/// The SCR bit that wakes a core waiting for an event when any interrupt pends.
pub const sevonpend: u32 = 1 << 4;
/// The SCR bit that keeps SLEEPDEEP from the Non-secure state, itself Secure only, v8-M D1.2.230.
pub const sleepdeeps: u32 = 1 << 3;
/// The SCR bit that asks for deep sleep, one bit for both Security states.
pub const sleepdeep: u32 = 1 << 2;

/// The key an AIRCR write must carry to take effect.
pub const vectkey: u32 = 0x05fa;
/// What AIRCR reads back in place of that key.
pub const vectkeystat: u32 = 0xfa05_0000;

/// The HFSR bit for a fault reading the vector table.
pub const vecttbl: u32 = 1 << 1;
/// The HFSR bit for a fault escalated to HardFault.
pub const forced: u32 = 1 << 30;

const iaccviol: u32 = 1 << 0;
const daccviol: u32 = 1 << 1;
const mstkerr: u32 = 1 << 4;
const mmarvalid: u32 = 1 << 7;
const ibuserr: u32 = 1 << 8;
const preciserr: u32 = 1 << 9;
const stkerr: u32 = 1 << 12;
const bfarvalid: u32 = 1 << 15;
const undefinstr: u32 = 1 << 16;
const invstate: u32 = 1 << 17;
const invpc: u32 = 1 << 18;
const nocp: u32 = 1 << 19;
const unaligned: u32 = 1 << 24;
const divbyzero: u32 = 1 << 25;

/// The CFSR bits and the names explain prints them by.
pub const recorded = [_]struct { bit: u32, name: []const u8 }{
    .{ .bit = iaccviol, .name = "IACCVIOL" },
    .{ .bit = daccviol, .name = "DACCVIOL" },
    .{ .bit = mstkerr, .name = "MSTKERR" },
    .{ .bit = mmarvalid, .name = "MMARVALID" },
    .{ .bit = ibuserr, .name = "IBUSERR" },
    .{ .bit = preciserr, .name = "PRECISERR" },
    .{ .bit = stkerr, .name = "STKERR" },
    .{ .bit = bfarvalid, .name = "BFARVALID" },
    .{ .bit = undefinstr, .name = "UNDEFINSTR" },
    .{ .bit = invstate, .name = "INVSTATE" },
    .{ .bit = invpc, .name = "INVPC" },
    .{ .bit = nocp, .name = "NOCP" },
    .{ .bit = unaligned, .name = "UNALIGNED" },
    .{ .bit = divbyzero, .name = "DIVBYZERO" },
};

/// The CCR bit that lets a handler return to Thread mode with exceptions still active.
pub const nonbasethrdena: u32 = 1 << 0;
/// The CCR bit that makes a negative-priority handler ignore a data fault.
pub const bfhfnmign: u32 = 1 << 8;
/// The CCR bit that aligns the exception frame to eight bytes.
pub const stkalign: u32 = 1 << 9;
/// The CCR bit that lets unprivileged code write STIR.
pub const usersetmpend: u32 = 1 << 1;
/// The CCR bit that traps an unaligned access.
pub const unalign_trp: u32 = 1 << 3;
/// The CCR bit that traps a divide by zero.
pub const div_0_trp: u32 = 1 << 4;
const dc: u32 = 1 << 16;
const ic: u32 = 1 << 17;

/// The SHCSR bit saying the debug monitor is active.
pub const monitoract: u32 = 1 << 8;
/// The SHCSR bit that enables MemManage.
pub const memfaultena: u32 = 1 << 16;
/// The SHCSR bit that enables BusFault.
pub const busfaultena: u32 = 1 << 17;
/// The SHCSR bit that enables UsageFault.
pub const usgfaultena: u32 = 1 << 18;
/// The SHCSR bit that enables SecureFault.
pub const secureflt_ena: u32 = 1 << 19;

/// The DEMCR bit that runs the DWT.
pub const trcena: u32 = 1 << 24;

const Slot = struct { name: []const u8, offset: u32, group: enum { shared, main, floating, cache, cache_id, armv8, sleep } };

/// Every register the block holds, with the offset and the group that decides whether a core has it.
pub const layout = [_]Slot{
    .{ .name = "CPUID", .offset = cpuid, .group = .shared },
    .{ .name = "VTOR", .offset = vtor, .group = .shared },
    .{ .name = "AIRCR", .offset = aircr, .group = .shared },
    .{ .name = "CCR", .offset = ccr, .group = .shared },
    .{ .name = "SHPR2", .offset = shpr2, .group = .shared },
    .{ .name = "SHPR3", .offset = shpr3, .group = .shared },
    .{ .name = "SHCSR", .offset = shcsr, .group = .shared },
    .{ .name = "DFSR", .offset = dfsr, .group = .shared },
    .{ .name = "DEMCR", .offset = demcr, .group = .shared },
    .{ .name = "SCR", .offset = scr, .group = .sleep },
    .{ .name = "SHPR1", .offset = shpr1, .group = .main },
    .{ .name = "CFSR", .offset = cfsr, .group = .main },
    .{ .name = "HFSR", .offset = hfsr, .group = .main },
    .{ .name = "MMFAR", .offset = mmfar, .group = .main },
    .{ .name = "BFAR", .offset = bfar, .group = .main },
    .{ .name = "AFSR", .offset = afsr, .group = .main },
    .{ .name = "CPACR", .offset = cpacr, .group = .main },
    .{ .name = "STIR", .offset = stir, .group = .main },
    .{ .name = "FPCCR", .offset = fpccr, .group = .floating },
    .{ .name = "FPCAR", .offset = fpcar, .group = .floating },
    .{ .name = "FPDSCR", .offset = fpdscr, .group = .floating },
    .{ .name = "MVFR0", .offset = mvfr0, .group = .floating },
    .{ .name = "MVFR1", .offset = mvfr1, .group = .floating },
    .{ .name = "MVFR2", .offset = mvfr2, .group = .floating },
    .{ .name = "CLIDR", .offset = clidr, .group = .cache_id },
    .{ .name = "CTR", .offset = ctr, .group = .cache_id },
    .{ .name = "CCSIDR", .offset = ccsidr, .group = .cache },
    .{ .name = "CSSELR", .offset = csselr, .group = .cache_id },
    .{ .name = "NSACR", .offset = nsacr, .group = .armv8 },
};

const absent: u8 = layout.len;

const map = blk: {
    var m: [size / 4]u8 = @splat(absent);
    for (layout, 0..) |r, i| m[r.offset / 4] = i;
    break :blk m;
};

/// Which registers one core has, and the reset value and writable mask of each.
pub const Profile = struct {
    present: u32,
    main: bool,
    floating_point: bool,
    caches: bool,
    levels: u32,
    features: [14]?u32,
    tcms: bool,
    reset: [layout.len]u32,
    write_mask: [layout.len]u32,
};

const cache_type: u32 = 0x8303_c003;
const data_ccsidr = [_]u32{ 0, 0xf003_e019, 0xf007_e019, 0xf00f_e019, 0xf01f_e019, 0xf03f_e019 };
const instruction_ccsidr = [_]u32{ 0, 0xf007_e009, 0xf00f_e009, 0xf01f_e009, 0xf03f_e009, 0xf07f_e009 };

fn valuesOf(comptime spec: core.Spec, comptime slot: Slot) struct { reset: u32, write_mask: u32 } {
    const main = spec.architecture.main();
    const lane: u32 = (0xff << (8 - core.choicesOf(spec.core).priority_bits.most())) & 0xff;
    const wide_default = spec.architecture == .armv8_1m_main;
    return switch (slot.offset) {
        cpuid => .{ .reset = spec.cpuid, .write_mask = 0 },
        vtor => .{ .reset = 0, .write_mask = switch (spec.core) {
            .m0, .m1 => 0,
            else => 0xffff_ff80,
        } },
        aircr => .{ .reset = vectkeystat, .write_mask = (if (spec.security) 0x0000_6000 else 0) | (if (main) 0x0000_0700 else 0) },
        ccr => .{ .reset = spec.ccr, .write_mask = switch (spec.architecture) {
            .armv6m, .armv8m_base => 0,
            .armv7m, .armv7em => if (spec.core == .m7) 0x0000_011b else 0x0000_031b,
            .armv8m_main, .armv8_1m_main => 0x0000_051a,
        } },
        shpr1 => .{ .reset = 0, .write_mask = lane << 16 | lane << 8 | lane },
        shpr2 => .{ .reset = 0, .write_mask = lane << 24 },
        shpr3 => .{ .reset = 0, .write_mask = lane << 24 | lane << 16 | (if (main) lane else 0) },
        shcsr => .{ .reset = 0, .write_mask = if (!main) 0 else monitoract | memfaultena | busfaultena | usgfaultena | (if (spec.security) secureflt_ena else 0) },
        demcr => .{ .reset = 0, .write_mask = trcena },
        scr => .{ .reset = 0, .write_mask = 0x0000_0016 | (if (spec.security) sleepdeeps else 0) },
        mmfar, bfar => .{ .reset = 0, .write_mask = 0xffff_ffff },
        cpacr => .{ .reset = 0, .write_mask = if (spec.floating_point) 0x00f0_0000 else 0 },
        nsacr => .{ .reset = 0, .write_mask = if (spec.floating_point) 0x0000_0c00 else 0 },
        fpccr => .{ .reset = if (spec.security) 0xc000_0004 else 0xc000_0000, .write_mask = if (spec.security) 0xfc00_07ff else 0xc000_017b },
        fpcar => .{ .reset = 0, .write_mask = 0xffff_fff8 },
        fpdscr => .{ .reset = if (wide_default) 0x0004_0000 else 0, .write_mask = if (wide_default) 0x07c8_0000 else 0x07c0_0000 },
        mvfr0 => .{ .reset = spec.mvfr[0], .write_mask = 0 },
        mvfr1 => .{ .reset = spec.mvfr[1], .write_mask = 0 },
        mvfr2 => .{ .reset = spec.mvfr[2], .write_mask = 0 },
        ctr => .{ .reset = if (spec.core == .m7) cache_type else 0, .write_mask = 0 },
        csselr => .{ .reset = 0, .write_mask = 1 },
        else => .{ .reset = 0, .write_mask = 0 },
    };
}

/// ID_PFR0 to ID_ISAR5 of a core, null where the core has none: Armv6-M reserves them, v6-M D3.6.1; the M23 has them RES0 for want of the Main Extension, v8-M D1.2.140; the M3, M4 and M7 read their TRM tables, M3 and M4 TRM Table 4-1, M7 TRM Table 3-1, with ID_ISAR5 RAZ, v7-M Table B4-1; the M33, M55 and M85 read theirs, M33 TRM Table 3-1, M55 and M85 TRM Table 5-1, with debug fitted, no coprocessor interface and no CDE, the M33 with DSP and the M85 with PACBTI. The M33 TRM gives ID_PFR0 and ID_PFR1 values its notes contradict, so the M33 has neither.
fn featuresOf(comptime c: core.Core) [14]?u32 {
    const armv7: [14]?u32 = .{ 0x30, 0x200, 0x0010_0000, 0, 0x0010_0030, 0, 0x0100_0000, 0, 0x0110_0110, 0x0211_1000, 0x2111_2231, 0x0111_1110, 0x0131_0132, 0 };
    const armv8_1: [14]?u32 = .{ 0x2000_0030, 0x230, 0x1020_0000, 0, 0x0011_1040, 0, 0x0100_0000, 0x11, 0x0110_3110, 0x0221_2000, 0x2023_2232, 0x0111_1131, 0x0131_0132, 0 };
    var out = armv7;
    switch (c) {
        .m0, .m0plus, .m1 => return @splat(null),
        .m23 => return @splat(0),
        .m3 => {},
        .m4 => out[8..12].* = .{ 0x0114_1110, 0x0211_2000, 0x2123_2231, 0x0111_1131 },
        .m7 => out[8..12].* = .{ 0x0110_1110, 0x0211_2000, 0x2023_2231, 0x0111_1131 },
        .m33 => out = .{ null, null, 0x0020_0000, 0, 0x0010_1f40, 0, 0x0100_0000, 0, 0x0110_1110, 0x0221_2000, 0x2023_2232, 0x0111_1131, 0x0131_0132, 0 },
        .m55 => out = armv8_1,
        .m85 => {
            out = armv8_1;
            out[13] = 0x0040_0000;
        },
    }
    return out;
}

/// The profile of a core, built at compile time from its spec.
pub fn profileOf(comptime c: core.Core) Profile {
    @setEvalBranchQuota(200_000);
    const spec = core.spec(c);
    const main = spec.architecture.main();
    var out: Profile = .{ .present = 0, .main = main, .floating_point = spec.floating_point, .caches = spec.caches, .levels = if (c == .m7) 0x0900_0000 else 0x0920_0000, .features = featuresOf(c), .tcms = c == .m7, .reset = @splat(0), .write_mask = @splat(0) };
    for (layout, 0..) |slot, i| {
        const held = switch (slot.group) {
            .shared => true,
            .main => main or spec.architecture.v8(),
            .floating => spec.floating_point or spec.architecture.v8(),
            .cache => spec.caches or spec.architecture.v8(),
            .cache_id => spec.architecture != .armv6m,
            .armv8 => spec.architecture.v8(),
            .sleep => c != .m1,
        };
        if (!held) continue;
        const res0 = ((slot.group == .main or slot.group == .armv8) and !main) or (slot.group == .floating and !spec.floating_point);
        const v = if (res0) .{ .reset = 0, .write_mask = 0 } else valuesOf(spec, slot);
        out.present |= @as(u32, 1) << @intCast(i);
        out.reset[i] = v.reset;
        out.write_mask[i] = v.write_mask;
    }
    return out;
}

/// The block itself: a word per register the core has, over a profile shared by every instance, and the cache sizes, TCMs and REVIDR of this part.
pub const Scb = struct {
    const Self = @This();

    profile: *const Profile,
    words: [layout.len]u32,
    data: core.CacheSize,
    instruction: core.CacheSize,
    tcm: bool,
    revision: u4,

    /// A block at the reset values its profile and its part give; a core without caches keeps none.
    pub fn init(profile: *const Profile, part: core.Part) Self {
        var out: Self = .{
            .profile = profile,
            .words = undefined,
            .data = .none,
            .instruction = .none,
            .tcm = profile.tcms and (part.itcm.size != .none or part.dtcm.size != .none),
            .revision = part.revidr,
        };
        if (profile.caches) {
            out.data = part.data;
            out.instruction = part.instruction;
        }
        out.reset();
        return out;
    }

    /// Returns every register to its reset value.
    pub fn reset(self: *Self) void {
        self.words = self.profile.reset;
        const ctype = @as(u32, @intFromBool(self.data != .none)) << 1 | @intFromBool(self.instruction != .none);
        self.words[comptime slot(clidr).?] = if (ctype == 0) 0 else self.profile.levels | ctype;
        if (ctype != 0) self.words[comptime slot(ctr).?] = cache_type;
        self.words[comptime slot(ccsidr).?] = self.selected(0);
    }

    fn selected(self: *const Self, instruction: u32) u32 {
        return if (instruction == 0) data_ccsidr[@intFromEnum(self.data)] else instruction_ccsidr[@intFromEnum(self.instruction)];
    }

    fn enables(self: *const Self) u32 {
        return (if (self.data != .none) dc else 0) | (if (self.instruction != .none) ic else 0);
    }

    fn has(self: *const Self, i: u8) bool {
        return self.profile.present & (@as(u32, 1) << @intCast(i)) != 0;
    }

    /// The word a register holds, by offset, resolved to a slot at compile time.
    pub fn get(self: *const Self, comptime offset: u32) u32 {
        return self.words[comptime slot(offset).?];
    }

    /// Puts a word into a register, by offset, without the masking a program write takes.
    pub fn put(self: *Self, comptime offset: u32, value: u32) void {
        self.words[comptime slot(offset).?] = value;
    }

    /// Records a fault in CFSR, and its address in MMFAR or BFAR where the fault has one.
    pub fn fault(self: *Self, stop: Stop, address: u32) void {
        if (!self.profile.main) return;
        self.words[comptime slot(cfsr).?] |= switch (stop) {
            .undefined_instruction => undefinstr,
            .not_t32_state, .authentication_failure, .not_branch_target, .tail_predication => invstate,
            .exception_return => invpc,
            .no_coprocessor => nocp,
            .unaligned_access => unaligned,
            .divide_by_zero => divbyzero,
            .fetch_violation => iaccviol,
            .data_violation => blk: {
                self.words[comptime slot(mmfar).?] = address;
                break :blk daccviol | mmarvalid;
            },
            .fetch_fault => ibuserr,
            .data_fault => blk: {
                self.words[comptime slot(bfar).?] = address;
                break :blk preciserr | bfarvalid;
            },
            else => return,
        };
    }

    /// Records that the fault happened while stacking an exception frame.
    pub fn stacking(self: *Self, stop: Stop) void {
        if (!self.profile.main) return;
        self.words[comptime slot(cfsr).?] |= switch (stop) {
            .data_violation => mstkerr,
            .data_fault => stkerr,
            else => return,
        };
    }

    /// Sets bits in HFSR.
    pub fn hardFault(self: *Self, bits: u32) void {
        if (self.profile.main) self.words[comptime slot(hfsr).?] |= bits;
    }

    /// The word a register read answers; a register the core lacks answers null, and debug and cache maintenance read zero.
    pub fn readRegister(self: *Self, offset: u32) ?u32 {
        const i = index(offset);
        if (i != absent and self.has(i)) return self.words[i];
        if (self.feature(offset)) |word| return word;
        return if (self.answers(offset)) 0 else null;
    }

    fn feature(self: *const Self, offset: u32) ?u32 {
        if (offset -% id_pfr0 >= clidr - id_pfr0 or offset & 3 != 0) return null;
        const word = self.profile.features[(offset - id_pfr0) / 4] orelse return null;
        return if (offset == id_mmfr0 and self.tcm) word | 1 << 16 else word;
    }

    /// Takes a register write, keeping the writable bits; a status register is cleared by what it is written.
    pub fn writeRegister(self: *Self, offset: u32, value: u32) bool {
        const i = index(offset);
        if (i == absent or !self.has(i)) return self.feature(offset) != null or self.answers(offset);
        if (offset == aircr and value >> 16 != vectkey) return true;
        if (offset == clidr or offset == ccsidr or offset == ctr) return true;
        if (offset == csselr) self.words[comptime slot(ccsidr).?] = self.selected(value & 1);
        const mask = self.profile.write_mask[i] | (if (offset == ccr) self.enables() else 0);
        self.words[i] = if (clearedByWrite(offset)) self.words[i] & ~value else (value & mask) | (self.profile.reset[i] & ~mask);
        return true;
    }

    fn index(offset: u32) u8 {
        if (offset >= size or offset & 3 != 0) return absent;
        return map[offset / 4];
    }

    fn slot(offset: u32) ?u8 {
        const i = index(offset);
        return if (i == absent) null else i;
    }

    fn answers(self: *const Self, offset: u32) bool {
        if (offset & 3 != 0) return false;
        if (self.profile.main and !self.profile.floating_point and offset -% fpccr < iciallu - fpccr) return true;
        if (self.has(comptime slot(ccsidr).?) and offset -% iciallu <= bpiall - iciallu and offset != iciallu + 4) return true;
        return offset -% dhcsr < demcr - dhcsr;
    }

    fn clearedByWrite(offset: u32) bool {
        return offset == cfsr or offset == hfsr or offset == dfsr;
    }
};
