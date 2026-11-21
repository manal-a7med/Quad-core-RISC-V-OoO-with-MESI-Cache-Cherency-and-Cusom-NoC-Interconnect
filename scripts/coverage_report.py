#!/usr/bin/env python3
"""Merge the functional coverage of several coh-random runs into one report.

Each run of verif/coherence/tb_coh_random.v prints one line per coverage bin:
    COV <bin> <count> <name>
This script adds up the counts of all runs of each build and prints, per bin,
the count in every build, then how many bins each build hit.

Usage: coverage_report.py <name>=<log glob> [<name>=<log glob> ...]
e.g.   coverage_report.py bus='build/coh_random_*.log' noc1='build/noc1/coh_random_*.log'
"""
import glob
import sys

builds = []             # (name, {bin: count}, runs)
names = {}              # bin -> name
for arg in sys.argv[1:]:
    label, pattern = arg.split("=", 1)
    counts, runs = {}, 0
    for path in sorted(glob.glob(pattern)):
        runs += 1
        for line in open(path):
            if line.startswith("COV "):
                _, b, n, name = line.rstrip("\n").split(" ", 3)
                counts[int(b)] = counts.get(int(b), 0) + int(n)
                names[int(b)] = name
    builds.append((label, counts, runs))

if not names:
    sys.exit("coverage_report: no COV lines found")

w = max(len(n) for n in names.values())
print("Functional coverage of the coherence protocol (make coverage)")
print("Counts summed over " + ", ".join(f"{l}: {r} runs" for l, _, r in builds)
      + ". '-' = the bin does not apply to that build.\n")
print(f"{'bin':>3}  {'event':<{w}}  " + "  ".join(f"{l:>8}" for l, _, _ in builds))
for b in sorted(names):
    cells = []
    for _, counts, _ in builds:
        cells.append(f"{counts[b]:>8}" if b in counts else f"{'-':>8}")
    print(f"{b:>3}  {names[b]:<{w}}  " + "  ".join(cells))
print()
bad_total = 0
for label, counts, _ in builds:
    legal = [b for b in counts if not names[b].startswith("ILLEGAL")]
    hit = [b for b in legal if counts[b] > 0]
    bad = sum(counts[b] for b in counts if names[b].startswith("ILLEGAL"))
    bad_total += bad
    missed = [names[b] for b in legal if counts[b] == 0]
    print(f"{label}: {len(hit)} of {len(legal)} bins hit ({100 * len(hit) // max(len(legal), 1)}%), "
          f"{bad} illegal events" + (f"; missed: {', '.join(missed)}" if missed else ""))
sys.exit(1 if bad_total else 0)
