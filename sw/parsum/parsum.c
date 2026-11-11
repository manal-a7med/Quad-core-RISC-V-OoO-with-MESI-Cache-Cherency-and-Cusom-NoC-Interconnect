// parsum.c - parallel array sum on four harts.
// Each hart fills and sums its quarter of a shared array, publishes its
// partial sum and a done flag; hart 0 waits for all four, adds the partial
// sums, checks the total and reports per-hart cycle counts over the UART.
// The result goes to the 7-segment display; EXIT = 1 if the total is right.
#include "soc.h"

#define N      2048
#define CHUNK  (N / 4)

static unsigned data[N];
// One cache line (32 bytes) per hart, so the flags do not share lines.
static volatile unsigned partial[4][8];
static volatile unsigned done[4][8];
static volatile unsigned cycles[4][8];

int main(unsigned hart)
{
    unsigned t0 = read_mcycle();
    unsigned *p = &data[hart * CHUNK];
    unsigned base = hart * CHUNK, sum = 0;
    for (unsigned i = 0; i < CHUNK; i++)
        p[i] = base + i;
    for (unsigned i = 0; i < CHUNK; i++)
        sum += p[i];
    partial[hart][0] = sum;
    cycles[hart][0] = read_mcycle() - t0;
    done[hart][0] = 1;
    LEDS = 1u << hart;                     // last hart to finish stays lit

    if (hart != 0)
        for (;;)
            ;

    unsigned total = 0;
    for (unsigned h = 0; h < 4; h++) {
        while (!done[h][0])
            ;
        total += partial[h][0];
    }
    for (unsigned h = 0; h < 4; h++) {
        uart_puts("hart ");
        uart_putc('0' + h);
        uart_puts(": partial=0x");
        uart_puthex(partial[h][0]);
        uart_puts(" cycles=0x");
        uart_puthex(cycles[h][0]);
        uart_puts("\r\n");
    }
    uart_puts("total=0x");
    uart_puthex(total);
    unsigned expect = (unsigned)N * (N - 1) / 2;
    uart_puts(total == expect ? " OK\r\n" : " WRONG\r\n");
    HEX = total;
    LEDS = 0xF;
    EXIT = (total == expect) ? 1 : 3;
    for (;;)
        ;
}
