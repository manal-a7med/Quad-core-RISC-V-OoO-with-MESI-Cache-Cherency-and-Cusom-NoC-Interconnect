# Machine-mode system test: CSRs, counters, ECALL/EBREAK/MRET, illegal
# instructions. Uses the bare-metal env (TOHOST: 1 = pass, 2n+1 = fail at n).
#include "riscv_test.h"

#define FAIL_IF_NE(a, b, n)  li gp, n; bne a, b, fail

        .section .text.init
        .globl _start
_start:
        li   gp, 0
        la   t0, handler
        csrw mtvec, t0

        # 1: mhartid of core 0 is 0
        csrr t1, mhartid
        FAIL_IF_NE(t1, x0, 1)

        # 2: mtvec reads back
        csrr t1, mtvec
        FAIL_IF_NE(t1, t0, 2)

        # 3-5: mscratch with CSRRW / CSRRS / CSRRC / immediates
        li   t2, 0x0f0
        csrw mscratch, t2
        csrrsi t1, mscratch, 0x00f     # t1 = old 0x0f0
        li   t3, 0x00f
        csrrs t1, mscratch, t3         # t1 = old (0x0ff after the line above)
        csrr t4, mscratch
        li   t5, 0x0ff
        FAIL_IF_NE(t4, t5, 3)
        li   t3, 0x0f0
        csrrc t1, mscratch, t3
        csrr t4, mscratch
        li   t5, 0x00f
        FAIL_IF_NE(t4, t5, 4)
        csrrwi t1, mscratch, 7
        FAIL_IF_NE(t1, t5, 5)          # old value returned

        # 6: mcycle advances
        csrr t1, mcycle
        nop
        nop
        csrr t2, mcycle
        li   gp, 6
        bgeu t1, t2, fail

        # 7: minstret advances and the user alias matches it
        csrr t1, minstret
        csrr t2, instret
        li   gp, 7
        bgeu t1, t2, fail

        # 8: ECALL traps with mcause 11 and mepc = the ecall
        li   s1, 0
        la   s2, ecall_at
ecall_at:
        ecall
        li   t1, 11
        FAIL_IF_NE(s3, t1, 8)          # handler saved mcause in s3
        FAIL_IF_NE(s4, s2, 9)          # and mepc in s4

        # 10: EBREAK traps with mcause 3
        la   s2, ebreak_at
ebreak_at:
        ebreak
        li   t1, 3
        FAIL_IF_NE(s3, t1, 10)
        FAIL_IF_NE(s4, s2, 11)

        # 12: an all-zero word is illegal, mtval = the instruction
        la   s2, illegal_at
illegal_at:
        .word 0x00000000
        li   t1, 2
        FAIL_IF_NE(s3, t1, 12)
        FAIL_IF_NE(s5, x0, 13)

        # 14: writing a read-only CSR is illegal
        la   s2, ro_at
ro_at:
        csrw mhartid, t1
        li   t1, 2
        FAIL_IF_NE(s3, t1, 14)

        # 15: an unimplemented CSR is illegal
        la   s2, unimpl_at
unimpl_at:
        csrr t1, 0x7c0
        li   t1, 2
        FAIL_IF_NE(s3, t1, 15)

        # 16: the handler ran exactly 5 times
        li   t1, 5
        FAIL_IF_NE(s1, t1, 16)

        # 17: a trapping instruction does not write its rd
        li   t6, 0x55
        la   s2, nowrite_at
nowrite_at:
        csrr t6, 0x7c0
        li   t1, 0x55
        FAIL_IF_NE(t6, t1, 17)

        RVTEST_PASS
fail:
        RVTEST_FAIL

# Trap handler: count traps, record mcause/mepc/mtval, skip the instruction.
        .align 2
handler:
        addi s1, s1, 1
        csrr s3, mcause
        csrr s4, mepc
        csrr s5, mtval
        addi t0, s4, 4
        csrw mepc, t0
        mret
