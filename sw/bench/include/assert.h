#ifndef BENCH_ASSERT_H
#define BENCH_ASSERT_H
#include <stdlib.h>
#define assert(x) do { if (!(x)) abort(); } while (0)
#endif
