#!/bin/sh
# Parallel speed-up: the multi-thread riscv-tests benchmarks on 1, 2 and 4
# cores, on the bus and on NoC builds. The program is the same in every run;
# NCORES only sets how many harts share the work (the others park and make
# no memory traffic). The 1-core run is the no-contention baseline: speed-up
# = cycles(1 core) / cycles(n cores), efficiency = speed-up / n.
# Usage: scripts/scaling.sh [riscv-tests checkout] [output file]
#   CONFIGS="bus noc4_f256" (default: bus noc1 noc4_f256)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RVT=${1:-$ROOT/third_party/riscv-tests}
OUTF=${2:-$ROOT/build/scaling.txt}
CONFIGS=${CONFIGS:-"bus noc1 noc4_f256"}
BENCHES=${BENCHES:-"mt-vvadd mt-matmul mt-memcpy"}
cd "$ROOT" || exit 1
for c in $CONFIGS; do
  case $c in
    bus)       args="";                                d=build ;;
    noc1)      args="NOC=1";                           d=build/noc1 ;;
    noc4)      args="NOC=1 NOC_BANKS=4";               d=build/noc4 ;;
    noc1_f256) args="NOC=1 NOC_FLIT=256";              d=build/noc1_f256 ;;
    noc4_f256) args="NOC=1 NOC_BANKS=4 NOC_FLIT=256";  d=build/noc4_f256 ;;
    *) echo "unknown build $c"; exit 1 ;;
  esac
  v=vl_$c; [ "$c" = bus ] && v=vl_soc
  make -s "$d/$v/Vtb_soc" $args > "$d.scaling_build.log" 2>&1 || { tail -5 "$d.scaling_build.log"; exit 1; }
  for n in 1 2 4; do
    echo "== $c, $n core(s)"
    OUT="$ROOT/$d/scaling_$n" NCORES=$n SIM="$ROOT/$d/$v/Vtb_soc" sh scripts/bench.sh "$RVT" $BENCHES \
      > "$d.scaling_$n.log" 2>&1 || { tail -5 "$d.scaling_$n.log"; exit 1; }
    cp "$d/scaling_$n/results.txt" "build/scaling_${c}_$n.txt"
  done
done
python3 - "$OUTF" $CONFIGS <<'PY'
import sys, re
out, cfgs = sys.argv[1], sys.argv[2:]
res, names = {}, []
for c in cfgs:
    for n in (1, 2, 4):
        for line in open(f"build/scaling_{c}_{n}.txt"):
            m = re.match(r"(\S+) (\S+) cycles=(\d+) region=(\d+)", line)
            if m:
                if m.group(1) not in names:
                    names.append(m.group(1))
                res[(m.group(1), c, n)] = (m.group(2), int(m.group(4)))
lines = ["Parallel speed-up of the multi-thread benchmarks (make scaling).",
         "Timed-region cycles on 1, 2 and 4 cores; in brackets: speed-up over 1 core",
         "of the same build, and efficiency (speed-up / cores).", ""]
ok = True
for c in cfgs:
    lines.append(f"{c}:")
    lines.append("  " + "benchmark".ljust(11) + "1 core".rjust(10) + "2 cores".rjust(24) + "4 cores".rjust(24))
    for b in names:
        row = "  " + b.ljust(11)
        base = res.get((b, c, 1), ("MISSING", 0))[1]
        for n in (1, 2, 4):
            st, cyc = res.get((b, c, n), ("MISSING", 0))
            ok &= st == "PASS"
            if st != "PASS":
                cell = st
            elif n == 1:
                cell = str(cyc)
            else:
                cell = f"{cyc} ({base / cyc:.2f}x, {base / cyc / n * 100:.0f}%)"
            row += cell.rjust(10 if n == 1 else 24)
        lines.append(row)
    lines.append("")
if "bus" in cfgs:
    lines.append("4-core run relative to the bus (above 1.00 = faster than the bus):")
    for c in cfgs:
        if c == "bus":
            continue
        cells = []
        for b in names:
            bus, other = res.get((b, "bus", 4)), res.get((b, c, 4))
            if bus and other and bus[0] == other[0] == "PASS":
                cells.append(f"{b} {bus[1] / other[1]:.2f}")
        lines.append(f"  {c}: " + ", ".join(cells))
open(out, "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
sys.exit(0 if ok else 1)
PY
