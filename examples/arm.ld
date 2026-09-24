MEMORY {
    flash (rx) : ORIGIN = 0x00000000, LENGTH = 64K
    ram (rwx) : ORIGIN = 0x20000000, LENGTH = 8K
}
_stack = ORIGIN(ram) + LENGTH(ram);
SECTIONS {
    .text : { KEEP(*(.vectors)) *(.text*) *(.rodata*) } > flash
    .bss : { *(.bss*) } > ram
    /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) }
}
