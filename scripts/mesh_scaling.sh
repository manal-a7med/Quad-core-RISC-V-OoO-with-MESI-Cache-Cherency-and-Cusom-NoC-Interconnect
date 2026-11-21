#!/bin/sh
# mesh_scaling.sh - bus vs mesh as the core count grows (4, 9, 16 cores).
#
# Runs the calibrated model verif/scaling/tb_mesh_scaling.v (see its header
# for what it models and how it was calibrated against the RTL). For each
# size, pattern and load it prints misses per 1000 cycles and the average
# miss latency, for the bus and for the mesh.
#
# Usage: sh scripts/mesh_scaling.sh [build_dir]     (make mesh-scaling)
#   SIZES   mesh sizes K (K x K cores), default "2 3 4"
#   GAPS    mean idle cycles between misses, default "64 16 4 0"
#   OPS     misses per core, default 400
set -e
B=${1:-build/mesh_scaling}
SIZES=${SIZES:-"2 3 4"}
GAPS=${GAPS:-"64 16 4 0"}
OPS=${OPS:-400}
D=verif/scaling
mkdir -p "$B"
for k in $SIZES; do
    iverilog -g2012 -DSIM -Ptb_mesh_scaling.K=$k -o "$B/ms$k.vvp" \
        $D/mesh_router.v $D/mesh_k.v $D/tb_mesh_scaling.v
done
run() { vvp -n "$B/ms$1.vvp" +bus=$2 +pattern=$3 +gap=$4 +ops=$OPS | grep '^SCALING' || echo "SCALING FAILED k=$1 bus=$2 pattern=$3 gap=$4"; }
for k in $SIZES; do
    for p in 0 1 2; do
        for g in $GAPS; do
            run $k 1 $p $g > "$B/r_${k}_bus_${p}_${g}.txt" &
            run $k 0 $p $g > "$B/r_${k}_mesh_${p}_${g}.txt" &
            wait
        done
    done
done
if grep -q FAILED "$B"/r_*.txt; then grep -h FAILED "$B"/r_*.txt; exit 1; fi
num() { sed -n 's/.*: \([0-9.]*\) misses\/kcycle, latency \([0-9.]*\) cycles/\1 \2/p' "$1"; }
echo "Bus vs mesh as the core count grows (model, verif/scaling/tb_mesh_scaling.v, $OPS misses per core)."
echo "Each cell: misses per 1000 cycles (all cores) / average miss latency in cycles. gap = mean idle"
echo "cycles between a core's misses (smaller = more load). mesh/bus = mesh throughput over bus throughput."
for p in 0 1 2; do
    case $p in 0) name="private lines";; 1) name="shared lines (half the misses forwarded by an owner)";; 2) name="hotspot (every miss to one home)";; esac
    echo
    echo "pattern $p: $name"
    printf "  %5s %5s %18s %18s %9s\n" cores gap bus mesh mesh/bus
    for k in $SIZES; do
        for g in $GAPS; do
            set -- $(num "$B/r_${k}_bus_${p}_${g}.txt") $(num "$B/r_${k}_mesh_${p}_${g}.txt")
            printf "  %5d %5d %11s / %4s %11s / %4s %9s\n" $((k*k)) $g $1 $2 $3 $4 \
                "$(awk -v a=$3 -v b=$1 'BEGIN{printf "%.2f", a/b}')"
        done
    done
done
