#!/bin/sh
# P6: the same benchmarks on every interconnect build, one table.
# Builds: bus (default), NoC with 1 and 4 directory homes, each with 64-bit
# and 256-bit flits. The L1s, L2 and memory are the same in every build, so
# the differences come from the interconnect alone.
# Usage: scripts/compare_ic.sh [riscv-tests checkout] [output file]
# Output: one line per benchmark, timed-region cycles per build, and the
# speed relative to the bus (>1 = faster than the bus).
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RVT=${1:-$ROOT/third_party/riscv-tests}
OUTF=${2:-$ROOT/build/compare_ic.txt}
CONFIGS=${CONFIGS:-"bus noc1 noc4 noc1_f256 noc4_f256"}
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
  echo "== $c"
  make -s bench $args RISCV_TESTS="$RVT" > "$d.bench.log" 2>&1 || { tail -5 "$d.bench.log"; exit 1; }
  cp "$d/bench/results.txt" "build/compare_$c.txt"
done
python3 - "$OUTF" $CONFIGS <<'PY'
import sys, re
out, cfgs = sys.argv[1], sys.argv[2:]
res = {}
for c in cfgs:
    for line in open(f"build/compare_{c}.txt"):
        m = re.match(r"(\S+) (\S+) cycles=(\d+) region=(\d+)", line)
        if m:
            res.setdefault(m.group(1), {})[c] = (m.group(2), int(m.group(4)))
names = list(res)
w = 11
lines = ["Timed-region cycles per benchmark and build (lower is better);",
         "in brackets: speed relative to the bus (above 1.00 = faster than the bus).",
         "", "benchmark".ljust(w) + "".join(c.rjust(18) for c in cfgs)]
ok = True
for n in names:
    row = n.ljust(w)
    base = res[n].get("bus", (None, None))[1]
    for c in cfgs:
        st, cyc = res[n].get(c, ("MISSING", 0))
        ok &= st == "PASS"
        rel = f" ({base / cyc:.2f})" if base and cyc and c != "bus" else ""
        row += (f"{cyc}{rel}" if st == "PASS" else st).rjust(18)
    lines.append(row)
open(out, "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
sys.exit(0 if ok else 1)
PY
