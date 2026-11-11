// shim.c - runs the riscv-tests benchmarks (riscv-tests/benchmarks) on this
// SoC. It replaces their syscalls.c: printf over the UART, setStats() timing
// with mcycle/minstret, exit() through the EXIT register, the string
// functions they call, and the thread entry point. Built by scripts/bench.sh.
//
// Single-thread benchmarks define main(), renamed bench_main at compile time;
// it runs on hart 0 while the other harts park. Multi-thread benchmarks
// define thread_entry(cid, nc) and run on harts 0..NCORES-1.
#include <stdarg.h>
#include <stddef.h>
#include "soc.h"

#ifndef NCORES
#define NCORES 4
#endif

int bench_main(int argc, char **argv);

static unsigned stat_cycles, stat_instret, stat_c0, stat_i0;

void setStats(int enable)
{
    if (read_hartid() != 0)
        return;
    unsigned c = read_mcycle(), i = read_minstret();
    if (enable) {
        stat_c0 = c;
        stat_i0 = i;
    } else {
        stat_cycles += c - stat_c0;
        stat_instret += i - stat_i0;
    }
}

// ---------------------------------------------------------------- printf
static void put_uint(unsigned v, unsigned base, int width, char pad, int upper)
{
    char buf[12];
    int n = 0;
    do {
        unsigned d = v % base;
        buf[n++] = d < 10 ? '0' + d : (upper ? 'A' : 'a') + d - 10;
        v /= base;
    } while (v);
    while (width-- > n)
        uart_putc(pad);
    while (n)
        uart_putc(buf[--n]);
}

int vprintf(const char *fmt, va_list ap)
{
    for (; *fmt; fmt++) {
        if (*fmt != '%') {
            if (*fmt == '\n')
                uart_putc('\r');
            uart_putc(*fmt);
            continue;
        }
        char pad = ' ';
        int width = 0;
        fmt++;
        if (*fmt == '0') { pad = '0'; fmt++; }
        while (*fmt >= '0' && *fmt <= '9')
            width = width * 10 + (*fmt++ - '0');
        while (*fmt == 'l' || *fmt == 'z')
            fmt++;
        switch (*fmt) {
        case 'd': case 'i': {
            int v = va_arg(ap, int);
            if (v < 0) { uart_putc('-'); v = -v; width--; }
            put_uint((unsigned)v, 10, width, pad, 0);
            break;
        }
        case 'u': put_uint(va_arg(ap, unsigned), 10, width, pad, 0); break;
        case 'x': put_uint(va_arg(ap, unsigned), 16, width, pad, 0); break;
        case 'X': put_uint(va_arg(ap, unsigned), 16, width, pad, 1); break;
        case 'p': uart_puts("0x"); put_uint(va_arg(ap, unsigned), 16, 8, '0', 0); break;
        case 'c': uart_putc((char)va_arg(ap, int)); break;
        case 's': { const char *s = va_arg(ap, const char *); uart_puts(s ? s : "(null)"); break; }
        case '%': uart_putc('%'); break;
        default:  uart_putc('%'); uart_putc(*fmt); break;
        }
    }
    return 0;
}

int printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    return 0;
}


// ---------------------------------------------------------------- exit
void __attribute__((noreturn)) exit(int code)
{
    if (read_hartid() != 0)                  // only hart 0 ends the run
        for (;;)
            ;
    if (stat_cycles)
        printf("BENCH cycles=%u instret=%u\n", stat_cycles, stat_instret);
    EXIT = code == 0 ? 1 : ((unsigned)code << 1) | 1;
    for (;;)
        ;
}

void __attribute__((noreturn)) abort(void) { exit(134); }

// ---------------------------------------------------------------- strings
void *memcpy(void *d, const void *s, size_t n)
{
    char *dp = d;
    const char *sp = s;
    while (n--)
        *dp++ = *sp++;
    return d;
}

void *memset(void *d, int c, size_t n)
{
    char *dp = d;
    while (n--)
        *dp++ = (char)c;
    return d;
}

size_t strlen(const char *s)
{
    const char *p = s;
    while (*p)
        p++;
    return p - s;
}

char *strcpy(char *d, const char *s)
{
    char *r = d;
    while ((*d++ = *s++))
        ;
    return r;
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

// ---------------------------------------------------------------- entry
void __attribute__((weak)) thread_entry(int cid, int nc)
{
    (void)nc;
    while (cid != 0)
        ;
}

int __attribute__((weak)) bench_main(int argc, char **argv)
{
    (void)argc; (void)argv;
    return 0;
}

int main(unsigned hart)
{
    if (hart >= NCORES)
        for (;;)
            ;
    thread_entry(hart, NCORES);
    exit(bench_main(0, 0));
}
