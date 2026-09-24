//! The console subset of the Arm semihosting calls, written once for both families. The
//! operation number and the parameter block address arrive already unpacked, and every field
//! of the block is read back through the processor's own peek, so the call sees what the core
//! sees. SYS_OPEN of ":tt", CLOSE, WRITEC, WRITE0, WRITE, ISTTY, EXIT and
//! EXIT_EXTENDED are answered; anything else answers failure.
const std = @import("std");

const open: u32 = 0x01;
const close: u32 = 0x02;
const writec: u32 = 0x03;
const write0: u32 = 0x04;
const write: u32 = 0x05;
const istty: u32 = 0x09;
const exit: u32 = 0x18;
const exit_extended: u32 = 0x20;

const application_exit: u32 = 0x0002_0026;
const console_name = ":tt";
const console_handle: u32 = 1;
const failed: u32 = 0xffff_ffff;

/// The status a SYS_EXIT or SYS_EXIT_EXTENDED asked the run to end with.
pub const Exit = struct { status: u8 };

/// What a call produced: the word to put in the result register, or the exit it asked for.
pub const Result = union(enum) { value: u32, exit: Exit };

/// Performs the call an operation number names, over its parameter block; anything else fails.
pub fn call(cpu: anytype, out: *std.Io.Writer, op: u32, arg: u32) !Result {
    return .{ .value = switch (op) {
        open => if (opensConsole(cpu, arg)) console_handle else failed,
        close => if (console(cpu, arg)) 0 else failed,
        writec => try writeBytes(cpu, out, arg, 1),
        write0 => try writeString(cpu, out, arg),
        write => try written(cpu, out, arg),
        istty => if (console(cpu, arg)) 1 else failed,
        exit => return .{ .exit = status(arg, 0) },
        exit_extended => return .{ .exit = status(field(cpu, arg, 0) orelse 0, field(cpu, arg, 1) orelse 0) },
        else => failed,
    } };
}

fn status(reason: u32, subcode: u32) Exit {
    return .{ .status = if (reason == application_exit) @truncate(subcode) else 1 };
}

fn field(cpu: anytype, arg: u32, index: u32) ?u32 {
    return cpu.peek(4, arg +% index * 4);
}

fn console(cpu: anytype, arg: u32) bool {
    return (field(cpu, arg, 0) orelse return false) == console_handle;
}

fn written(cpu: anytype, out: *std.Io.Writer, arg: u32) !u32 {
    const at = field(cpu, arg, 1) orelse return failed;
    const len = field(cpu, arg, 2) orelse return failed;
    if (!console(cpu, arg)) return len;
    return writeBytes(cpu, out, at, len);
}

fn opensConsole(cpu: anytype, arg: u32) bool {
    if ((field(cpu, arg, 2) orelse return false) != console_name.len) return false;
    const at = field(cpu, arg, 0) orelse return false;
    for (console_name, 0..) |c, i| {
        if ((cpu.peek(1, at +% @as(u32, @intCast(i))) orelse return false) != c) return false;
    }
    return true;
}

fn writeBytes(cpu: anytype, out: *std.Io.Writer, at: u32, len: u32) !u32 {
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const byte = cpu.peek(1, at +% i) orelse break;
        try out.writeByte(byte);
    }
    return len - i;
}

fn writeString(cpu: anytype, out: *std.Io.Writer, at: u32) !u32 {
    var i: u32 = 0;
    while (cpu.peek(1, at +% i)) |byte| : (i += 1) {
        if (byte == 0) break;
        try out.writeByte(byte);
    }
    return 0;
}
