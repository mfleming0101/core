const std = @import("std");

fn parcel(comptime Host: type, host: *Host, at: u32) ?u16 {
    const bytes = host.span(at, .{ .kind = .fetch, .bytes = 2 });
    if (bytes.len >= 2) return std.mem.readInt(u16, bytes[0..2], .little);
    return @truncate(host.access(at, .{ .kind = .fetch, .bytes = 2 }, 0) catch return null);
}

const ArmStop = enum(u5) { breakpoint, undefined_instruction, unimplemented, not_t32_state, fetch_fault, data_fault, unaligned_access, divide_by_zero, no_coprocessor, authentication_failure, not_branch_target, exception_return, unrecoverable_exception, secure_fault, fetch_violation, data_violation, tail_predication };

const RiscvStop = enum(u4) { breakpoint, unimplemented, unrecoverable_trap };

pub const arm = struct {
    pub const Architecture = enum {
        armv6m,
        armv7m,
        armv7em,
        armv8m_base,
        armv8m_main,
        armv8_1m_main,

        pub fn main(self: Architecture) bool {
            return self != .armv6m and self != .armv8m_base;
        }

        pub fn v8(self: Architecture) bool {
            return self == .armv8m_base or self == .armv8m_main or self == .armv8_1m_main;
        }

        pub fn dsp(self: Architecture) bool {
            return self == .armv7em or self == .armv8m_main or self == .armv8_1m_main;
        }
    };

    pub const State = struct {
        r: [13]u32 = @splat(0),
        msp: u32 = 0,
        psp: u32 = 0,
        lr: u32 = 0,
        pc: u32 = 0,
        xpsr: u32 = 0,
        control: u32 = 0,
        primask: bool = false,
        basepri: u8 = 0,
        faultmask: bool = false,
        secure: bool = false,
        lockup: bool = false,
        exclusive: ?u32 = null,
        fp: [32]u32 = @splat(0),
        fpscr: u32 = 0,
        pac_key: [8]u32 = @splat(0),
        vpr: u32 = 0,
        msplim: u32 = 0,
        psplim: u32 = 0,

        pub const flag_z: u32 = 1 << 30;
        pub const flag_q: u32 = 1 << 27;
        pub const flag_ge: u32 = 0xf << 16;
        pub const flag_t: u32 = 1 << 24;
        pub const flag_b: u32 = 1 << 21;
        pub const control_npriv: u32 = 1 << 0;
        pub const control_spsel: u32 = 1 << 1;
        pub const control_fpca: u32 = 1 << 2;
        pub const control_sfpa: u32 = 1 << 3;
        pub const ipsr_mask: u32 = 0x1ff;
        pub const it_mask: u32 = 0x0600_fc00;

        pub const Banked = struct {
            msp: u32 = 0,
            psp: u32 = 0,
            control: u32 = 0,
            primask: bool = false,
            basepri: u8 = 0,
            faultmask: bool = false,
            pac_key: [8]u32 = @splat(0),
            msplim: u32 = 0,
            psplim: u32 = 0,
        };

        pub fn handler(self: *const State) bool {
            return self.xpsr & ipsr_mask != 0;
        }

        pub fn privileged(self: *const State) bool {
            return self.handler() or self.control & control_npriv == 0;
        }

        pub fn sp(self: *const State) u32 {
            return if (self.control & control_spsel != 0) self.psp else self.msp;
        }

        pub fn branchTo(self: *State, address: u32) void {
            self.xpsr = (self.xpsr & ~flag_t) | ((address & 1) << 24);
            self.pc = address & ~@as(u32, 1);
        }

        pub fn inIt(self: *const State) bool {
            return self.xpsr & it_mask != 0;
        }

        pub fn itState(self: *const State) u8 {
            return @truncate(((self.xpsr >> 8) & 0xfc) | ((self.xpsr >> 25) & 3));
        }

        pub fn setItState(self: *State, it: u8) void {
            self.xpsr = (self.xpsr & ~it_mask) | (@as(u32, it & 0xfc) << 8) | (@as(u32, it & 3) << 25);
        }

        pub fn itAdvance(self: *State) void {
            const it = self.itState();
            self.setItState(if (it & 7 == 0) 0 else (it & 0xe0) | ((it & 0x0f) << 1));
        }
    };

    pub const Stop = step.Stop;

    pub const instruction = struct {
        pub const Class = enum(u4) { data_processing, load, store, load_multiple, store_multiple, push, pop, pop_pc, branch, branch_link, system, sleep, special_register, barrier, divide };
        pub const Cost = packed struct(u16) { cycles: u8, taken: u8 };
        pub const costs_len = @typeInfo(Class).@"enum".fields.len;
    };

    pub const decode = struct {
        pub const Groups = u16;
        pub const Group = enum(u4) { v6m, v7m, main, dsp, v8m, v8m_main, v8_1m, mve };

        pub fn only(comptime list: []const Group) Groups {
            comptime {
                var out: Groups = 0;
                for (list) |g| out |= @as(Groups, 1) << @intFromEnum(g);
                return out;
            }
        }

        pub const every = only(&.{ .v6m, .v7m, .main, .dsp, .v8m, .v8m_main, .v8_1m, .mve });

        pub const Selection = struct {
            architecture: Architecture,
            groups: Groups,
            xpsr_mask: u32,
        };

        pub fn selectionOf(a: Architecture) Selection {
            return .{ .architecture = a, .groups = every, .xpsr_mask = State.flag_t };
        }
    };

    pub const step = struct {
        pub const Stop = ArmStop;

        pub const Signal = enum { supervisor_call, exception_return, function_return };

        pub const Wait = enum { event, interrupt };

        pub const Result = packed struct(u64) {
            code: u32 = 0,
            fetched: bool = false,
            class: instruction.Class = .data_processing,
            executed: bool = false,
            cycles: u8 = 0,
            branched: bool = false,
            stop: ArmStop = .breakpoint,
            halted: bool = false,
            _: u11 = 0,

            pub fn fetchedCode(self: Result) ?u32 {
                return if (self.fetched) self.code else null;
            }

            pub fn halt(self: Result) ?ArmStop {
                return if (self.halted) self.stop else null;
            }
        };

        pub const Model = struct {
            decoding: decode.Selection,
            costs: Costs,

            pub const Costs = [instruction.costs_len]instruction.Cost;

            pub fn costOf(self: Model, class: instruction.Class) instruction.Cost {
                return self.costs[@intFromEnum(class)];
            }
        };

        pub fn step(comptime Host: type, comptime _: ?decode.Groups, s: *State, host: *Host, _: Model) Result {
            const code = parcel(Host, host, s.pc) orelse return .{ .stop = .fetch_fault, .halted = true };
            return .{ .code = code, .fetched = true, .stop = .undefined_instruction, .halted = true };
        }
    };

    pub const fp = struct {
        pub fn fixedFields(_: Architecture, value: u32) u32 {
            return value;
        }

        pub fn written(comptime Host: type, _: *Host, value: u32) u32 {
            return value;
        }
    };
};

pub const riscv = struct {
    pub const State = struct {
        x: [32]u32 = @splat(0),
        pc: u32 = 0,
        csr: csr_file.File = .{},
        privilege: csr_file.Privilege = .machine,
        reservation: ?u32 = null,

        const csr_file = csr;

        pub fn get(self: *const State, i: u5) u32 {
            return self.x[i];
        }

        pub fn set(self: *State, i: u5, value: u32) void {
            if (i != 0) self.x[i] = value;
        }
    };

    pub const Stop = step.Stop;

    pub const instruction = struct {
        pub const Class = enum(u4) { data_processing, load, store, branch, jump, system, multiply, divide, atomic, load_reserved };
        pub const Cost = packed struct(u16) { cycles: u8, taken: u8 };
        pub const costs_len = @typeInfo(Class).@"enum".fields.len;
    };

    pub const csr = struct {
        pub const Privilege = enum(u2) { user = 0, machine = 3 };

        pub const Number = enum(u12) {
            mstatus = 0x300,
            misa = 0x301,
            mie = 0x304,
            mtvec = 0x305,
            mscratch = 0x340,
            mepc = 0x341,
            mcause = 0x342,
            mtval = 0x343,
            mip = 0x344,
            mvendorid = 0xf11,
            marchid = 0xf12,
            mimpid = 0xf13,
            mhartid = 0xf14,
        };

        pub const Protection = enum(u12) {
            pmpcfg0 = 0x3a0,
            pmpcfg1 = 0x3a1,
            pmpcfg2 = 0x3a2,
            pmpcfg3 = 0x3a3,
            pmpaddr0 = 0x3b0,
            pmpaddr1 = 0x3b1,
            pmpaddr2 = 0x3b2,
            pmpaddr3 = 0x3b3,
            pmpaddr4 = 0x3b4,
            pmpaddr5 = 0x3b5,
            pmpaddr6 = 0x3b6,
            pmpaddr7 = 0x3b7,
            pmpaddr8 = 0x3b8,
            pmpaddr9 = 0x3b9,
            pmpaddr10 = 0x3ba,
            pmpaddr11 = 0x3bb,
            pmpaddr12 = 0x3bc,
            pmpaddr13 = 0x3bd,
            pmpaddr14 = 0x3be,
            pmpaddr15 = 0x3bf,

            pub fn group(self: Protection) ?usize {
                const raw = @intFromEnum(self);
                if (raw >= @intFromEnum(Protection.pmpaddr0)) return null;
                return raw & 0xf;
            }

            pub fn entry(self: Protection) usize {
                return @intFromEnum(self) & 0xf;
            }
        };

        pub const Cause = enum(u32) {
            instruction_access_fault = 1,
            illegal_instruction = 2,
            load_access_fault = 5,
            store_access_fault = 7,
            ecall_from_user = 8,
            ecall_from_machine = 11,
        };

        pub const vendor_id: u32 = 0x0000_0612;
        pub const hart_id: u32 = 0x0000_0000;
        pub const vectored: u32 = 1;
        pub const base_mask: u32 = 0xffff_ff00;
        pub const interrupt_flag: u32 = 0x8000_0000;
        pub const cause_mask: u32 = 0x8000_001f;

        pub const Misaligned = enum { answered, refused };

        pub const TvecModes = enum { direct, vectored, both };

        pub const Implementation = struct {
            isa: u32,
            vendor_id: u32,
            architecture_id: u32,
            implementation_id: u32,
            mstatus_writable: u32,
            cause_mask: u32,
            tvec_base_mask: u32,
            tvec_modes: TvecModes,
            misaligned: Misaligned,
            sc_failure: u32,
            interrupt_csrs: bool,
            float: bool,
        };

        pub const sail: Implementation = .{
            .isa = 0,
            .vendor_id = vendor_id,
            .architecture_id = 0,
            .implementation_id = 0,
            .mstatus_writable = 0,
            .cause_mask = cause_mask,
            .tvec_base_mask = base_mask,
            .tvec_modes = .both,
            .misaligned = .answered,
            .sc_failure = 1,
            .interrupt_csrs = true,
            .float = false,
        };

        pub const Mstatus = packed struct(u32) {
            _0: u3 = 0,
            mie: bool = false,
            _4: u3 = 0,
            mpie: bool = false,
            _8: u3 = 0,
            mpp: Privilege = .user,
            _13: u8 = 0,
            tw: bool = false,
            _22: u10 = 0,
        };

        pub const File = struct {
            mstatus: Mstatus = .{},
            mtvec: u32 = vectored,
            mscratch: u32 = 0,
            mepc: u32 = 0,
            mcause: u32 = 0,
            mtval: u32 = 0,
            mie: u32 = 0,
            mip: u32 = 0,
            implementation: Implementation = sail,

            pub fn read(self: *const File, number: Number) u32 {
                return switch (number) {
                    .mstatus => @bitCast(self.mstatus),
                    .misa => self.implementation.isa,
                    .mie => self.mie,
                    .mtvec => self.mtvec,
                    .mscratch => self.mscratch,
                    .mepc => self.mepc,
                    .mcause => self.mcause,
                    .mtval => self.mtval,
                    .mip => self.mip,
                    .mvendorid => self.implementation.vendor_id,
                    .marchid => self.implementation.architecture_id,
                    .mimpid => self.implementation.implementation_id,
                    .mhartid => hart_id,
                };
            }

            pub fn write(self: *File, number: Number, value: u32) void {
                switch (number) {
                    .mstatus => self.mstatus = .{
                        .mie = value & 1 << 3 != 0,
                        .mpie = value & 1 << 7 != 0,
                        .mpp = if (value & 1 << 11 != 0) .machine else .user,
                        .tw = value & 1 << 21 != 0,
                    },
                    .mie => self.mie = value,
                    .mtvec => self.mtvec = value & base_mask | vectored,
                    .mscratch => self.mscratch = value,
                    .mepc => self.mepc = value & ~@as(u32, 1),
                    .mcause => self.mcause = value & cause_mask,
                    .mtval => self.mtval = value,
                    .mip, .misa, .mvendorid, .marchid, .mimpid, .mhartid => {},
                }
            }

            pub fn enter(self: *File, privilege: *Privilege, cause: Cause, tval: u32, pc: u32) u32 {
                self.stack(privilege, @intFromEnum(cause), tval, pc);
                return self.mtvec & base_mask;
            }

            pub fn interrupt(self: *File, privilege: *Privilege, id: u5, pc: u32) u32 {
                self.stack(privilege, interrupt_flag | id, 0, pc);
                return (self.mtvec & base_mask) +% 4 * @as(u32, id);
            }

            fn stack(self: *File, privilege: *Privilege, cause: u32, tval: u32, pc: u32) void {
                self.mepc = pc;
                self.mcause = cause;
                self.mtval = tval;
                self.mstatus.mpie = self.mstatus.mie;
                self.mstatus.mie = false;
                self.mstatus.mpp = privilege.*;
                privilege.* = .machine;
            }

            pub fn leave(self: *File, privilege: *Privilege) u32 {
                self.mstatus.mie = self.mstatus.mpie;
                self.mstatus.mpie = false;
                privilege.* = self.mstatus.mpp;
                self.mstatus.mpp = .user;
                return self.mepc;
            }
        };
    };

    pub const decode = struct {
        pub const Groups = u16;
        pub const Group = enum(u4) { rv32i, m, a, c, zicsr };

        pub fn only(comptime list: []const Group) Groups {
            comptime {
                var out: Groups = 0;
                for (list) |g| out |= @as(Groups, 1) << @intFromEnum(g);
                return out;
            }
        }

        pub const every = only(&.{ .rv32i, .m, .a, .c, .zicsr });

        pub const wide_prefix: u2 = 0b11;

        pub fn escapes(code: u32) bool {
            return @as(u2, @truncate(code)) == wide_prefix;
        }
    };

    pub const step = struct {
        pub const Stop = RiscvStop;

        pub const Trap = enum(u4) { none, instruction_access_fault, illegal_instruction, load_access_fault, store_access_fault, environment_call };

        pub const Result = packed struct(u64) {
            code: u32 = 0,
            fetched: bool = false,
            class: instruction.Class = .data_processing,
            executed: bool = false,
            cycles: u8 = 0,
            branched: bool = false,
            stop: RiscvStop = .breakpoint,
            halted: bool = false,
            trap: Trap = .none,
            _: u8 = 0,

            pub fn fetchedCode(self: Result) ?u32 {
                return if (self.fetched) self.code else null;
            }

            pub fn halt(self: Result) ?RiscvStop {
                return if (self.halted and self.trap == .none) self.stop else null;
            }
        };

        pub const Model = struct {
            decoding: decode.Groups,
            costs: Costs,

            pub const Costs = [instruction.costs_len]instruction.Cost;

            pub fn costOf(self: Model, class: instruction.Class) instruction.Cost {
                return self.costs[@intFromEnum(class)];
            }
        };

        pub fn step(comptime Host: type, comptime _: ?decode.Groups, s: *State, host: *Host, _: Model) Result {
            const code = parcel(Host, host, s.pc) orelse return .{ .halted = true, .trap = .instruction_access_fault };
            return .{ .code = code, .fetched = true, .halted = true, .trap = .illegal_instruction };
        }
    };
};

pub const sem = struct {
    pub const riscv = struct {
        pub const abi = [32][]const u8{
            "zero", "ra", "sp",  "gp",  "tp", "t0", "t1", "t2",
            "s0",   "s1", "a0",  "a1",  "a2", "a3", "a4", "a5",
            "a6",   "a7", "s2",  "s3",  "s4", "s5", "s6", "s7",
            "s8",   "s9", "s10", "s11", "t3", "t4", "t5", "t6",
        };
    };
};

pub const generated = struct {
    pub const arm_disasm = struct {
        pub fn write(w: *std.Io.Writer, _: u32, _: u32, _: arm.decode.Groups) std.Io.Writer.Error!void {
            try w.writeAll("undefined");
        }
    };

    pub const riscv_disasm = struct {
        pub fn write(w: *std.Io.Writer, _: u32, _: u32, _: riscv.decode.Groups) std.Io.Writer.Error!void {
            try w.writeAll("undefined");
        }
    };
};
