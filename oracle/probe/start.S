    .syntax unified
    .thumb

    .section .vectors, "a"
    .word _stack
    .word _start
    .word halt
    .word fault_handler
    .word fault_handler
    .word fault_handler
    .word fault_handler
    .word halt
    .word halt
    .word halt
    .word halt
    .word return_handler
    .word halt
    .word halt
    .word return_handler
    .word return_handler
    .rept 32
    .word irq_handler
    .endr

    .text
    .thumb_func
    .global _start
_start:
    ldr r0, =_stack
    mov sp, r0
    ldr r0, =_bss_start
    ldr r1, =_bss_end
    movs r2, #0
1:  cmp r0, r1
    beq 2f
    str r2, [r0]
    adds r0, #4
    b 1b
2:  bl main
    movs r0, #0x18
    ldr r1, =0x20026
    bkpt 0xab

    .thumb_func
    .global halt
halt:
    bkpt #0
    b halt

    .thumb_func
    .global fault_handler
fault_handler:
    mrs r0, ipsr
    ldr r1, =fault_ipsr
    str r0, [r1]
    ldr r0, =0xe000ed28
    ldr r0, [r0]
    ldr r1, =fault_cfsr
    str r0, [r1]
    ldr r0, =0xe000ed2c
    ldr r0, [r0]
    ldr r1, =fault_hfsr
    str r0, [r1]
    ldr r0, =0xe000ed24
    ldr r0, [r0]
    ldr r1, =fault_shcsr
    str r0, [r1]
    ldr r0, [sp, #24]
    adds r0, #4
    str r0, [sp, #24]
    bx lr

    .thumb_func
    .global irq_handler
irq_handler:
    mrs r0, ipsr
    ldr r1, =irq_ipsr
    str r0, [r1]
    ldr r0, =0xe000e300
    ldr r0, [r0]
    ldr r1, =irq_iabr
    str r0, [r1]
    ldr r0, =0xe000ed04
    ldr r0, [r0]
    ldr r1, =irq_icsr
    str r0, [r1]
    ldr r0, =0xe000ed24
    ldr r0, [r0]
    ldr r1, =irq_shcsr
    str r0, [r1]
    bx lr

    .thumb_func
    .global return_handler
return_handler:
    mrs r0, ipsr
    ldr r1, =system_ipsr
    str r0, [r1]
    bx lr
