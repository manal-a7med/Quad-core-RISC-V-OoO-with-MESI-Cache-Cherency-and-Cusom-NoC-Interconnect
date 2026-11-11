#!/bin/sh
# Mutation check of the random coherence test: each mutant is a copy of the
# design with one deliberate coherence bug. The test must fail on every one.
# Usage: scripts/coh_mutants.sh [ops per port, default 300]
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OPS=${1:-300}
OUT=$ROOT/build/mutants; rm -rf "$OUT"; mkdir -p "$OUT"
L1=$ROOT/rtl/cache/l1_dcache.v
L2=$ROOT/rtl/cache/l2_cache.v
OTHER="$ROOT/rtl/core/*.v $ROOT/rtl/cache/l1_icache.v $ROOT/rtl/coherence/bus_arbiter.v \
       $ROOT/rtl/coherence/coherence_bus.v $ROOT/rtl/coherence/snoop_controller.v \
       $ROOT/rtl/memory/*.v $ROOT/rtl/io/*.v $ROOT/rtl/top/quad_core_top.v"

caught=0; total=0
# mutant <name> <file: l1|l2> <sed expression> <description>
mutant() {
  total=$((total + 1))
  cp "$L1" "$OUT/l1.v"; cp "$L2" "$OUT/l2.v"
  sed -i "$3" "$OUT/$2.v"
  if cmp -s "$OUT/$2.v" "$( [ "$2" = l1 ] && echo "$L1" || echo "$L2" )"; then
    echo "mutant $1: NOT APPLIED ($4)"; return
  fi
  iverilog -g2012 -DSIM -DNO_UART_ECHO -I "$ROOT/rtl/core" -I "$ROOT/rtl/cache" -I "$ROOT/verif" \
    -o "$OUT/$1.vvp" $OTHER "$OUT/l1.v" "$OUT/l2.v" "$ROOT/verif/coherence/tb_coh_random.v" 2> /dev/null
  vvp -n "$OUT/$1.vvp" +ops="$OPS" > "$OUT/$1.log" 2>&1
  first=$(grep -m1 '^ERROR' "$OUT/$1.log" | cut -c1-110)
  if grep -q 'RESULT PASS' "$OUT/$1.log"; then
    echo "mutant $1: MISSED | $4"
  else
    caught=$((caught + 1)); echo "mutant $1: CAUGHT | $4 | $first"
  fi
}

mutant upgr_no_inval l1 's/`BUS_READX, `BUS_UPGR, `BUS_INVAL: begin s_st_we/`BUS_READX, `BUS_INVAL: begin s_st_we/' \
  "a BusUpgr snoop does not invalidate other copies"
mutant rd_no_downgrade l1 's/`BUS_READ:                       begin s_st_we = 1.b1; s_st_val = S; end/`BUS_READ: begin s_st_we = 1'"'"'b0; s_st_val = S; end/' \
  "a BusRd snoop leaves the owner in M or E"
mutant l1_drop_dirty l1 's/wire vic_dirty = ((vic_way ? st1 : st0) == M);/wire vic_dirty = 1'"'"'b0;/' \
  "L1 evicts a modified line without writing it back"
mutant l2_drop_dirty l2 's/wire       vic_dirty = vld\[vic_way\] \&\& drt\[vic_way\];/wire       vic_dirty = 1'"'"'b0;/' \
  "L2 evicts a dirty line without writing it to memory"
mutant sc_no_resv l1 's/wire sc_fail      = is_sc \&\& !resv_ok;/wire sc_fail = 1'"'"'b0;/' \
  "SC succeeds without a reservation"
mutant resv_survives l1 's/resv_valid <= 1.b0;                         \/\/ line taken by another core/;/' \
  "the LR reservation survives a snoop invalidation"

echo "mutants caught: $caught of $total"
[ "$caught" -eq "$total" ]
