// ldorder.c - checks that one hart performs two loads of the same address in
// program order (RVWMO rule CoRR), even when the younger load reaches the
// load/store queue in a lower slot than the older one.
//
// The two loads read the TIMER register, a free-running cycle counter, so a
// load performed later returns a larger value. Each round runs, on hart 0:
//
//   lw a, m1        miss: holds the data cache
//   lw c, m2        miss: waits in the queue, then holds the cache
//   lw old, TIMER   waits in the queue behind m2
//   lw new, TIMER   address depends on a, so it enters the queue after m1
//                   has left it, in m1's (lower) slot
//
// When m2 finishes, both TIMER loads are waiting. Picking by slot number
// would perform the younger one first, and then old > new. The load/store
// unit must perform loads of the same bytes oldest first (see
// docs/architecture.md, section 2.1). m1 and m2 are lines in a memory area
// that nothing else uses (not even the start-up code, which clears .bss), so
// both miss in the L1 and the L2.
#include "soc.h"

#define ROUNDS 32
#define UNUSED_AREA 0xC000u   // below the stacks, above this small program

int main(unsigned hart)
{
    if (hart != 0)
        for (;;)
            ;
    extern char __bss_end[];
    if ((unsigned)__bss_end > UNUSED_AREA) {   // the program grew into the area
        uart_puts("ldorder: program too large FAIL\r\n");
        EXIT = 2;
    }
    unsigned bad = 0, gap_min = ~0u;
    for (unsigned r = 0; r < ROUNDS; r++) {
        unsigned old, new_, a, c;
        volatile unsigned *m1 = (volatile unsigned *)(UNUSED_AREA + 64 * r);
        volatile unsigned *m2 = m1 + 8;
        __asm__ volatile(
            "lw   %2, 0(%4)\n"
            "lw   %3, 0(%5)\n"
            "lw   %0, 0(%6)\n"
            "and  t0, %2, zero\n"
            "add  t0, t0, %6\n"
            "lw   %1, 0(t0)\n"
            : "=&r"(old), "=&r"(new_), "=&r"(a), "=&r"(c)
            : "r"(m1), "r"(m2), "r"(&TIMER)
            : "t0", "memory");
        (void)c;
        if (new_ < old)
            bad++;
        else if (new_ - old < gap_min)
            gap_min = new_ - old;
    }
    uart_puts("ldorder: ");
    uart_putdec(ROUNDS);
    uart_puts(" rounds, ");
    if (bad) {
        uart_puts("younger load performed first ");
        uart_putdec(bad);
        uart_puts(" times FAIL\r\n");
    } else {
        uart_puts("same-address loads in order OK\r\n");
    }
    EXIT = bad ? 2 : 1;
    for (;;)
        ;
}
