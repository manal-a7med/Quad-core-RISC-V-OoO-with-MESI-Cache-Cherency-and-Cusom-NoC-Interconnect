#!/bin/sh
# Build the riscv-tests benchmarks for this SoC and run them on the Verilator
# model of the 4-core SoC. Results: build/bench/results.txt, one line each:
#   <bench> <PASS|FAIL> cycles=<total> region=<timed cycles> instret=<timed instret>
#       branches=<n> mispredicts=<n> (hart 0, whole run) busupgr=<n> bustx=<all bus transactions>
# Usage: scripts/bench.sh <riscv-tests checkout> [bench ...]
#   NCORES=n   cores used by the multi-thread benchmarks (default 4)
#   MARCH=...  -march for the programs (default rv32ima_zicsr)
#   SIM=...    simulator binary (default build/vl_soc/Vtb_soc);  OUT=... output directory
set -e
RVT=$(cd "${1:?path to riscv-tests checkout}" && pwd); shift
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/build/bench}; mkdir -p "$OUT"
NCORES=${NCORES:-4}
MARCH=${MARCH:-rv32ima_zicsr}
SIM=${SIM:-$ROOT/build/vl_soc/Vtb_soc}
CC=riscv64-unknown-elf-gcc
# (spmv also works but is double-precision soft float: 15 M cycles)
BENCHES=${*:-"dhrystone median multiply qsort rsort towers vvadd memcpy mt-vvadd mt-matmul"}
[ -x "$SIM" ] || make -C "$ROOT" -s "${SIM#$ROOT/}"

: > "$OUT/results.txt"
for b in $BENCHES; do
  src=$RVT/benchmarks/$b
  [ -d "$src" ] || { echo "$b: not found in $RVT/benchmarks"; continue; }
  # The benchmark's main() becomes bench_main(); crt0 and the shim keep theirs
  CFLAGS="-march=$MARCH -mabi=ilp32 -O2 -fno-common -fno-builtin-printf -ffreestanding -Wno-implicit-function-declaration \
          -DNCORES=$NCORES -DPREALLOCATE=1 -I$src -I$ROOT/sw/bench/include -I$RVT/benchmarks/common -I$ROOT/sw/common"
  rm -rf "$OUT/$b.o"; mkdir -p "$OUT/$b.o"
  if ! { for c in "$src"/*.c; do $CC $CFLAGS -Dmain=bench_main -c "$c" -o "$OUT/$b.o/$(basename "$c" .c).o" || exit 1; done &&
         $CC $CFLAGS -nostdlib -nostartfiles -static -Wl,--no-warn-rwx-segments -T "$ROOT/sw/common/link.ld" \
             "$ROOT/sw/common/crt0.S" "$ROOT/sw/bench/shim.c" "$OUT/$b.o"/*.o -lgcc -o "$OUT/$b.elf"; } > "$OUT/$b.build.log" 2>&1; then
    echo "$b BUILD-FAIL (see $OUT/$b.build.log)" | tee -a "$OUT/results.txt"; continue
  fi
  riscv64-unknown-elf-objcopy -O binary "$OUT/$b.elf" "$OUT/$b.bin"
  od -An -v -tx4 -w4 "$OUT/$b.bin" | tr -d ' ' > "$OUT/$b.hex"
  "$SIM" +hex="$OUT/$b.hex" +timeout=${TIMEOUT:-20000000} +perf > "$OUT/$b.log" 2>&1 || true
  res=$(grep -o 'RESULT [A-Z]*' "$OUT/$b.log" | head -1 | cut -d' ' -f2 || true)
  tot=$(grep -o 'RESULT PASS cycles=[0-9]*' "$OUT/$b.log" | grep -o '[0-9]*$' || true)
  reg=$(grep -o 'BENCH cycles=[0-9]* instret=[0-9]*' "$OUT/$b.log" | head -1 || true)
  if [ -z "$reg" ]; then    # multi-thread: sum of the "<code>: N cycles" lines
    reg=$(grep -o ': [0-9]* cycles' "$OUT/$b.log" | grep -o '[0-9]*' | awk '{s+=$1} END {if (NR) print "BENCH cycles=" s " instret=-"}')
  fi
  br=$(grep -o 'branches=[0-9]* mispredicts=[0-9]*' "$OUT/$b.log" | head -1 || true)
  bus=$(awk '/^PERF bus/ { for (i = 3; i <= NF; i++) { split($i, a, "="); n[a[1]] = a[2] }
                           print "busupgr=" n["busupgr"] " bustx=" n["busrd"] + n["busrdx"] + n["busupgr"] + n["flush"] }' "$OUT/$b.log")
  echo "$b ${res:-NONE} cycles=${tot:--} ${reg#BENCH } $br $bus" | sed 's/ cycles=\([0-9-]*\) cycles=/ cycles=\1 region=/' | tee -a "$OUT/results.txt"
done
