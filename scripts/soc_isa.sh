#!/bin/sh
# Run the ISA test hex files (built by `make isa`) on the full quad-core SoC.
# Usage: scripts/soc_isa.sh [extra vvp args, e.g. +all]
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/soc; mkdir -p "$OUT"
SRC="$ROOT/rtl/core/*.v $ROOT/rtl/cache/l1_icache.v $ROOT/rtl/cache/l1_dcache.v $ROOT/rtl/cache/l2_cache.v \
     $ROOT/rtl/coherence/bus_arbiter.v $ROOT/rtl/coherence/coherence_bus.v $ROOT/rtl/coherence/snoop_controller.v \
     $ROOT/rtl/memory/*.v $ROOT/rtl/io/*.v $ROOT/rtl/top/quad_core_top.v"
iverilog -g2012 -DSIM -I "$ROOT/rtl/core" -I "$ROOT/rtl/cache" -I "$ROOT/verif" -o "$OUT/soc.vvp" $SRC "$ROOT/verif/soc/tb_soc.v" || exit 1
pass=0; fail=0; : > "$OUT/summary.txt"
for h in "$ROOT"/build/isa/*.hex; do
  t=$(basename "$h" .hex)
  res=$(vvp -n "$OUT/soc.vvp" +hex="$h" "$@" | grep RESULT || echo "RESULT NONE")
  echo "$t $res" | tee -a "$OUT/summary.txt"
  case "$res" in *PASS*) pass=$((pass+1));; *) fail=$((fail+1));; esac
done
echo "soc: $pass passed, $fail failed" | tee -a "$OUT/summary.txt"
[ "$fail" -eq 0 ]
