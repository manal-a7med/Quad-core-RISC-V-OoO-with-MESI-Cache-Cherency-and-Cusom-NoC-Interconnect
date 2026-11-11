/* Minimal libc headers for the benchmarks (no C library in the toolchain);
   the functions are in sw/bench/shim.c. */
#ifndef BENCH_STDIO_H
#define BENCH_STDIO_H
#include <stdarg.h>
int printf(const char *fmt, ...);
int vprintf(const char *fmt, va_list ap);
#endif
