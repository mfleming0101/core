    .syntax unified
    .thumb

    .section .vectors, "a"
    .word _stack
    .word _start
    .word nmi_handler
    .word hard_fault_handler
    .word mem_manage_handler
    .word bus_fault_handler
    .word usage_fault_handler
    .word 0
    .word 0
    .word 0
    .word 0
    .word svc_handler
    .word debug_handler
    .word 0
    .word pendsv_handler
    .word systick_handler
    .rept 240
    .word irq_entry
    .endr

    .text
    .thumb_func
    .global _start
_start:
    ldr r0, =_stack
    mov sp, r0
    ldr r0, =_data_load
    ldr r1, =_data_start
    ldr r2, =_data_end
1:  cmp r1, r2
    beq 2f
    ldr r3, [r0], #4
    str r3, [r1], #4
    b 1b
2:  ldr r0, =_bss_start
    ldr r1, =_bss_end
    movs r2, #0
3:  cmp r0, r1
    beq 4f
    str r2, [r0], #4
    b 3b
4:  bl main
    bl console_crc
    .thumb_func
    .global bench_exit
bench_exit:
    bkpt #0
    b bench_exit
