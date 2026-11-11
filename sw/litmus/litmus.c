// litmus.c - memory-model litmus tests on the four harts.
// Each test runs RUNS times. Two-thread tests run as two copies at once
// (harts 0/1 and 2/3, separate variables); IRIW uses all four harts. Before
// every run each thread reads the variables (so the lines are Shared in every
// cache and loads hit) and waits a pseudo-random few cycles, so the threads
// interleave differently. Hart 0 counts every outcome and prints them.
//
// An outcome marked "forbidden" must never appear under RVWMO (the RISC-V
// memory model); seeing one is a bug. "allowed" outcomes may or may not
// appear; seeing them shows which reorderings this core really does.
// EXIT = 1 if no forbidden outcome was seen.
#include "soc.h"

#ifndef RUNS
#define RUNS 50
#endif
#ifndef DELAY_MASK
#define DELAY_MASK 7      // start skew: 1..DELAY_MASK+1 turns of a short loop
#endif
#define LINE __attribute__((aligned(32)))

struct pair_vars { volatile unsigned x LINE; volatile unsigned y LINE; };
static struct pair_vars v[2];
static volatile unsigned res[4][8] LINE;      // one line per hart: r0, r1
static volatile unsigned barrier_ctr LINE;
static unsigned count[8][16];                 // hart 0 only

#define FENCE() __asm__ volatile("fence rw,rw" ::: "memory")
static inline void st1(volatile unsigned *p)
{
    __asm__ volatile("sw %1, 0(%0)" :: "r"(p), "r"(1) : "memory");
}
static inline unsigned ld(volatile unsigned *p)
{
    unsigned r;
    __asm__ volatile("lw %0, 0(%1)" : "=r"(r) : "r"(p) : "memory");
    return r;
}
// A load whose address is ready only after a chain of eight dependent adds,
// so a younger load can be issued ahead of it.
static inline unsigned ld_late(volatile unsigned *p)
{
    unsigned r;
    __asm__ volatile(
        "addi %1, %1, 0\n addi %1, %1, 0\n addi %1, %1, 0\n addi %1, %1, 0\n"
        "addi %1, %1, 0\n addi %1, %1, 0\n addi %1, %1, 0\n addi %1, %1, 0\n"
        "lw   %0, 0(%1)"
        : "=r"(r), "+r"(p) :: "memory");
    return r;
}

// Six dependent adds: holds up retirement, so a younger store stays in the
// store queue (not yet visible to other harts) for a few more cycles.
static inline void slow(void)
{
    unsigned z = 0;
    __asm__ volatile(
        "addi %0, %0, 1\n addi %0, %0, 1\n addi %0, %0, 1\n"
        "addi %0, %0, 1\n addi %0, %0, 1\n addi %0, %0, 1"
        : "+r"(z));
}

static void barrier(unsigned *round)
{
    *round += 1;
    __atomic_fetch_add(&barrier_ctr, 1, __ATOMIC_SEQ_CST);
    while (barrier_ctr < 4 * *round)
        ;
}

static void delay(unsigned *rng)
{
    unsigned s = *rng;
    s ^= s << 13; s ^= s >> 17; s ^= s << 5;
    *rng = s;
    unsigned d = (s & DELAY_MASK) + 1;
    __asm__ volatile("1: addi %0, %0, -1\n bnez %0, 1b" : "+r"(d));
}

enum { MP, MP_F, SB, SB_F, CORR, LB, IRIW_F, NTESTS };
static const char *const name[NTESTS] = {
    "MP        ", "MP+fence  ", "SB        ", "SB+fence  ",
    "CoRR      ", "LB        ", "IRIW+fence"
};
// The outcome of interest, and whether RVWMO forbids it
static const unsigned watch[NTESTS]     = { 2, 2, 0, 0, 2, 3, 10 };
static const unsigned forbidden[NTESTS] = { 0, 1, 0, 1, 1, 0, 1 };
static const char *const watch_txt[NTESTS] = {
    "r1=1 r2=0", "r1=1 r2=0", "r0=0 r1=0", "r0=0 r1=0",
    "r1=1 r2=0", "r0=1 r1=1", "1 0 / 1 0"
};

static void body(unsigned t, unsigned hart, unsigned *rng)
{
    struct pair_vars *pv = &v[(t == IRIW_F) ? 0 : hart >> 1];
    unsigned role = (t == IRIW_F) ? hart : (hart & 1);
    unsigned a = 0, b = 0;
    // Warm up: every thread reads both variables, so each cache holds both
    // lines (Shared) and the test's loads hit. The fence waits for these
    // loads, then a random delay skews the threads' start.
    (void)ld(&pv->x);
    (void)ld(&pv->y);
    FENCE();
    delay(rng);
    switch (t) {
    case MP:     if (role == 0) { st1(&pv->x); st1(&pv->y); }
                 else { a = ld_late(&pv->y); b = ld(&pv->x); } break;
    case MP_F:   if (role == 0) { st1(&pv->x); FENCE(); st1(&pv->y); }
                 else { a = ld_late(&pv->y); FENCE(); b = ld(&pv->x); } break;
    case SB:     if (role == 0) { slow(); st1(&pv->x); a = ld(&pv->y); }
                 else { slow(); st1(&pv->y); a = ld(&pv->x); } break;
    case SB_F:   if (role == 0) { slow(); st1(&pv->x); FENCE(); a = ld(&pv->y); }
                 else { slow(); st1(&pv->y); FENCE(); a = ld(&pv->x); } break;
    case CORR:   if (role == 0) { st1(&pv->x); }
                 else { a = ld_late(&pv->x); b = ld(&pv->x); } break;
    case LB:     if (role == 0) { a = ld(&pv->x); st1(&pv->y); }
                 else { a = ld(&pv->y); st1(&pv->x); } break;
    case IRIW_F: if (role == 0) st1(&pv->x);
                 else if (role == 1) st1(&pv->y);
                 else if (role == 2) { a = ld(&pv->x); FENCE(); b = ld(&pv->y); }
                 else { a = ld(&pv->y); FENCE(); b = ld(&pv->x); } break;
    }
    res[hart][0] = a;
    res[hart][1] = b;
}

static void tally(unsigned t)
{
    if (t == IRIW_F) {
        count[t][(res[2][0] << 3) | (res[2][1] << 2) | (res[3][0] << 1) | res[3][1]]++;
        return;
    }
    for (unsigned p = 0; p < 2; p++) {
        unsigned h0 = 2 * p, h1 = 2 * p + 1, o;
        if (t == SB || t == SB_F || t == LB)
            o = (res[h0][0] << 1) | res[h1][0];       // one load per thread
        else
            o = (res[h1][0] << 1) | res[h1][1];       // reader is the second hart
        count[t][o]++;
    }
}

int main(unsigned hart)
{
    unsigned round = 0, rng = 0x9E3779B9u * (hart + 1);

    for (unsigned t = 0; t < NTESTS; t++) {
        for (unsigned r = 0; r < RUNS; r++) {
            if (hart == 0) {
                v[0].x = 0; v[0].y = 0; v[1].x = 0; v[1].y = 0;
            }
            barrier(&round);
            body(t, hart, &rng);
            barrier(&round);
            if (hart == 0)
                tally(t);
        }
        LEDS = 1u << t;
    }
    if (hart != 0)
        for (;;)
            ;

    unsigned bad = 0;
    uart_puts("litmus: ");
    uart_putdec(RUNS);
    uart_puts(" runs per test, 2 copies (IRIW: 1)\r\n");
    for (unsigned t = 0; t < NTESTS; t++) {
        unsigned n = count[t][watch[t]];
        uart_puts(name[t]);
        uart_puts(forbidden[t] ? "  forbidden " : "  allowed   ");
        uart_puts(watch_txt[t]);
        uart_puts(": ");
        if (forbidden[t]) {
            uart_puts(n ? "SEEN " : "never seen OK");
            if (n) uart_putdec(n);
            bad += n;
        } else {
            uart_puts("seen ");
            uart_putdec(n);
        }
        uart_puts("   [");
        unsigned nout = (t == IRIW_F) ? 16 : 4;
        for (unsigned o = 0; o < nout; o++) {
            if (t == IRIW_F && !count[t][o]) continue;
            if (o) uart_putc(' ');
            for (int bit = (t == IRIW_F) ? 3 : 1; bit >= 0; bit--)
                uart_putc('0' + ((o >> bit) & 1));
            uart_putc(':');
            uart_putdec(count[t][o]);
        }
        uart_puts("]\r\n");
    }
    uart_puts(bad ? "litmus: FORBIDDEN OUTCOMES SEEN\r\n" : "litmus: no forbidden outcome\r\n");
    HEX = bad;
    LEDS = bad ? 0xFFFF : 0xF;
    EXIT = bad ? 3 : 1;
    for (;;)
        ;
}
