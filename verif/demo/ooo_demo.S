# Out-of-order demo: sum a 4-element array.
# Each iteration's loads take several cycles; the independent pointer and
# counter updates issue ahead of the older add that waits for the load.
# Expected: a0 = 5 + 7 + 11 + 13 = 36, written to TOHOST as pass/fail.
        .section .text.init
        .globl _start
_start:
        li   s0, 0x400
        li   t1, 5
        sw   t1, 0(s0)
        li   t1, 7
        sw   t1, 4(s0)
        li   t1, 11
        sw   t1, 8(s0)
        li   t1, 13
        sw   t1, 12(s0)
        li   a0, 0
        li   a1, 4
        mv   a2, s0
loop:
        lw   t2, 0(a2)
        add  a0, a0, t2
        slli t3, t2, 1
        addi a2, a2, 4
        addi a1, a1, -1
        xor  t4, t4, a1
        bnez a1, loop
        li   t5, 1
        li   t0, 36
        beq  a0, t0, 1f
        li   t5, 3
1:      li   t6, 0xFFF0
        sw   t5, 0(t6)
2:      j    2b
