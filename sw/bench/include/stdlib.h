#ifndef BENCH_STDLIB_H
#define BENCH_STDLIB_H
#include <stddef.h>
void exit(int code) __attribute__((noreturn));
void abort(void) __attribute__((noreturn));
#endif
