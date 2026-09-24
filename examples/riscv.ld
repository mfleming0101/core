MEMORY {
    flash (rx) : ORIGIN = 0x42000000, LENGTH = 64K
    ram (rw) : ORIGIN = 0x3FC80000, LENGTH = 8K
}
_stack = ORIGIN(ram) + LENGTH(ram);
SECTIONS {
    .text : { KEEP(*(.text.entry)) *(.text*) *(.rodata*) } > flash
    .bss : { *(.bss*) } > ram
}
