/* link.ld - programs run from address 0 of the 64 KB main memory.
   Stacks: 1 KB per hart from 0xF000 down (0xE000-0xF000). */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0, LENGTH = 0xE000 }
SECTIONS
{
  .text   : { *(.text.init) *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
  .data   : ALIGN(32) { *(.data .data.* .sdata .sdata.*) } > RAM
  .bss    : ALIGN(32) { __bss_start = .; *(.sbss .sbss.* .bss .bss.* COMMON) . = ALIGN(4); __bss_end = .; } > RAM
}
