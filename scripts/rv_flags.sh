#!/bin/sh
# rv_flags.sh <gcc> <march> - prints the -march and linker flags this RISC-V
# GCC accepts, e.g. "-march=rv32ima_zicsr -Wl,--no-warn-rwx-segments".
#   GCC before 12 (Ubuntu 22.04 ships 10.2) follows the older ISA spec, where
#   CSR and FENCE.I instructions are part of the base ISA and the _zicsr and
#   _zifencei names are rejected: they are dropped for such a compiler.
#   binutils before 2.39 do not know --no-warn-rwx-segments: left out there.
# The code generated is the same either way.
CC=${1:-riscv64-unknown-elf-gcc}; M=${2:-rv32ima_zicsr}
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
printf 'void _start(void) { for (;;); }\n' > "$t/a.c"
try() { "$CC" "$@" -mabi=ilp32 -nostdlib -nostartfiles -static "$t/a.c" -o "$t/a.elf" > /dev/null 2>&1; }
try -march="$M" || M=$(echo "$M" | sed 's/_zicsr//; s/_zifencei//')
F="-march=$M"
try -march="$M" -Wl,--no-warn-rwx-segments && F="$F -Wl,--no-warn-rwx-segments"
echo "$F"
