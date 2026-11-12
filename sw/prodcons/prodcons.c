// prodcons.c - producer/consumer queue on four harts.
// Hart 0 produces ITEMS numbered items into a 16-slot ring buffer; harts 1-3
// take them out. The producer writes an item, then a release fence, then
// moves `head`, so a consumer that sees the new head also sees the item.
// A consumer reads the item at `tail` and then claims it by moving `tail`
// with compare-and-swap (lr.w/sc.w); if another consumer got there first the
// swap fails and it tries again, so each item is taken exactly once. Each
// consumer marks the items it took in a shared bitmap with amoor.w, which
// would reveal an item taken twice. Hart 0 checks the count, the sum and the
// bitmap; EXIT = 1 if every item arrived exactly once.
#include "soc.h"

#define ITEMS 200
#define SLOTS 16
#define LINE  __attribute__((aligned(32)))

static volatile unsigned ring[SLOTS] LINE;
static volatile unsigned head LINE;          // next slot to fill (producer)
static volatile unsigned tail LINE;          // next slot to take (consumers)
static volatile unsigned taken[4][8];        // one line per consumer
static volatile unsigned summed[4][8];
static volatile unsigned bitmap[(ITEMS + 32) / 32] LINE;
static volatile unsigned dups LINE;
static volatile unsigned finished LINE;

static void produce(void)
{
    for (unsigned i = 0; i < ITEMS; i++) {
        while (i - tail >= SLOTS)               // ring full: wait for consumers
            ;
        ring[i % SLOTS] = i + 1;                 // item i has value i + 1
        __atomic_thread_fence(__ATOMIC_RELEASE); // item before head
        head = i + 1;
        LEDS = 1;
    }
}

static void consume(unsigned hart)
{
    unsigned n = 0, sum = 0;
    for (;;) {
        unsigned t = tail;
        if (t >= ITEMS)
            break;
        if (t == head)                           // empty
            continue;
        __atomic_thread_fence(__ATOMIC_ACQUIRE); // head before the item
        unsigned v = ring[t % SLOTS];
        unsigned expect = t;
        if (__atomic_compare_exchange_n(&tail, &expect, t + 1, 0,
                                        __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
            n++;
            sum += v;
            unsigned bit = 1u << (v & 31);
            if (__atomic_fetch_or(&bitmap[v >> 5], bit, __ATOMIC_RELAXED) & bit)
                __atomic_fetch_add(&dups, 1, __ATOMIC_RELAXED);
            LEDS = 1u << hart;
        }
    }
    taken[hart][0] = n;
    summed[hart][0] = sum;
    __atomic_fetch_add(&finished, 1, __ATOMIC_SEQ_CST);
}

int main(unsigned hart)
{
    if (hart != 0) {
        consume(hart);
        for (;;)
            ;
    }
    unsigned t0 = read_mcycle();
    produce();
    while (finished != 3)
        ;
    unsigned cycles = read_mcycle() - t0;

    unsigned total = 0, sum = 0, missing = 0;
    uart_puts("prodcons: hart 0 produced ");
    uart_putdec(ITEMS);
    uart_puts(" items through a 16-slot ring\r\n");
    for (unsigned h = 1; h < 4; h++) {
        uart_puts("hart ");
        uart_putc('0' + h);
        uart_puts(" took ");
        uart_putdec(taken[h][0]);
        uart_puts(" items\r\n");
        total += taken[h][0];
        sum += summed[h][0];
    }
    for (unsigned v = 1; v <= ITEMS; v++)
        if (!(bitmap[v >> 5] & (1u << (v & 31))))
            missing++;
    unsigned want = ITEMS * (ITEMS + 1) / 2;
    int ok = total == ITEMS && sum == want && dups == 0 && missing == 0;
    uart_puts("total ");
    uart_putdec(total);
    uart_puts(" items, sum ");
    uart_putdec(sum);
    uart_puts(ok ? " OK" : " WRONG");
    uart_puts(", duplicates ");
    uart_putdec(dups);
    uart_puts(", missing ");
    uart_putdec(missing);
    uart_puts("\r\ncycles: ");
    uart_putdec(cycles);
    uart_puts("\r\n");
    HEX = sum;
    LEDS = 0xF;
    EXIT = ok ? 1 : 3;
    for (;;)
        ;
}
