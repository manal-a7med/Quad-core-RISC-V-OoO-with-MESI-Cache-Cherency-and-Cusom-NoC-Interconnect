#!/bin/sh
# Build and run rv32ui riscv-tests on the OoO core.
# Usage: verif/riscv-tests/run.sh <path-to-riscv-tests-checkout> [test ...]
set -e
RVT=${1:?path to riscv-tests checkout}; shift
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
RTL=${RTL:-$ROOT/rtl/core}   # override to test another copy of the core
OUT=${OUT:-$ROOT/build/isa}; mkdir -p "$OUT"
CC=${CC:-riscv64-unknown-elf-gcc}
OBJCOPY=${OBJCOPY:-riscv64-unknown-elf-objcopy}
TESTS=${*:-$(cd "$RVT/isa/rv32ui" && ls *.S | sed 's/\.S$//' | grep -v -e fence_i -e ma_data)}

iverilog -g2012 -DSIM -I "$RTL" -o "$OUT/tb_isa.vvp" "$RTL"/*.v "$HERE/tb_isa.v"

pass=0; fail=0; : > "$OUT/summary.txt"
for t in $TESTS; do
  $CC -march=rv32i -mabi=ilp32 -static -nostdlib -Wl,--no-warn-rwx-segments -nostartfiles \
      -I "$HERE/env" -I "$RVT/isa/macros/scalar" -T "$HERE/env/link.ld" \
      "$RVT/isa/rv32ui/$t.S" -o "$OUT/$t.elf"
  $OBJCOPY -O binary "$OUT/$t.elf" "$OUT/$t.bin"
  od -An -v -tx4 -w4 "$OUT/$t.bin" | tr -d ' ' > "$OUT/$t.hex"
  res=$(vvp -n "$OUT/tb_isa.vvp" +hex="$OUT/$t.hex" | grep RESULT || echo "RESULT NONE")
  echo "$t $res" | tee -a "$OUT/summary.txt"
  case "$res" in *PASS*) pass=$((pass+1));; *) fail=$((fail+1));; esac
done
echo "rv32ui: $pass passed, $fail failed" | tee -a "$OUT/summary.txt"
[ "$fail" -eq 0 ]
