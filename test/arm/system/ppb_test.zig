const std = @import("std");
const bus = @import("../../../src/arm/system/ppb.zig");

test "addresses outside the private peripheral bus belong to the memory of the part" {
    try std.testing.expectEqual(.memory, bus.region(0x0000_0000));
    try std.testing.expectEqual(.memory, bus.region(0x2000_0000));
    try std.testing.expectEqual(.memory, bus.region(0xdfff_fffc));
    try std.testing.expectEqual(.memory, bus.region(0xe010_0000));
    try std.testing.expectEqual(.memory, bus.region(0xffff_fffc));
}

test "the sixteen bytes from 0xE000E010 are the SysTick, B3.3.2" {
    try std.testing.expectEqual(.systick, bus.region(0xe000_e010));
    try std.testing.expectEqual(.systick, bus.region(0xe000_e01c));
    try std.testing.expectEqual(.ppb_unmapped, bus.region(0xe000_e020));
}

test "the sixteen bytes from 0xE000E000 hold ICTR and ACTLR, B3.2.24 B3.2.25" {
    try std.testing.expectEqual(.control, bus.region(0xe000_e000));
    try std.testing.expectEqual(.control, bus.region(0xe000_e00c));
    try std.testing.expectEqual(.systick, bus.region(0xe000_e010));
}

test "the 704 bytes from 0xE000ED00 are the System Control Block, the cache maintenance operations and the M7 control registers included, B3.2.2 B2.2.7, M7 TRM Table 3-1" {
    try std.testing.expectEqual(.scb, bus.region(0xe000_ed00));
    try std.testing.expectEqual(.scb, bus.region(0xe000_ed1c));
    try std.testing.expectEqual(.scb, bus.region(0xe000_ed3f));
    try std.testing.expectEqual(.scb, bus.region(0xe000_ed88));
    try std.testing.expectEqual(.scb, bus.region(0xe000_ed90));
    try std.testing.expectEqual(.scb, bus.region(0xe000_ef00));
    try std.testing.expectEqual(.scb, bus.region(0xe000_ef3c));
    try std.testing.expectEqual(.scb, bus.region(0xe000_ef48));
    try std.testing.expectEqual(.scb, bus.region(0xe000_ef50));
    try std.testing.expectEqual(.scb, bus.region(0xe000_ef78));
    try std.testing.expectEqual(.scb, bus.region(0xe000_ef90));
    try std.testing.expectEqual(.scb, bus.region(0xe000_efbc));
    try std.testing.expectEqual(.ppb_unmapped, bus.region(0xe000_efc0));
}

test "the 4KB from 0xE0000000 are the ITM and the 4KB from 0xE0001000 the DWT, C1.7 C1.8" {
    try std.testing.expectEqual(.itm, bus.region(0xe000_0000));
    try std.testing.expectEqual(.itm, bus.region(0xe000_0ffc));
    try std.testing.expectEqual(.dwt, bus.region(0xe000_1000));
    try std.testing.expectEqual(.dwt, bus.region(0xe000_1ffc));
    try std.testing.expectEqual(.ppb_unmapped, bus.region(0xe000_2000));
}

test "REVIDR is the word below the System Control Block and its alias the word below the alias, v8-M D1.2.222" {
    try std.testing.expectEqual(.revidr, bus.region(0xe000_ecfc));
    try std.testing.expectEqual(.revidr_ns, bus.region(0xe002_ecfc));
    try std.testing.expectEqual(.scb, bus.region(0xe000_ed00));
}

test "the Non-secure aliases of the control words, the SysTick and the NVIC sit 0x20000 above them, v8-M D1.1.20 D1.1.21 D1.1.22" {
    try std.testing.expectEqual(.control_ns, bus.region(0xe002_e000));
    try std.testing.expectEqual(.control_ns, bus.region(0xe002_e00c));
    try std.testing.expectEqual(.systick_ns, bus.region(0xe002_e010));
    try std.testing.expectEqual(.systick_ns, bus.region(0xe002_e01c));
    try std.testing.expectEqual(.nvic_ns, bus.region(0xe002_e100));
    try std.testing.expectEqual(.nvic_ns, bus.region(0xe002_e5ec));
    try std.testing.expectEqual(.ppb_unmapped, bus.region(0xe002_e020));
}

test "the 4KB from 0xE0005000 are the RAS error record, M55 TRM Table 8-3" {
    try std.testing.expectEqual(.ras, bus.region(0xe000_5000));
    try std.testing.expectEqual(.ras, bus.region(0xe000_5ffc));
    try std.testing.expectEqual(.ppb_unmapped, bus.region(0xe000_6000));
}

test "the 8KB from 0xE001E000 are the implementation defined registers of the M55 and M85, M55 TRM Table 8-3" {
    try std.testing.expectEqual(.ppb_unmapped, bus.region(0xe001_dffc));
    try std.testing.expectEqual(.impdef, bus.region(0xe001_e000));
    try std.testing.expectEqual(.impdef, bus.region(0xe001_fffc));
    try std.testing.expectEqual(.ppb_unmapped, bus.region(0xe002_0000));
}

test "the rest of the private peripheral bus is unmapped in this core" {
    try std.testing.expectEqual(.ppb_unmapped, bus.region(0xe000_dffc));
    try std.testing.expectEqual(.ppb_unmapped, bus.region(0xe000_ecf8));
    try std.testing.expectEqual(.ppb_unmapped, bus.region(0xe004_0000));
    try std.testing.expectEqual(.ppb_unmapped, bus.region(0xe00f_fffc));
}

test "the NVIC occupies 0xE000E100 to 0xE000E5EF, the whole architectural window, B3.4.1" {
    try std.testing.expectEqual(bus.Region.nvic, bus.region(0xe000_e100));
    try std.testing.expectEqual(bus.Region.nvic, bus.region(0xe000_e41c));
    try std.testing.expectEqual(bus.Region.nvic, bus.region(0xe000_e5ec));
    try std.testing.expectEqual(bus.Region.ppb_unmapped, bus.region(0xe000_e5f0));
    try std.testing.expectEqual(bus.Region.ppb_unmapped, bus.region(0xe000_e0fc));
}
