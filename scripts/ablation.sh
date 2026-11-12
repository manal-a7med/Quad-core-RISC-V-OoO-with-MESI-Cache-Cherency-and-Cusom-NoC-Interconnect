#!/bin/sh
# What each part of the design buys: build the SoC with one feature switched
# off at a time (CFG_* macros in the RTL) and run the benchmarks on each.
# Results: build/ablation/<config>.txt (same format as build/bench/results.txt)
# and a summary table on stdout.
# Usage: scripts/ablation.sh <riscv-tests checkout> [bench ...]
#   full      the design as it is
#   no_bp     no branch prediction (every taken branch is repaired at commit)
#   inorder   instructions issue strictly in program order
#   simple    both: in-order issue and no prediction
#   msi       MSI instead of MESI (no Exclusive state)
set -e
RVT=${1:?path to riscv-tests checkout}; shift
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/ablation; mkdir -p "$OUT"
cfg_defs() {
  case $1 in
    full)    echo "" ;;
    no_bp)   echo "-DCFG_NO_BP" ;;
    inorder) echo "-DCFG_INORDER" ;;
    simple)  echo "-DCFG_NO_BP -DCFG_INORDER" ;;
    msi)     echo "-DCFG_MSI" ;;
  esac
}
for cfg in ${CONFIGS:-full no_bp inorder simple msi}; do
  make -C "$ROOT" -s "build/vl_$cfg/Vtb_soc" VL_CFG="$cfg" VL_DEFS="$(cfg_defs $cfg)"
  SIM=$ROOT/build/vl_$cfg/Vtb_soc OUT=$OUT/$cfg sh "$ROOT/scripts/bench.sh" "$RVT" "$@" > /dev/null
  cp "$OUT/$cfg/results.txt" "$OUT/$cfg.txt"
  echo "== $cfg"; cat "$OUT/$cfg.txt"
done
