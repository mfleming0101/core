MEMORY {
    flash (rx) : ORIGIN = 0x00000000, LENGTH = 1M
    ram (rw)   : ORIGIN = 0x00200000, LENGTH = 1M
}
_stack = ORIGIN(ram) + LENGTH(ram);
SECTIONS {
    .text   : { KEEP(*(.vectors)) *(.text*) } > flash
    .rodata : { *(.rodata*) } > flash
    .data   : { . = ALIGN(4); _data_start = .; *(.data*) . = ALIGN(4); _data_end = .; } > ram AT> flash
    _data_load = LOADADDR(.data);
    .bss    : { . = ALIGN(4); _bss_start = .; *(.bss*) *(COMMON) . = ALIGN(4); _bss_end = .; } > ram
}
