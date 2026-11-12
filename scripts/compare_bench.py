#!/usr/bin/env python3
"""Compare a benchmark run with a reference file (both in make bench format).
Usage: compare_bench.py <reference.txt> <new results.txt>
Prints the timed-region cycles side by side. Exits 1 if a benchmark failed
or is missing. Cycle counts match exactly only with the same compiler
(GCC 13.2.0, as on Ubuntu 24.04); another compiler gives other programs."""
import re, sys

def load(path):
    out = {}
    for line in open(path):
        if line.startswith("#") or not line.strip():
            continue
        f = line.split()
        kv = dict(re.findall(r"(\w+)=(\S+)", line))
        out[f[0]] = (f[1], int(kv.get("region", 0)))
    return out

ref, new = load(sys.argv[1]), load(sys.argv[2])
bad = 0
print(f"{'benchmark':12} {'reference':>10} {'this run':>10}  ")
for b, (res, cyc) in ref.items():
    if b not in new:
        print(f"{b:12} {cyc:>10} {'missing':>10}"); bad += 1; continue
    nres, ncyc = new[b]
    note = "same" if ncyc == cyc else f"{ncyc / cyc:.3f}x"
    if nres != "PASS":
        note = "FAILED"; bad += 1
    print(f"{b:12} {cyc:>10} {ncyc:>10}  {note}")
sys.exit(1 if bad else 0)
