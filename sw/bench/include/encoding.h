/* The part of riscv-tests' encoding.h the benchmarks use */
#ifndef BENCH_ENCODING_H
#define BENCH_ENCODING_H
#define read_csr(reg) ({ unsigned long __tmp; \
    __asm__ volatile ("csrr %0, " #reg : "=r"(__tmp)); __tmp; })
#define write_csr(reg, val) ({ __asm__ volatile ("csrw " #reg ", %0" :: "rK"(val)); })
#endif
