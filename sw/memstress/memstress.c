// memstress.c - directed test of the load/store queue under pressure
//
// Straight-line bursts of stores and loads, with nothing in between to let
// the queue drain, in the patterns that used to go wrong or could:
//   1. 24 stores in a row (more than the queue and issue queue hold together:
//      a store issued into a full queue used to be dropped)
//   2. 24 loads in a row
//   3. store, load, store, load on one word (store-to-load forwarding)
//   4. two byte stores then a word load of the same word, behind a chain of
//      dependent adds of varying length (the load must wait for both stores,
//      and they must wait for the adds to retire)
// Each pattern runs with 0 to 7 dependent adds in front of it, which shifts
// the timing between dispatch, issue and the cache. Hart 0 runs the test;
// the other harts hammer a word in the same cache lines' neighbourhood so
// the caches keep losing lines to the bus while the bursts are in flight.
#include "soc.h"

#define BURST 24

// void burst_st<k>(unsigned *p, unsigned v): p[i] = v + (i % 6), i < BURST
// unsigned burst_ld<k>(unsigned *p): sum of p[0..BURST-1]
// unsigned fwd<k>(unsigned *p, unsigned v): eight store/load/increment rounds on p[0]
// unsigned bytes<k>(unsigned *p, unsigned lo, unsigned hi): sb lo, sb hi, lw
__asm__(
    ".macro chain k\n"
    "    mv   t6, a1\n"
    "    .rept \\k\n"
    "    add  t6, t6, a1\n"
    "    .endr\n"
    ".endm\n"

    ".macro variants k\n"
    "    .globl burst_st\\k\n"
    "burst_st\\k:\n"
    "    addi t0, a1, 1\n"
    "    addi t1, a1, 2\n"
    "    addi t2, a1, 3\n"
    "    addi t3, a1, 4\n"
    "    addi t4, a1, 5\n"
    "    chain \\k\n"
    "    .set i, 0\n"
    "    .rept 4\n"
    "    sw   a1, i(a0)\n"
    "    sw   t0, i+4(a0)\n"
    "    sw   t1, i+8(a0)\n"
    "    sw   t2, i+12(a0)\n"
    "    sw   t3, i+16(a0)\n"
    "    sw   t4, i+20(a0)\n"
    "    .set i, i+24\n"
    "    .endr\n"
    "    ret\n"

    "    .globl burst_ld\\k\n"
    "burst_ld\\k:\n"
    "    mv   a1, a0\n"
    "    chain \\k\n"
    "    .set i, 0\n"
    "    .rept 4\n"
    "    lw   t0, i(a0)\n"
    "    lw   t1, i+4(a0)\n"
    "    lw   t2, i+8(a0)\n"
    "    lw   t3, i+12(a0)\n"
    "    lw   t4, i+16(a0)\n"
    "    lw   t5, i+20(a0)\n"
    "    add  a2, t0, t1\n"
    "    add  a3, t2, t3\n"
    "    add  a4, t4, t5\n"
    "    add  a2, a2, a3\n"
    "    add  a2, a2, a4\n"
    "    .if i\n"
    "    add  a5, a5, a2\n"
    "    .else\n"
    "    mv   a5, a2\n"
    "    .endif\n"
    "    .set i, i+24\n"
    "    .endr\n"
    "    mv   a0, a5\n"
    "    ret\n"

    "    .globl fwd\\k\n"
    "fwd\\k:\n"
    "    chain \\k\n"
    "    .rept 8\n"
    "    sw   a1, 0(a0)\n"
    "    lw   a1, 0(a0)\n"
    "    addi a1, a1, 1\n"
    "    .endr\n"
    "    mv   a0, a1\n"
    "    ret\n"

    "    .globl bytes\\k\n"
    "bytes\\k:\n"
    "    chain \\k\n"
    "    sb   a1, 0(a0)\n"
    "    sb   a2, 1(a0)\n"
    "    lw   a3, 0(a0)\n"
    "    sh   a2, 2(a0)\n"
    "    lbu  a4, 3(a0)\n"
    "    lw   a5, 0(a0)\n"
    "    add  a0, a3, a5\n"
    "    add  a0, a0, a4\n"
    "    ret\n"
    ".endm\n"

    "    .text\n"
    "    variants 0\n    variants 1\n    variants 2\n    variants 3\n"
    "    variants 4\n    variants 5\n    variants 6\n    variants 7\n"
);

#define DECL(k) \
    void burst_st##k(unsigned *, unsigned); unsigned burst_ld##k(unsigned *); \
    unsigned fwd##k(unsigned *, unsigned);  unsigned bytes##k(unsigned *, unsigned, unsigned);
DECL(0) DECL(1) DECL(2) DECL(3) DECL(4) DECL(5) DECL(6) DECL(7)

typedef void     (*st_fn)(unsigned *, unsigned);
typedef unsigned (*ld_fn)(unsigned *);
typedef unsigned (*fw_fn)(unsigned *, unsigned);
typedef unsigned (*by_fn)(unsigned *, unsigned, unsigned);
#define ALL(n) { n##0, n##1, n##2, n##3, n##4, n##5, n##6, n##7 }
static const st_fn st_tab[8] = ALL(burst_st);
static const ld_fn ld_tab[8] = ALL(burst_ld);
static const fw_fn fw_tab[8] = ALL(fwd);
static const by_fn by_tab[8] = ALL(bytes);

static unsigned buf[BURST + 8];
static volatile unsigned noise[4];      // next to buf: other harts write here
static volatile unsigned done;
static unsigned checks, errors;

static void check(unsigned got, unsigned want)
{
    checks++;
    if (got != want)
        errors++;
}

int main(unsigned hart)
{
    if (hart != 0) {
        while (!done)
            noise[hart]++;
        for (;;)
            ;
    }

    for (unsigned round = 0; round < 4; round++) {
        for (unsigned k = 0; k < 8; k++) {
            unsigned *p = buf + ((round + k) & 7);
            unsigned  v = 0x1000 * (round + 1) + 0x10 * k;
            unsigned  sum = 0;

            st_tab[k](p, v);
            for (unsigned i = 0; i < BURST; i++) {
                check(p[i], v + i % 6);
                sum += v + i % 6;
            }
            check(ld_tab[k](p), sum);
            check(fw_tab[k](p, v), v + 8);
            check(p[0], v + 7);

            p[1] = 0x44332211;
            // bytes 0,1 replaced, word read; bytes 2,3 replaced, byte 3 and word read
            unsigned lo = 0xA0 + k, hi = 0xB0 + round;
            unsigned w1 = 0x44330000 | (hi << 8) | lo;
            unsigned w2 = (hi << 16) | (hi << 8) | lo;      // sh writes hi as a halfword
            check(by_tab[k](p + 1, lo, hi), w1 + w2 + 0);   // byte 3 of the halfword is 0
        }
    }
    done = 1;

    uart_puts("memstress: ");
    uart_putdec(checks);
    uart_puts(" checks, ");
    uart_putdec(errors);
    uart_puts(" errors\r\n");
    uart_puts("cycles: ");
    uart_putdec(read_mcycle());
    uart_puts("\r\n");
    HEX  = (checks << 16) | errors;
    EXIT = errors ? 3 : 1;
    for (;;)
        ;
}
