# Demo charts

Charts for presenting the project, made from the committed result files in
`results/` (no simulation needed). To make them again:

```
make visuals        # or: python3 scripts/viz/make_visuals.py
```

It needs matplotlib (`sudo apt install python3-matplotlib`). The same charts,
with a short explanation on each slide, are in the deck
`results/visual/project_results.pptx`.

All results come from simulation of the RTL (Icarus Verilog and Verilator).
"Bus" is the snooping-bus system, "NoC" the 2x2 mesh with a directory. Both use
the same cores, L1 caches, L2 and memory, so the differences come from the
interconnect alone.

| Chart | What it shows | In one line |
|---|---|---|
| [01_architecture.png](01_architecture.png) | The two systems side by side | Same four cores and caches; one shares a bus, the other sends messages over a 2x2 mesh with a directory home per node. |
| [02_verification_scorecard.png](02_verification_scorecard.png) | Every correctness check | All official RISC-V tests, all 4-core programs, every coverage bin, every broken design caught, the bus arbiter formally proved. |
| [03_core_speedup_before_after.png](03_core_speedup_before_after.png) | Benchmarks before and after the core performance work | Every benchmark got 1.7x to 5.7x faster; Dhrystone 3.0x (CPI 3.94 to 1.36). |
| [04_ablation.png](04_ablation.png) | Each benchmark with one feature switched off | Branch prediction matters most (up to 2.3x slower without it); in-order issue costs up to 1.2x; MSI instead of MESI costs almost nothing here. |
| [05_bus_vs_noc_benchmarks.png](05_bus_vs_noc_benchmarks.png) | Real programs on the bus and on the NoC | At 4 cores the bus is as fast or faster, because a single miss is quicker on the bus; the NoC wins only on mt-matmul (5%). |
| [06_traffic_throughput_latency.png](06_traffic_throughput_latency.png) | Synthetic load from light to full | The bus tops out at about 172 accesses per 1000 cycles, the NoC reaches 260 (1.5x); at light load the bus answers in 9 cycles, the NoC in 14. With one hot line the bus wins. |
| [07_parallel_speedup.png](07_parallel_speedup.png) | 1, 2 and 4 cores on the parallel benchmarks | Four cores run 2.8x to 3.8x faster than one, on both systems. |
| [08_more_cores_model.png](08_more_cores_model.png) | Bus vs mesh at 4, 9 and 16 cores (calibrated model) | At full load the mesh carries 1.6x, 3.2x and 5.1x what the bus does; on one hot line only 1.2x. |
| [09_coverage_heatmap.png](09_coverage_heatmap.png) | How often each coherence event happened in the random test | Every event that can happen in a system happened (from 17 to over 29,000 times); the two illegal events never did. |

**The story in three sentences.** The four-core processor is correct: every
test, coverage bin and broken-design check passes on both interconnects. At
four cores the simple bus is still as fast or faster on real programs, because
each miss is answered sooner. The mesh pays off under heavy load and as the
core count grows: 1.5x the throughput at 4 cores and about 5x at 16 cores
(model), except when every core hits the same line.

Sources: `results/2026-11-11/` (ablation, before the performance work),
`results/2026-11-12/bench.txt`, `results/2026-11-13/` (bus vs NoC),
`results/2026-11-21/` (coverage, speed-up, mesh model). The 16-core and 9-core
numbers come from a model calibrated on the 4-core RTL
(`verif/scaling/tb_mesh_scaling.v`), not from a 16-core RTL build.
