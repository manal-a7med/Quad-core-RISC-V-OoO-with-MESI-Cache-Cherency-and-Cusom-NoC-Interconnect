// Minimal bare-metal environment for running riscv-tests (rv32ui) on the
// riscv_ooo_core: no CSRs, traps or privilege modes. Code starts at 0.
// Result is written to TOHOST: 1 = pass, (TESTNUM << 1) | 1 = fail.
// Only hart 0 runs the test; other harts park in a loop.
#ifndef _ENV_OOO_H
#define _ENV_OOO_H

#define TOHOST 0xFFF0

#define RVTEST_RV32U .macro init; .endm
#define RVTEST_RV64U RVTEST_RV32U
#define TESTNUM gp

#define RVTEST_CODE_BEGIN       \
        .section .text.init;    \
        .align 2;               \
        .globl _start;          \
_start:                         \
        csrr t0, mhartid;       \
        beqz t0, 2f;            \
1:      j 1b;                   \
2:      li TESTNUM, 0;

#define RVTEST_CODE_END         \
        unimp

#define RVTEST_PASS             \
        li t5, 1;               \
        li t6, TOHOST;          \
        sw t5, 0(t6);           \
1:      j 1b;

#define RVTEST_FAIL             \
        slli t5, TESTNUM, 1;    \
        ori  t5, t5, 1;         \
        li t6, TOHOST;          \
        sw t5, 0(t6);           \
1:      j 1b;

#define EXTRA_DATA
#define RVTEST_DATA_BEGIN EXTRA_DATA .align 4;
#define RVTEST_DATA_END

#endif
