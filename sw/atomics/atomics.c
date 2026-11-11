// atomics.c - four harts update shared counters, with and without atomics.
//   Phase 1: a plain counter (load, add, store). Harts interleave, so some
//            increments are lost.
//   Phase 2: the same with amoadd.w. Every increment lands.
//   Phase 3: a spinlock built from lr.w/sc.w guards a plain counter and a
//            log of which hart held the lock each time.
// Hart 0 prints the totals; EXIT = 1 if phases 2 and 3 are exact.
#include "soc.h"

#define HARTS 4
#define ITERS 200
#define TOTAL (HARTS * ITERS)
#define LINE  __attribute__((aligned(32)))   // one cache line per variable

static volatile unsigned plain_ctr  LINE;
static volatile unsigned amo_ctr    LINE;
static volatile unsigned lock_word  LINE;
static volatile unsigned locked_ctr LINE;
static volatile unsigned barrier_ctr LINE;
static volatile unsigned char order[TOTAL] LINE;   // hart that held the lock

static void barrier(unsigned round)
{
    __atomic_fetch_add(&barrier_ctr, 1, __ATOMIC_SEQ_CST);
    while (barrier_ctr < HARTS * round)
        ;
}

static void lock(volatile unsigned *l)
{
    unsigned tmp;
    __asm__ volatile(
        "1: lr.w.aq  %0, (%1)\n"
        "   bnez     %0, 1b\n"       // held: try again
        "   li       %0, 1\n"
        "   sc.w     %0, %0, (%1)\n"
        "   bnez     %0, 1b\n"       // lost the reservation: try again
        : "=&r"(tmp) : "r"(l) : "memory");
}

static void unlock(volatile unsigned *l)
{
    __atomic_store_n(l, 0, __ATOMIC_RELEASE);
}

static void report(const char *name, unsigned got, int checked)
{
    uart_puts(name);
    uart_putdec(got);
    uart_puts(" of ");
    uart_putdec(TOTAL);
    if (checked)
        uart_puts(got == TOTAL ? " OK\r\n" : " WRONG\r\n");
    else
        uart_puts(got == TOTAL ? " (none lost)\r\n" : " (updates lost)\r\n");
}

int main(unsigned hart)
{
    unsigned t[4];

    barrier(1);
    t[0] = read_mcycle();
    for (unsigned i = 0; i < ITERS; i++)
        plain_ctr = plain_ctr + 1;
    barrier(2);
    t[1] = read_mcycle();
    for (unsigned i = 0; i < ITERS; i++)
        __atomic_fetch_add(&amo_ctr, 1, __ATOMIC_RELAXED);
    barrier(3);
    t[2] = read_mcycle();
    for (unsigned i = 0; i < ITERS; i++) {
        lock(&lock_word);
        LEDS = 1u << hart;
        order[locked_ctr] = hart;
        locked_ctr = locked_ctr + 1;
        unlock(&lock_word);
    }
    barrier(4);
    t[3] = read_mcycle();

    if (hart != 0)
        for (;;)
            ;

    uart_puts("atomics: 4 harts x 200 increments of one shared counter\r\n");
    report("plain load/add/store: ", plain_ctr, 0);
    report("amoadd.w:             ", amo_ctr, 1);
    report("lr.w/sc.w spinlock:   ", locked_ctr, 1);
    uart_puts("lock holders: ");
    for (unsigned i = 0; i < 48; i++)
        uart_putc('0' + order[i]);
    uart_puts("...\r\n");
    uart_puts("cycles: plain=");
    uart_putdec(t[1] - t[0]);
    uart_puts(" amoadd=");
    uart_putdec(t[2] - t[1]);
    uart_puts(" spinlock=");
    uart_putdec(t[3] - t[2]);
    uart_puts("\r\n");

    int ok = (amo_ctr == TOTAL) && (locked_ctr == TOTAL);
    HEX = (amo_ctr << 16) | plain_ctr;
    LEDS = 0xF;
    EXIT = ok ? 1 : 3;
    for (;;)
        ;
}
