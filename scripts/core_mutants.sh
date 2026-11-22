#!/bin/sh
# Mutation check of the core's memory-ordering tests: each mutant is a copy
# of the design with one deliberate bug in the load/store unit, and the named
# program must fail on it (and pass on the real design, as in make regress).
# Usage: scripts/core_mutants.sh      (needs build/sw/<prog>.hex: make sw)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LSU=$ROOT/rtl/core/load_store_unit.v
OUT=$ROOT/build/core_mutants
rm -rf "$OUT"; mkdir -p "$OUT"
# Every SoC source except the load/store unit (bus build)
SRC=$(ls "$ROOT"/rtl/core/*.v "$ROOT"/rtl/cache/*.v "$ROOT"/rtl/coherence/*.v \
         "$ROOT"/rtl/memory/*.v "$ROOT"/rtl/io/*.v "$ROOT"/rtl/top/quad_core_top.v | grep -v load_store_unit.v)

caught=0; total=0
# mutant <name> <program> <sed expression> <description>
mutant() {
  total=$((total + 1))
  cp "$LSU" "$OUT/lsu.v"
  sed -i "$3" "$OUT/lsu.v"
  if cmp -s "$OUT/lsu.v" "$LSU"; then
    echo "mutant $1: NOT APPLIED ($4)"; return
  fi
  iverilog -g2012 -DSIM -DNO_UART_ECHO -I "$ROOT/rtl/core" -I "$ROOT/rtl/cache" -I "$ROOT/verif" \
    -o "$OUT/$1.vvp" $SRC "$OUT/lsu.v" "$ROOT/verif/soc/tb_soc.v" 2> "$OUT/$1.build.log" ||
    { echo "mutant $1: BUILD FAILED"; return; }
  vvp -n "$OUT/$1.vvp" +hex="$ROOT/build/sw/$2.hex" > "$OUT/$1.log" 2>&1
  if grep -q 'RESULT PASS' "$OUT/$1.log"; then
    echo "mutant $1: MISSED by $2 | $4"
  else
    caught=$((caught + 1)); echo "mutant $1: CAUGHT by $2 | $4"
  fi
}

mutant ld_ld_reorder ldorder 's/(lsq_is_store\[bj\] || lsq_is_load\[bj\])/lsq_is_store[bj]/' \
  "a load may be performed before an older load of the same bytes (CoRR)"
mutant ld_passes_store memstress 's/(lsq_is_store\[bj\] || lsq_is_load\[bj\])/lsq_is_load[bj]/' \
  "a load may read the cache before an older overlapping store is written"

echo "core mutants caught: $caught of $total"
[ "$caught" -eq "$total" ]
