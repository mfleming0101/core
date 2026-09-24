	.option norvc
	.section .text.start, "ax"
	.globl _start
_start:

	la	sp, _stack
	jal	ra, main

	li	a0, 0x18
	li	a1, 0x20026
	slli	zero, zero, 0x1f
	ebreak
	srai	zero, zero, 7

1:	jal	zero, 1b

	.option norvc
	.section .text.trap, "ax"
	.balign 256
	.globl trap_vector
trap_vector:
	csrrw	t0, mscratch, t0
	sw	t1, 16(t0)
	csrr	t1, mcause
	sw	t1, 0(t0)
	csrr	t1, mtval
	sw	t1, 4(t0)
	csrr	t1, mepc
	sw	t1, 8(t0)
	lw	t1, 12(t0)
	addi	t1, t1, 1
	sw	t1, 12(t0)
	addi	t1, t1, -1
	bnez	t1, 2f
	lw	t1, 0(t0)
	sw	t1, 24(t0)
	lw	t1, 4(t0)
	sw	t1, 28(t0)
2:
	lw	t1, 0(t0)
	addi	t1, t1, -1
	bnez	t1, 3f
	lw	t1, 20(t0)
	beqz	t1, 3f
	csrw	mepc, t1
	j	4f
3:
	csrr	t1, mepc
	addi	t1, t1, 4
	csrw	mepc, t1
4:
	li	t1, 0x1800
	csrs	mstatus, t1
	lw	t1, 16(t0)
	csrrw	t0, mscratch, t0
	mret
