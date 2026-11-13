#!/bin/sh
# Mutation check of the random coherence test: each mutant is a copy of the
# design with one deliberate coherence bug. The test must fail on every one.
# Usage: scripts/coh_mutants.sh [ops per port, default 300]
# NOC=1 [NOC_BANKS=4] [NOC_FLIT=128] in the environment: the NoC + directory build, with two
# more mutants in the directory home.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OPS=${1:-300}
L1=$ROOT/rtl/cache/l1_dcache.v
L2=$ROOT/rtl/cache/l2_cache.v
DH=$ROOT/rtl/noc/dir_home.v
OTHER="$ROOT/rtl/core/*.v $ROOT/rtl/cache/l1_icache.v $ROOT/rtl/coherence/bus_arbiter.v \
       $ROOT/rtl/coherence/coherence_bus.v $ROOT/rtl/coherence/snoop_controller.v $ROOT/rtl/coherence/bus_interconnect.v \
       $ROOT/rtl/memory/*.v $ROOT/rtl/io/*.v $ROOT/rtl/top/quad_core_top.v"
DEFS=""
OUT=$ROOT/build/mutants
if [ -n "$NOC" ]; then
  B=${NOC_BANKS:-1}; T=noc$B; FD=""
  [ -n "$NOC_FLIT" ] && { T=${T}_f$NOC_FLIT; FD="-DNOC_FLIT_W=$NOC_FLIT"; }
  OTHER="$OTHER $(ls "$ROOT"/rtl/noc/*.v | grep -v dir_home.v)"
  DEFS="-DNOC -DNOC_BANKS=$B $FD -I $ROOT/rtl/noc"; OUT=$ROOT/build/$T/mutants
fi
rm -rf "$OUT"; mkdir -p "$OUT"

caught=0; total=0
# mutant <name> <file: l1|l2|dh> <sed expression> <description>
mutant() {
  total=$((total + 1))
  cp "$L1" "$OUT/l1.v"; cp "$L2" "$OUT/l2.v"; cp "$DH" "$OUT/dh.v"
  sed -i "$3" "$OUT/$2.v"
  case $2 in l1) ORIG=$L1;; l2) ORIG=$L2;; *) ORIG=$DH;; esac
  if cmp -s "$OUT/$2.v" "$ORIG"; then
    echo "mutant $1: NOT APPLIED ($4)"; return
  fi
  HOME_SRC=""; [ -n "$NOC" ] && HOME_SRC="$OUT/dh.v"
  iverilog -g2012 -DSIM -DNO_UART_ECHO $DEFS -I "$ROOT/rtl/core" -I "$ROOT/rtl/cache" -I "$ROOT/verif" \
    -o "$OUT/$1.vvp" $OTHER "$OUT/l1.v" "$OUT/l2.v" $HOME_SRC "$ROOT/verif/coherence/tb_coh_random.v" 2> /dev/null
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

if [ -n "$NOC" ]; then
mutant dir_getm_keeps_sharers dh 's/(is_getm || is_upg) ? others : 4.b0000;/(is_getm || is_upg) ? (others \& owner) : 4'"'"'b0000;/' \
  "directory: a GetM / Upgrade probes only the owner, other sharers keep stale copies"
mutant dir_e_with_sharers dh 's/wire shared = |kept || |(others \& ~probed);/wire shared = |kept;/' \
  "directory: a GetS is granted E although other caches still share the line"
fi

echo "mutants caught: $caught of $total"
[ "$caught" -eq "$total" ]
