# crt0.S - start-up for all four harts
# Every hart starts at 0. Each gets a 1 KB stack below 0xF000. Hart 0 clears
# .bss and then sets the BOOT register; the other harts wait for it, so a
# program can rely on zeroed globals even after a board reset (BOOT is cleared
# by reset, memory is not). Then main(hartid) runs; if it returns, the hart
# parks.
    .section .text.init, "ax"
    .globl _start
_start:
    csrr  a0, mhartid
    li    sp, 0xF000
    slli  t0, a0, 10
    sub   sp, sp, t0
    li    t1, 0x80000014          # BOOT
    bnez  a0, 2f
    la    t2, __bss_start
    la    t3, __bss_end
1:  bgeu  t2, t3, 3f
    sw    zero, 0(t2)
    addi  t2, t2, 4
    j     1b
3:  li    t4, 1
    sw    t4, 0(t1)
    j     4f
2:  lw    t4, 0(t1)
    beqz  t4, 2b
4:  call  main
5:  j     5b
