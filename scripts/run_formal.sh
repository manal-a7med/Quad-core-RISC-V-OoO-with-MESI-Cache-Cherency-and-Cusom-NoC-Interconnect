#!/bin/sh
# run_formal.sh - formal proof of the bus arbiter (make formal).
#
# The properties are in rtl/coherence/bus_arbiter.v under `ifdef FORMAL`:
# at most one grant, the grant matches current_owner, a grant goes only to a
# requester and in round-robin order, and no core waits for more than three
# grants to other cores. Yosys's built-in SAT solver proves them for every
# input sequence by temporal induction (no extra tools needed).
#
# Then the same proof is run on a copy of the arbiter with the round-robin
# order broken; it must fail, which shows the properties have teeth.
set -e
B=${1:-build/formal}
mkdir -p "$B"
prove() {   # prove <file> <log>; prints PROVED or FAILED
    if yosys -q -l "$2" -p "read_verilog -formal -DFORMAL -I rtl/cache -I rtl/core $1; \
        prep -top bus_arbiter; async2sync; \
        sat -tempinduct -prove-asserts -set-assumes -maxsteps 12 -verify" > /dev/null 2>&1 \
        && grep -q 'Induction step proven: SUCCESS' "$2"; then echo PROVED; else echo FAILED; fi
}
r=$(prove rtl/coherence/bus_arbiter.v "$B/arbiter.log")
echo "formal: bus_arbiter properties $r ($(grep -c 'Import proof for assert' "$B/arbiter.log") assertion checks, induction length $(grep 'Trying induction with length' "$B/arbiter.log" | tail -1 | sed 's/[^0-9]//g'))"
[ "$r" = PROVED ] || { tail -40 "$B/arbiter.log"; exit 1; }
# Mutant: core 2 is tried before core 1 after core 0 wins
sed 's/if      (req\[cand1\]) next_owner = cand1;/if (req[cand2]) next_owner = cand2; else if (req[cand1]) next_owner = cand1;/' \
    rtl/coherence/bus_arbiter.v > "$B/bus_arbiter_mutant.v"
cmp -s rtl/coherence/bus_arbiter.v "$B/bus_arbiter_mutant.v" && { echo "formal: mutant sed did not apply"; exit 1; }
m=$(prove "$B/bus_arbiter_mutant.v" "$B/mutant.log")
echo "formal: arbiter with broken round-robin order $m (must be FAILED)"
[ "$m" = FAILED ]
