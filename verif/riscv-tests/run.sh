#!/bin/sh
# Build and run the rv32ui and rv32ua riscv-tests, plus our own tests in
# verif/system/, on the OoO core.
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
UA_TESTS=$( [ -n "$*" ] || (cd "$RVT/isa/rv32ua" && ls *.S | sed 's/\.S$//') )
SYS_TESTS=$(ls "$ROOT"/verif/system/*.S 2>/dev/null || true)

iverilog -g2012 -DSIM $ISA_DEFS -I "$RTL" -I "$ROOT/verif" -o "$OUT/tb_isa.vvp" "$RTL"/*.v "$HERE/tb_isa.v"

pass=0; fail=0; : > "$OUT/summary.txt"
run_one() {   # run_one <name> <source.S>
  $CC -march=rv32ia_zicsr -mabi=ilp32 -static -nostdlib -nostartfiles -Wl,--no-warn-rwx-segments \
      -I "$HERE/env" -I "$RVT/isa/macros/scalar" -T "$HERE/env/link.ld" "$2" -o "$OUT/$1.elf"
  $OBJCOPY -O binary "$OUT/$1.elf" "$OUT/$1.bin"
  od -An -v -tx4 -w4 "$OUT/$1.bin" | tr -d ' ' > "$OUT/$1.hex"
  res=$(vvp -n "$OUT/tb_isa.vvp" +hex="$OUT/$1.hex" | grep RESULT || echo "RESULT NONE")
  echo "$1 $res" | tee -a "$OUT/summary.txt"
  case "$res" in *PASS*) pass=$((pass+1));; *) fail=$((fail+1));; esac
}
for t in $TESTS; do run_one "$t" "$RVT/isa/rv32ui/$t.S"; done
echo "rv32ui: $pass passed, $fail failed" | tee -a "$OUT/summary.txt"
p_ui=$pass; f_ui=$fail; pass=0; fail=0
for t in $UA_TESTS; do run_one "$t" "$RVT/isa/rv32ua/$t.S"; done
[ -z "$UA_TESTS" ] || echo "rv32ua: $pass passed, $fail failed" | tee -a "$OUT/summary.txt"
f_ua=$fail; pass=0; fail=0
for s in $SYS_TESTS; do run_one "$(basename "$s" .S)" "$s"; done
echo "system: $pass passed, $fail failed" | tee -a "$OUT/summary.txt"
[ "$f_ui" -eq 0 ] && [ "$f_ua" -eq 0 ] && [ "$fail" -eq 0 ]
