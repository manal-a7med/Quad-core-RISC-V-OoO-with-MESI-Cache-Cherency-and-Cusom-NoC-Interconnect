# Memory-hierarchy stress: write a 24 KB pattern (larger than L1D + L2, so
# dirty lines are evicted from both levels to main memory), mixing byte,
# half and word stores, then read it all back with several load sizes.
#include "riscv_test.h"
#define BASE  0x2000
#define WORDS 6144
        .section .text.init
        .globl _start
_start:
        csrr t0, mhartid
        beqz t0, 1f
park:   j    park
1:      li   gp, 1
        # pass 1: word stores, value = addr ^ 0x5a5a0000
        li   s0, BASE
        li   s1, WORDS
        li   s2, 0x5a5a0000
        mv   t0, s0
        mv   t1, s1
w1:     xor  t2, t0, s2
        sw   t2, 0(t0)
        addi t0, t0, 4
        addi t1, t1, -1
        bnez t1, w1
        # pass 3: read back and check every word
        li   gp, 3
        mv   t0, s0
        mv   t1, s1
r1:     lw   t2, 0(t0)
        xor  t3, t0, s2
        bne  t2, t3, fail
        lbu  t4, 0(t0)
        andi t5, t3, 0xff
        bne  t4, t5, fail
        lhu  t4, 2(t0)
        srli t5, t3, 16
        bne  t4, t5, fail
        addi t0, t0, 4
        addi t1, t1, -1
        bnez t1, r1
        # pass 4: byte stores then word read in a second sweep
        li   gp, 4
        mv   t0, s0
        mv   t1, s1
        li   t6, 0xa5
w4:     sb   t6, 1(t0)
        addi t0, t0, 128            # one store per 4 lines
        addi t1, t1, -32
        bgtz t1, w4
        mv   t0, s0
        mv   t1, s1
r4:     lw   t2, 0(t0)
        xor  t3, t0, s2
        li   t4, 0xffff00ff
        and  t3, t3, t4
        li   t4, 0xa500
        or   t3, t3, t4
        bne  t2, t3, fail
        addi t0, t0, 128
        addi t1, t1, -32
        bgtz t1, r4
        RVTEST_PASS
fail:   RVTEST_FAIL
