#!/bin/sh
# Run the ISA test hex files (built by `make isa`) on the full quad-core SoC.
# Usage: scripts/soc_isa.sh [extra vvp args, e.g. +all]
# NOC=1 [NOC_BANKS=4] [NOC_FLIT=128] in the environment: the NoC + directory build.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/rtl/core/*.v $ROOT/rtl/cache/l1_icache.v $ROOT/rtl/cache/l1_dcache.v $ROOT/rtl/cache/l2_cache.v \
     $ROOT/rtl/coherence/bus_arbiter.v $ROOT/rtl/coherence/coherence_bus.v $ROOT/rtl/coherence/snoop_controller.v \
     $ROOT/rtl/coherence/bus_interconnect.v $ROOT/rtl/memory/*.v $ROOT/rtl/io/*.v $ROOT/rtl/top/quad_core_top.v"
DEFS=""
OUT=$ROOT/build/soc
if [ -n "$NOC" ]; then
  B=${NOC_BANKS:-1}; T=noc$B; FD=""
  [ -n "$NOC_FLIT" ] && { T=${T}_f$NOC_FLIT; FD="-DNOC_FLIT_W=$NOC_FLIT"; }
  SRC="$SRC $ROOT/rtl/noc/*.v"; DEFS="-DNOC -DNOC_BANKS=$B $FD -I $ROOT/rtl/noc"; OUT=$ROOT/build/$T/soc
fi
mkdir -p "$OUT"
iverilog -g2012 -DSIM $DEFS -I "$ROOT/rtl/core" -I "$ROOT/rtl/cache" -I "$ROOT/verif" -o "$OUT/soc.vvp" $SRC "$ROOT/verif/soc/tb_soc.v" || exit 1
pass=0; fail=0; : > "$OUT/summary.txt"
for h in "$ROOT"/build/isa/*.hex; do
  t=$(basename "$h" .hex)
  res=$(vvp -n "$OUT/soc.vvp" +hex="$h" "$@" | grep RESULT || echo "RESULT NONE")
  echo "$t $res" | tee -a "$OUT/summary.txt"
  case "$res" in *PASS*) pass=$((pass+1));; *) fail=$((fail+1));; esac
done
echo "soc: $pass passed, $fail failed" | tee -a "$OUT/summary.txt"
[ "$fail" -eq 0 ]
