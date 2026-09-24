MEMORY {
    flash (rx) : ORIGIN = 0x42000000, LENGTH = 4M
    dram (rw) : ORIGIN = 0x3FC80000, LENGTH = 384K
}
_stack = ORIGIN(dram) + LENGTH(dram);
SECTIONS {
    .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) *(.srodata*) } > flash
    .bss (NOLOAD) : { *(.bss*) *(.sbss*) *(COMMON) } > dram
    /DISCARD/ : { *(.comment) *(.riscv.attributes) }
}
