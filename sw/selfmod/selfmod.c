// selfmod.c - code written by stores, then executed (FENCE.I, review bug 16)
//
// Each hart writes a two-instruction function "return K" into its own
// buffer, runs FENCE.I and calls it; then overwrites it with "return K2" and
// calls it twice: once without FENCE.I (the instruction cache may still hold
// the old line, so either value is legal and the result is only reported),
// and once after FENCE.I, when it must be the new value.
// Then code written by another hart: hart 1 writes "return 0x333" into a
// shared buffer and raises a flag; hart 0 runs FENCE.I and calls it. The
// newest copy of that line is in hart 1's data cache (Modified), so hart 0's
// instruction fetch has to get it over the coherence bus.
#include "soc.h"

#define LI_A0(k)  (0x00000513u | ((unsigned)(k) << 20))   // addi a0, x0, k
#define RET       0x00008067u                             // jalr x0, 0(ra)

typedef unsigned (*fn)(void);

// One cache line (32 bytes) per buffer. Word 2 is a data word that shares the
// line with the code.
static unsigned code[4][8] __attribute__((aligned(32)));
static unsigned shared_code[8] __attribute__((aligned(32)));
static volatile unsigned shared_ready;
static unsigned inline_code[4][8] __attribute__((aligned(32)));
static volatile unsigned first[4][8], stale[4][8], second[4][8], third[4][8], done[4][8];

static inline void fence_i(void) { __asm__ volatile (".word 0x0000100f")   /* fence.i */; }

int main(unsigned hart)
{
    unsigned *c = code[hart];
    unsigned k1 = 0x100 + hart, k2 = 0x200 + hart;

    c[0] = LI_A0(k1);
    c[1] = RET;
    fence_i();
    first[hart][0] = ((fn)c)();

    c[2] = k2;                      // a data store into the line being executed
    c[0] = LI_A0(k2);
    stale[hart][0] = ((fn)c)();     // old or new: both are legal without FENCE.I
    fence_i();
    second[hart][0] = ((fn)c)();

    // FENCE.I inside the rewritten function: "fence.i; return K". The first
    // call puts the line in the instruction cache. After the rewrite, the
    // instruction right behind the FENCE.I has already been fetched from the
    // old line when the FENCE.I executes, and must be fetched again.
    unsigned *d = inline_code[hart];
    d[0] = 0x0000100f;
    d[1] = LI_A0(0x300 + hart);
    d[2] = RET;
    fence_i();
    third[hart][0] = ((fn)d)();
    d[1] = LI_A0(0x400 + hart);
    third[hart][0] = (third[hart][0] << 16) | ((fn)d)();

    if (hart == 1) {
        shared_code[0] = LI_A0(0x333);
        shared_code[1] = RET;
        shared_ready = 1;
    }
    done[hart][0] = 1;
    if (hart != 0)
        for (;;)
            ;

    unsigned errors = 0;
    for (unsigned h = 0; h < 4; h++) {
        while (!done[h][0])
            ;
        unsigned ok = first[h][0] == 0x100 + h && second[h][0] == 0x200 + h && code[h][2] == 0x200 + h &&
                      third[h][0] == (((0x300 + h) << 16) | (0x400 + h));
        errors += !ok;
        uart_puts("hart ");
        uart_putc('0' + h);
        uart_puts(": first=0x");
        uart_puthex(first[h][0]);
        uart_puts(" after fence.i=0x");
        uart_puthex(second[h][0]);
        uart_puts(" inline=0x");
        uart_puthex(third[h][0]);
        uart_puts(ok ? " OK\r\n" : " WRONG\r\n");
        uart_puts("  without fence.i the call ran the ");
        uart_puts(stale[h][0] == 0x100 + h ? "old code\r\n" :
                  stale[h][0] == 0x200 + h ? "new code\r\n" : "WRONG code\r\n");
        errors += stale[h][0] != 0x100 + h && stale[h][0] != 0x200 + h;
    }

    while (!shared_ready)
        ;
    fence_i();
    unsigned r = ((fn)shared_code)();
    uart_puts("code written by hart 1, run by hart 0: 0x");
    uart_puthex(r);
    uart_puts(r == 0x333 ? " OK\r\n" : " WRONG\r\n");
    errors += r != 0x333;

    uart_puts("selfmod: ");
    uart_putdec(errors);
    uart_puts(" errors\r\n");
    HEX  = r;
    LEDS = 0xF;
    EXIT = errors ? 3 : 1;
    for (;;)
        ;
}
