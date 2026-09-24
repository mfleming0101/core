const std = @import("std");
const regions = @import("../../../src/memory/regions.zig");
const intc = @import("../../../src/riscv/system/intc.zig");
const register = @import("../../register.zig");

const Lines = regions.Lines;

const sw_intr_0: usize = 50;
const sw_intr_1: usize = 51;
const uhci0: usize = 15;

const layout = intc.esp32c3;

const ungated: u32 = ~@as(u32, 0);

fn line(source: usize) Lines {
    return @as(Lines, 1) << @intCast(source);
}

fn mapAt(l: intc.Layout, source: usize) u32 {
    return l.matrix_base + @as(u32, @intCast(4 * source));
}

fn priAt(l: intc.Layout, id: u5) u32 {
    return l.control_base + l.priority + 4 * (@as(u32, id) - l.priority_first);
}

fn started(l: intc.Layout) intc.Intc {
    return .{ .layout = l };
}

fn arm(unit: *intc.Intc, source: usize, id: u5, priority: u4, edge: bool) void {
    const l = unit.layout;
    unit.writeRegister(mapAt(l, source), id);
    if (edge) unit.writeRegister(l.control_base + l.kinds, unit.readRegister(l.control_base + l.kinds) | @as(u32, 1) << id);
    unit.writeRegister(priAt(l, id), priority);
    unit.writeRegister(l.control_base + l.enable, unit.readRegister(l.control_base + l.enable) | @as(u32, 1) << id);
}

const esp32c3_registers = [_]register.Register{
    .{ .name = "UHCI0_INTR_MAP", .offset = intc.esp32c3.matrix_base + 4 * 15, .reset = 0, .write_mask = 0x1f },
    .{ .name = "CPU_INTR_FROM_CPU_0_MAP", .offset = intc.esp32c3.matrix_base + 4 * 50, .reset = 0, .write_mask = 0x1f },
    .{ .name = "CPU_INT_ENABLE", .offset = intc.esp32c3.control_base + intc.esp32c3.enable, .reset = 0, .write_mask = 0xffff_ffff },
    .{ .name = "CPU_INT_TYPE", .offset = intc.esp32c3.control_base + intc.esp32c3.kinds, .reset = 0, .write_mask = 0xffff_ffff },
    .{ .name = "CPU_INT_CLEAR", .offset = intc.esp32c3.control_base + intc.esp32c3.clear, .reset = 0, .write_mask = 0xffff_ffff },
    .{ .name = "CPU_INT_EIP_STATUS", .offset = intc.esp32c3.control_base + intc.esp32c3.status, .reset = 0, .write_mask = 0 },
    .{ .name = "CPU_INT_PRI_1", .offset = intc.esp32c3.control_base + intc.esp32c3.priority, .reset = 0, .write_mask = 0xf },
    .{ .name = "CPU_INT_PRI_31", .offset = intc.esp32c3.control_base + intc.esp32c3.priority + 4 * 30, .reset = 0, .write_mask = 0xf },
    .{ .name = "CPU_INT_THRESH", .offset = intc.esp32c3.control_base + intc.esp32c3.threshold, .reset = 0, .write_mask = 0xf },
};

const esp32c6_registers = [_]register.Register{
    .{ .name = "INTMTX_CORE0_PMU_INTR_MAP", .offset = intc.esp32c6.matrix_base + 4 * 13, .reset = 0, .write_mask = 0x1f },
    .{ .name = "INTMTX_CORE0_CPU_INTR_FROM_CPU_0_MAP", .offset = intc.esp32c6.matrix_base + 4 * 22, .reset = 0, .write_mask = 0x1f },
    .{ .name = "INTMTX_CORE0_ECC_INTR_MAP", .offset = intc.esp32c6.matrix_base + 4 * 76, .reset = 0, .write_mask = 0x1f },
    .{ .name = "INTPRI_CORE0_CPU_INT_ENABLE", .offset = intc.esp32c6.control_base + intc.esp32c6.enable, .reset = 0, .write_mask = 0xffff_ffff },
    .{ .name = "INTPRI_CORE0_CPU_INT_TYPE", .offset = intc.esp32c6.control_base + intc.esp32c6.kinds, .reset = 0, .write_mask = 0xffff_ffff },
    .{ .name = "INTPRI_CORE0_CPU_INT_EIP_STATUS", .offset = intc.esp32c6.control_base + intc.esp32c6.status, .reset = 0, .write_mask = 0 },
    .{ .name = "INTPRI_CORE0_CPU_INT_PRI_0", .offset = intc.esp32c6.control_base + intc.esp32c6.priority, .reset = 0, .write_mask = 0xf },
    .{ .name = "INTPRI_CORE0_CPU_INT_PRI_31", .offset = intc.esp32c6.control_base + intc.esp32c6.priority + 4 * 31, .reset = 0, .write_mask = 0xf },
    .{ .name = "INTPRI_CORE0_CPU_INT_THRESH", .offset = intc.esp32c6.control_base + intc.esp32c6.threshold, .reset = 0, .write_mask = 0xff },
    .{ .name = "INTPRI_CPU_INTR_FROM_CPU_0", .offset = intc.esp32c6.control_base + intc.esp32c6.software, .reset = 0, .write_mask = 1 },
    .{ .name = "INTPRI_CPU_INTR_FROM_CPU_3", .offset = intc.esp32c6.control_base + intc.esp32c6.software + 12, .reset = 0, .write_mask = 1 },
    .{ .name = "INTPRI_CORE0_CPU_INT_CLEAR", .offset = intc.esp32c6.control_base + intc.esp32c6.clear, .reset = 0, .write_mask = 0xffff_ffff },
};

test "every register of the C3's block reads its reset value and keeps only the bits it implements, C3 TRM 8.5" {
    try checkRegisters(intc.esp32c3, &esp32c3_registers);
}

test "every register of the C6's block reads its reset value and keeps only the bits it implements, C6 TRM 10.4.1 and 10.4.2" {
    try checkRegisters(intc.esp32c6, &esp32c6_registers);
}

fn checkRegisters(l: intc.Layout, table: []const register.Register) !void {
    for (table) |r| {
        var unit = started(l);
        unit.reset();
        try std.testing.expectEqual(r.reset, unit.readRegister(r.offset));
        unit.writeRegister(r.offset, 0xffff_ffff);
        const after = unit.readRegister(r.offset);
        if (after & ~(r.write_mask | r.reset) != 0) {
            std.debug.print("{s} kept {x:0>8}\n", .{ r.name, after });
            return error.TestUnexpectedResult;
        }
    }
}

test "the block answers over the four kilobytes the memory map gives the interrupt matrix and nothing outside them, C3 TRM Table 3.3-3" {
    var unit = started(layout);
    try std.testing.expectEqual(intc.Region.memory, unit.region(layout.matrix_base - 1));
    try std.testing.expectEqual(intc.Region.interrupt, unit.region(layout.matrix_base));
    try std.testing.expectEqual(intc.Region.interrupt, unit.region(layout.matrix_base + intc.size - 4));
    try std.testing.expectEqual(intc.Region.memory, unit.region(layout.matrix_base + intc.size));
    try std.testing.expectEqual(intc.Region.memory, unit.region(0x4200_0000));
}

test "the C6 answers over two blocks, the matrix at one base and the controller at another, C6 TRM Table 5.3-2" {
    var unit = started(intc.esp32c6);
    try std.testing.expectEqual(intc.Region.interrupt, unit.region(intc.esp32c6.matrix_base));
    try std.testing.expectEqual(intc.Region.interrupt, unit.region(intc.esp32c6.matrix_base + intc.size - 4));
    try std.testing.expectEqual(intc.Region.memory, unit.region(intc.esp32c6.matrix_base + intc.size));
    try std.testing.expectEqual(intc.Region.interrupt, unit.region(intc.esp32c6.control_base));
    try std.testing.expectEqual(intc.Region.interrupt, unit.region(intc.esp32c6.control_base + intc.size - 4));
    try std.testing.expectEqual(intc.Region.memory, unit.region(intc.esp32c6.control_base + intc.size));
    try std.testing.expectEqual(intc.Region.memory, unit.region(intc.esp32c3.control_base));
}

test "a mapping register sits at four times its source number and holds the five bits of a CPU interrupt id, C3 TRM 8.4 and Register 8.51" {
    var unit = started(layout);
    unit.writeRegister(mapAt(layout, uhci0), 3);
    unit.writeRegister(mapAt(layout, sw_intr_0), 0xffff_fff1);
    try std.testing.expectEqual(@as(u32, 3), unit.readRegister(layout.matrix_base + 0x003c));
    try std.testing.expectEqual(@as(u32, 0x11), unit.readRegister(layout.matrix_base + 0x00c8));
    try std.testing.expectEqual(@as(u32, 0), unit.readRegister(mapAt(layout, 0)));
    try std.testing.expectEqual(@as(u32, 0), unit.readRegister(mapAt(layout, 61)));
}

test "a source no mapping register routes anywhere raises nothing, C3 TRM 8.3.3.3" {
    var unit = started(layout);
    unit.writeRegister(layout.control_base + layout.enable, 0xffff_ffff);
    unit.writeRegister(priAt(layout, 1), 5);
    unit.raise(line(sw_intr_0));
    try std.testing.expectEqual(@as(u32, 0), unit.pending());
    try std.testing.expectEqual(@as(?u5, null), unit.best(ungated));
}

test "a level-type interrupt is pending while a source routed to it is asserted and stops when the source drops, C3 TRM 1.5.2" {
    var unit = started(layout);
    arm(&unit, sw_intr_0, 4, 1, false);
    try std.testing.expectEqual(@as(u32, 0), unit.pending());
    unit.raise(line(sw_intr_0));
    try std.testing.expectEqual(@as(u32, 1) << 4, unit.pending());
    unit.hold(line(sw_intr_0));
    try std.testing.expectEqual(@as(u32, 1) << 4, unit.pending());
    unit.hold(0);
    try std.testing.expectEqual(@as(u32, 0), unit.pending());
}

test "the clear register does not touch a level-type interrupt, whose pending state must be cleared from the source, C3 TRM 1.5.2" {
    var unit = started(layout);
    arm(&unit, sw_intr_0, 4, 1, false);
    unit.raise(line(sw_intr_0));
    unit.writeRegister(layout.control_base + layout.clear, 0xffff_ffff);
    try std.testing.expectEqual(@as(u32, 1) << 4, unit.pending());
    unit.hold(0);
    try std.testing.expectEqual(@as(u32, 0), unit.pending());
}

test "an edge-type interrupt latches on the rising edge and stays pending until the clear register flushes it, C3 TRM 1.5.2" {
    var unit = started(layout);
    arm(&unit, sw_intr_0, 4, 1, true);
    unit.raise(line(sw_intr_0));
    unit.hold(0);
    try std.testing.expectEqual(@as(u32, 1) << 4, unit.pending());
    unit.writeRegister(layout.control_base + layout.clear, @as(u32, 1) << 5);
    try std.testing.expectEqual(@as(u32, 1) << 4, unit.pending());
    unit.writeRegister(layout.control_base + layout.clear, @as(u32, 1) << 4);
    try std.testing.expectEqual(@as(u32, 0), unit.pending());
    try std.testing.expectEqual(@as(u32, 1) << 4, unit.readRegister(layout.control_base + layout.clear));
}

test "two sources routed to one interrupt both raise it, C3 TRM 8.3.3.2" {
    var unit = started(layout);
    arm(&unit, sw_intr_0, 7, 1, true);
    unit.writeRegister(mapAt(layout, sw_intr_1), 7);
    unit.raise(line(sw_intr_1));
    try std.testing.expectEqual(@as(u32, 1) << 7, unit.pending());
}

test "the pending status register shows an interrupt only while it is enabled and its priority is neither zero nor below the threshold, C3 TRM 1.5.2" {
    var unit = started(layout);
    arm(&unit, sw_intr_0, 9, 6, true);
    unit.raise(line(sw_intr_0));
    try std.testing.expectEqual(@as(u32, 1) << 9, unit.readRegister(layout.control_base + layout.status));
    unit.writeRegister(layout.control_base + layout.enable, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.readRegister(layout.control_base + layout.status));
    unit.writeRegister(layout.control_base + layout.enable, @as(u32, 1) << 9);
    unit.writeRegister(priAt(layout, 9), 0);
    try std.testing.expectEqual(@as(u32, 0), unit.readRegister(layout.control_base + layout.status));
    unit.writeRegister(priAt(layout, 9), 6);
    unit.writeRegister(layout.control_base + layout.threshold, 7);
    try std.testing.expectEqual(@as(u32, 0), unit.readRegister(layout.control_base + layout.status));
    unit.writeRegister(layout.control_base + layout.threshold, 6);
    try std.testing.expectEqual(@as(u32, 1) << 9, unit.readRegister(layout.control_base + layout.status));
    try std.testing.expectEqual(@as(u32, 1) << 9, unit.pending());
}

test "the highest priority is claimed first, and interrupts of equal priority are ordered by their ids with the lowest highest, C3 TRM 1.5.2" {
    var unit = started(layout);
    arm(&unit, sw_intr_0, 3, 5, true);
    arm(&unit, sw_intr_1, 8, 9, true);
    unit.raise(line(sw_intr_0) | line(sw_intr_1));
    try std.testing.expectEqual(@as(?u5, 8), unit.best(ungated));
    unit.writeRegister(priAt(layout, 8), 5);
    try std.testing.expectEqual(@as(?u5, 3), unit.best(ungated));
    unit.writeRegister(priAt(layout, 3), 4);
    try std.testing.expectEqual(@as(?u5, 8), unit.best(ungated));
}

test "raising the threshold masks an interrupt already pending, and lowering it lets the same one through, C3 TRM 1.5.2" {
    var unit = started(layout);
    arm(&unit, sw_intr_0, 3, 5, true);
    arm(&unit, sw_intr_1, 8, 9, true);
    unit.raise(line(sw_intr_0) | line(sw_intr_1));
    unit.writeRegister(layout.control_base + layout.threshold, 9);
    try std.testing.expectEqual(@as(?u5, 8), unit.best(ungated));
    unit.writeRegister(layout.control_base + layout.threshold, 10);
    try std.testing.expectEqual(@as(?u5, null), unit.best(ungated));
    unit.writeRegister(layout.control_base + layout.threshold, 1);
    try std.testing.expectEqual(@as(?u5, 8), unit.best(ungated));
}

test "a line above the last peripheral interrupt source reaches no mapping register, C3 TRM Table 8.3-1" {
    var unit = started(layout);
    unit.writeRegister(layout.control_base + layout.enable, 0xffff_ffff);
    unit.writeRegister(priAt(layout, 1), 1);
    unit.raise(@as(Lines, 1) << (regions.lines - 1));
    try std.testing.expectEqual(@as(u32, 0), unit.pending());
}

const c6 = intc.esp32c6;

test "the C6 routes 77 sources and its mapping register still sits at four times the source number, C6 TRM 10.3.1 and 10.4.1" {
    var unit = started(c6);
    unit.writeRegister(mapAt(c6, 76), 9);
    unit.writeRegister(mapAt(c6, 22), 5);
    try std.testing.expectEqual(@as(u32, 9), unit.readRegister(c6.matrix_base + 4 * 76));
    try std.testing.expectEqual(@as(u32, 5), unit.readRegister(c6.matrix_base + 4 * 22));
    unit.writeRegister(c6.control_base + c6.enable, 0xffff_ffff);
    unit.writeRegister(priAt(c6, 9), 1);
    unit.raise(line(76));
    try std.testing.expectEqual(@as(u32, 1) << 9, unit.pending());
    unit.hold(line(77));
    try std.testing.expectEqual(@as(u32, 0), unit.pending());
}

test "the C6 takes an enabled priority-zero interrupt while the threshold is zero, and a threshold of one masks it, C6 TRM 1.6.2 and 1.6.3.2" {
    var unit = started(c6);
    unit.writeRegister(mapAt(c6, c6.software_source), 5);
    unit.writeRegister(c6.control_base + c6.enable, 1 << 5);
    unit.writeRegister(c6.control_base + c6.software, 1);
    try std.testing.expectEqual(@as(u32, 1) << 5, unit.status());
    try std.testing.expectEqual(@as(?u5, 5), unit.best(ungated));
    unit.writeRegister(c6.control_base + c6.threshold, 1);
    try std.testing.expectEqual(@as(u32, 0), unit.status());
    try std.testing.expectEqual(@as(?u5, null), unit.best(ungated));
}

test "the C6's priority registers start at id 0 and run to id 31, where the C3's start at id 1, C6 TRM 10.4.2" {
    var unit = started(c6);
    unit.writeRegister(c6.control_base + c6.priority, 3);
    unit.writeRegister(c6.control_base + c6.priority + 4 * 31, 12);
    try std.testing.expectEqual(@as(u32, 3), unit.readRegister(priAt(c6, 0)));
    try std.testing.expectEqual(@as(u32, 12), unit.readRegister(priAt(c6, 31)));
    try std.testing.expectEqual(@as(u32, 0), unit.readRegister(c6.control_base + c6.threshold));
}

test "the four ids the C6's core local interrupts own are reachable by no source in the matrix, C6 TRM 1.7.1 and 10.3.2" {
    for ([_]u5{ 0, 3, 4, 7 }, 0..) |id, i| {
        var unit = started(c6);
        arm(&unit, 40 + i, id, 9, false);
        unit.raise(line(40 + i));
        try std.testing.expectEqual(@as(u32, 0), unit.readRegister(c6.control_base + c6.status));
        try std.testing.expectEqual(@as(?u5, null), unit.best(ungated));
    }
    var unit = started(c6);
    arm(&unit, 40, 8, 9, false);
    unit.raise(line(40));
    try std.testing.expectEqual(@as(u32, 1) << 8, unit.readRegister(c6.control_base + c6.status));
}

test "a one written to a C6 software interrupt register asserts its source until a zero drops it, C6 TRM 10.4.2 and Table 10.3-1" {
    var unit = started(c6);
    arm(&unit, c6.software_source, 5, 7, false);
    try std.testing.expectEqual(@as(u32, 0), unit.pending());
    unit.writeRegister(c6.control_base + c6.software, 1);
    try std.testing.expectEqual(@as(u32, 1), unit.readRegister(c6.control_base + c6.software));
    try std.testing.expectEqual(@as(u32, 1) << 5, unit.pending());
    unit.hold(0);
    try std.testing.expectEqual(@as(u32, 1) << 5, unit.pending());
    unit.writeRegister(c6.control_base + c6.software, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.pending());
}

test "the fourth software interrupt register raises the fourth source, and an edge-type interrupt latches on it, C6 TRM 10.4.2" {
    var unit = started(c6);
    arm(&unit, c6.software_source + 3, 6, 7, true);
    unit.writeRegister(c6.control_base + c6.software + 12, 1);
    try std.testing.expectEqual(@as(u32, 1) << 6, unit.pending());
    unit.writeRegister(c6.control_base + c6.software + 12, 0);
    try std.testing.expectEqual(@as(u32, 1) << 6, unit.pending());
    unit.writeRegister(c6.control_base + c6.clear, @as(u32, 1) << 6);
    try std.testing.expectEqual(@as(u32, 0), unit.pending());
}

test "the C6's threshold register is eight bits wide, so a threshold above the highest priority masks every interrupt, C6 TRM Register 10.68" {
    var unit = started(c6);
    arm(&unit, c6.software_source, 5, 15, false);
    unit.writeRegister(c6.control_base + c6.threshold, 0x10);
    try std.testing.expectEqual(@as(u32, 0x10), unit.readRegister(c6.control_base + c6.threshold));
    unit.writeRegister(c6.control_base + c6.software, 1);
    try std.testing.expectEqual(@as(u32, 0), unit.status());
    unit.writeRegister(c6.control_base + c6.threshold, 0xff);
    try std.testing.expectEqual(@as(u32, 0xff), unit.readRegister(c6.control_base + c6.threshold));
    unit.writeRegister(c6.control_base + c6.threshold, 15);
    try std.testing.expectEqual(@as(u32, 1) << 5, unit.status());
}

test "a one written over a one in a C6 software interrupt register is no rising edge, so an edge-type interrupt does not latch again, C6 TRM 1.6.2" {
    var unit = started(c6);
    arm(&unit, c6.software_source, 6, 7, true);
    unit.writeRegister(c6.control_base + c6.software, 1);
    try std.testing.expectEqual(@as(u32, 1) << 6, unit.pending());
    unit.writeRegister(c6.control_base + c6.clear, @as(u32, 1) << 6);
    unit.writeRegister(c6.control_base + c6.clear, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.pending());
    unit.writeRegister(c6.control_base + c6.software, 1);
    try std.testing.expectEqual(@as(u32, 0), unit.pending());
    unit.writeRegister(c6.control_base + c6.software, 0);
    unit.writeRegister(c6.control_base + c6.software, 1);
    try std.testing.expectEqual(@as(u32, 1) << 6, unit.pending());
}

test "an interrupt the C6's block lets through is taken only where mie has its bit as well, C6 TRM 1.6.2" {
    var unit = started(c6);
    arm(&unit, 40, 9, 7, false);
    unit.raise(line(40));
    try std.testing.expectEqual(@as(u32, 1) << 9, unit.status());
    try std.testing.expectEqual(@as(?u5, null), unit.best(0));
    try std.testing.expectEqual(@as(?u5, null), unit.best(~(@as(u32, 1) << 9)));
    try std.testing.expectEqual(@as(?u5, 9), unit.best(@as(u32, 1) << 9));
}

test "the C3's registers are nowhere in the C6's blocks, so a build carrying both keeps them apart, C6 TRM 10.4.2" {
    var unit = started(c6);
    unit.writeRegister(intc.esp32c3.control_base + intc.esp32c3.enable, 0xffff_ffff);
    unit.writeRegister(intc.esp32c3.control_base + intc.esp32c3.threshold, 5);
    try std.testing.expectEqual(@as(u32, 0), unit.readRegister(c6.control_base + c6.enable));
    try std.testing.expectEqual(@as(u32, 0), unit.readRegister(c6.control_base + c6.threshold));
}
