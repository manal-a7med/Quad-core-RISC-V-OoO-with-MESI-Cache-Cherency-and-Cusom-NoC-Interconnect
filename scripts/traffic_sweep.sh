#!/bin/sh
# P6: latency and throughput of the memory system under synthetic load
# (verif/traffic/tb_traffic.v), for the bus and the NoC builds.
# Output: build/traffic/traffic.txt (table) and traffic.csv.
# Env: CONFIGS (default "bus noc1 noc4 noc4_f256"), GAPS, PATTERNS, OPS,
#      JOBS (builds run at the same time, default 3)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/traffic; mkdir -p "$OUT"
CONFIGS=${CONFIGS:-"bus noc1 noc4 noc4_f256"}
GAPS=${GAPS:-"64 32 16 8 4 2 0"}
PATTERNS=${PATTERNS:-"0 1 2"}
OPS=${OPS:-500}
JOBS=${JOBS:-3}
SRC="$ROOT/rtl/core/*.v $ROOT/rtl/cache/l1_icache.v $ROOT/rtl/cache/l1_dcache.v $ROOT/rtl/cache/l2_cache.v \
     $ROOT/rtl/coherence/bus_arbiter.v $ROOT/rtl/coherence/coherence_bus.v $ROOT/rtl/coherence/snoop_controller.v \
     $ROOT/rtl/coherence/bus_interconnect.v $ROOT/rtl/memory/*.v $ROOT/rtl/io/*.v $ROOT/rtl/top/quad_core_top.v"
run_build() {
  c=$1
  case $c in
    bus)       D="" ;;
    noc1)      D="-DNOC -DNOC_BANKS=1" ;;
    noc4)      D="-DNOC -DNOC_BANKS=4" ;;
    noc1_f256) D="-DNOC -DNOC_BANKS=1 -DNOC_FLIT_W=256" ;;
    noc4_f256) D="-DNOC -DNOC_BANKS=4 -DNOC_FLIT_W=256" ;;
    *) echo "unknown build $c"; return 1 ;;
  esac
  N=""; [ -n "$D" ] && N="$ROOT/rtl/noc/*.v -I $ROOT/rtl/noc"
  iverilog -g2012 -DSIM -DNO_UART_ECHO $D -I "$ROOT/rtl/core" -I "$ROOT/rtl/cache" -I "$ROOT/verif" \
    -o "$OUT/$c.vvp" $SRC $N "$ROOT/verif/traffic/tb_traffic.v" || return 1
  : > "$OUT/$c.csv"
  for p in $PATTERNS; do for g in $GAPS; do
    l=$(vvp -n "$OUT/$c.vvp" +pattern=$p +gap=$g +ops=$OPS | grep '^TRAFFIC') || { echo "$c pattern $p gap $g: no result"; return 1; }
    echo "$c $l"
    echo "$l" | sed -E "s/.*pattern=([0-9]+) gap=([0-9]+).* cycles=([0-9]+) throughput=([0-9.]+) latency=([0-9.]+) l1req=([0-9]+) l1lat=([0-9.]+)/$c,\1,\2,\3,\4,\5,\6,\7/" >> "$OUT/$c.csv"
  done; done
}

# Builds run in parallel, JOBS at a time
i=0; pids=""; fail=0
for c in $CONFIGS; do
  run_build "$c" > "$OUT/$c.log" 2>&1 &
  pids="$pids $!"; i=$((i + 1))
  if [ $i -ge "$JOBS" ]; then for p in $pids; do wait $p || fail=1; done; pids=""; i=0; fi
done
for p in $pids; do wait $p || fail=1; done
for c in $CONFIGS; do cat "$OUT/$c.log"; done
[ $fail -eq 0 ] || { echo "traffic sweep failed"; exit 1; }
echo "build,pattern,gap,cycles,throughput,latency,l1req,l1lat" > "$OUT/traffic.csv"
for c in $CONFIGS; do cat "$OUT/$c.csv" >> "$OUT/traffic.csv"; done
python3 - "$OUT" <<'PY'
import csv, sys
out = sys.argv[1]
rows = list(csv.DictReader(open(f"{out}/traffic.csv")))
builds = list(dict.fromkeys(r["build"] for r in rows))
names = {"0": "private lines", "1": "shared lines", "2": "hotspot (one set)"}
txt = ["Synthetic traffic: accesses per 1000 cycles (all 4 ports) / average access latency in cycles.",
       "gap = mean idle cycles between a port's accesses (smaller = more load).", ""]
for p in dict.fromkeys(r["pattern"] for r in rows):
    txt.append(f"pattern {p}: {names.get(p, p)}")
    txt.append("gap".rjust(5) + "".join(b.rjust(16) for b in builds))
    for g in dict.fromkeys(r["gap"] for r in rows if r["pattern"] == p):
        line = g.rjust(5)
        for b in builds:
            r = [x for x in rows if x["build"] == b and x["pattern"] == p and x["gap"] == g]
            line += (f"{r[0]['throughput']} / {r[0]['latency']}" if r else "-").rjust(16)
        txt.append(line)
    txt.append("")
open(f"{out}/traffic.txt", "w").write("\n".join(txt))
print("\n".join(txt))
PY
