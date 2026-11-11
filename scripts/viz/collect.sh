#!/bin/sh
# Collect evidence for the results page: runs the repro testbench, the rv32ui
# riscv-tests and the OoO demo on two versions of the core (a baseline git ref
# and the working tree), with pipeline tracing, into build/viz/.
# Usage: scripts/viz/collect.sh <riscv-tests checkout> [baseline-ref]
set -e
RVT=${1:?path to riscv-tests checkout}
BASE=${2:-5ac1f58}            # imported teammate RTL + review commits
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
V=$ROOT/build/viz; rm -rf "$V"; mkdir -p "$V/before" "$V/after"
OBJDUMP=${OBJDUMP:-riscv64-unknown-elf-objdump}

git -C "$ROOT" archive "$BASE" rtl/core | tar -x -C "$V/before"
mkdir -p "$V/after/rtl" && cp -r "$ROOT/rtl/core" "$V/after/rtl/"
git -C "$ROOT" rev-parse --short "$BASE" > "$V/before/ref"
git -C "$ROOT" rev-parse --short HEAD > "$V/after/ref"

# Demo program
CC=riscv64-unknown-elf-gcc
$CC -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -Wl,--no-warn-rwx-segments \
    -T "$ROOT/verif/riscv-tests/env/link.ld" "$ROOT/verif/demo/ooo_demo.S" -o "$V/demo.elf"
riscv64-unknown-elf-objcopy -O binary "$V/demo.elf" "$V/demo.bin"
od -An -v -tx4 -w4 "$V/demo.bin" | tr -d ' ' > "$V/demo.hex"
$OBJDUMP -d "$V/demo.elf" > "$V/demo.dis"

# Repro program disassembly
cp "$ROOT/review/prog.hex" "$V/prog.hex"
python3 -c "
import struct,sys
w=[int(l,16) for l in open('$V/prog.hex') if l.strip()]
open('$V/prog.bin','wb').write(b''.join(struct.pack('<I',x) for x in w))"
$OBJDUMP -D -b binary -m riscv:rv32 "$V/prog.bin" > "$V/prog.dis"

for v in before after; do
  R=$V/$v/rtl/core
  iverilog -g2012 -DSIM -I "$R" -I "$ROOT/verif" -o "$V/$v/repro.vvp" "$R"/*.v "$ROOT/review/tb_repro.v"
  (cd "$V" && vvp -n "$v/repro.vvp" +trace > "$v/repro.log")
  iverilog -g2012 -DSIM -I "$R" -I "$ROOT/verif" -o "$V/$v/isa.vvp" "$R"/*.v "$ROOT/verif/riscv-tests/tb_isa.v"
  vvp -n "$V/$v/isa.vvp" +hex="$V/demo.hex" +trace > "$V/$v/demo.log"
  RTL=$R OUT=$V/$v/isa sh "$ROOT/verif/riscv-tests/run.sh" "$RVT" > /dev/null 2>&1 || true
  cp "$V/$v/isa/summary.txt" "$V/$v/isa_summary.txt"
done
# Does each core version get through Yosys elaboration?
for v in before after; do
  if yosys -q -p "read_verilog -DSYNTHESIS -I $V/$v/rtl/core $V/$v/rtl/core/*.v; hierarchy -top riscv_ooo_core; proc" > "$V/$v/yosys_check.txt" 2>&1
  then echo OK >> "$V/$v/yosys_check.txt"; fi
done
[ -f "$ROOT/build/synth.log" ] && cp "$ROOT/build/synth.log" "$V/synth_generic.log" || true
[ -f "$ROOT/build/synth_fpga_core.log" ] && cp "$ROOT/build/synth_fpga_core.log" "$V/synth_x7.log" || true

# P2: the full SoC. C demos on the 4-core SoC and on the board-level model
# of fpga_top, the ISA programs on the SoC, and the Artix-7 estimate of
# fpga_top (make synth-fpga, slow: run it first to include it).
# The ISA programs must have been built (the rv32ui runs above do that).
mkdir -p "$V/soc"
for p in hello parsum; do
  make -C "$ROOT" -s soc-run PROG=$p > /dev/null 2>&1 || true
  make -C "$ROOT" -s fpga-sim PROG=$p > /dev/null 2>&1 || true
  cp "$ROOT/build/sw/$p.log" "$ROOT/build/sw/$p.fpga.log" "$V/soc/" 2>/dev/null || true
done
# (REUSE_SOC_ISA=1 reuses build/soc/summary.txt from an earlier make soc-isa)
[ -n "$REUSE_SOC_ISA" ] || sh "$ROOT/scripts/soc_isa.sh" > /dev/null 2>&1 || true
cp "$ROOT/build/soc/summary.txt" "$V/soc/isa_summary.txt" 2>/dev/null || true
[ -f "$ROOT/build/synth_fpga.log" ] && cp "$ROOT/build/synth_fpga.log" "$V/soc/synth_fpga.log" || true
echo "collected into $V"
