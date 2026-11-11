// soc.h - memory-mapped I/O of the quad-core SoC (see rtl/io/soc_io.v)
#ifndef SOC_H
#define SOC_H

#define IO_REG(off)  (*(volatile unsigned *)(0x80000000u + (off)))
#define UART_TX      IO_REG(0x00)   // write: send one byte (waits while busy)
#define UART_STATUS  IO_REG(0x04)   // bit 0: transmitter busy
#define EXIT         IO_REG(0x08)   // write: result word (1 = pass); ends a simulation
#define LEDS         IO_REG(0x0C)   // 16 board LEDs
#define HEX          IO_REG(0x10)   // 8-digit 7-segment display
#define BOOT         IO_REG(0x14)   // cleared by reset, set by hart 0 after start-up

static inline unsigned read_mcycle(void)   { unsigned x; __asm__ volatile ("csrr %0, mcycle"   : "=r"(x)); return x; }
static inline unsigned read_minstret(void) { unsigned x; __asm__ volatile ("csrr %0, minstret" : "=r"(x)); return x; }
static inline unsigned read_hartid(void)   { unsigned x; __asm__ volatile ("csrr %0, mhartid"  : "=r"(x)); return x; }

static inline void uart_putc(char c) { UART_TX = (unsigned char)c; }
static inline void uart_puts(const char *s) { while (*s) uart_putc(*s++); }
static inline void uart_puthex(unsigned v)
{
    for (int i = 28; i >= 0; i -= 4) {
        unsigned d = (v >> i) & 15;
        uart_putc(d < 10 ? '0' + d : 'a' + d - 10);
    }
}

#endif
