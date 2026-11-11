// hello.c - each hart greets in turn over the UART, then lights its LED.
// Harts take turns through a shared variable (`turn`), so this also checks
// that a store by one core becomes visible to the others (MESI).
// Hart 3 shows the elapsed cycle count on the 7-segment display and exits.
#include "soc.h"

static volatile unsigned turn;

int main(unsigned hart)
{
    while (turn != hart)
        ;
    uart_puts("hello from hart ");
    uart_putc('0' + hart);
    uart_puts("\r\n");
    LEDS = LEDS | (1u << hart);
    turn = hart + 1;
    if (hart == 3) {
        HEX = read_mcycle();
        EXIT = 1;
    }
    for (;;)
        ;
}
