# Project plan and design review

The working plan for carrying this design to FPGA and later ASIC lives in two
living documents (kept outside the repo so they can be commented on):

| Document | What it covers |
|---|---|
| [Design review and FPGA readiness plan](https://claude.ai/artifact/7aUjMNPskuKsYJMgnQdEBK) | 18 RTL bugs, 11 FPGA blockers, 18 doc inconsistencies, repo hygiene, and the 8-phase roadmap |
| [Verification and benchmarking strategy](https://claude.ai/artifact/D7Gc5MmsVvPDjYL7GPkim3) | Verification layers, per-block plan, coherence/memory-model checks, coverage and regression tiers, benchmark suite, baselines B0-B4 / N1-N2, measurement infrastructure |

## Roadmap (8 phases)

| Phase | Goal | Exit gate |
|---|---|---|
| P0 | Build, CI, repo hygiene | Clean Yosys synth + all TBs green in CI |
| P1 | Core correctness fixes (JAL, AUIPC, LSQ, flush) | `review/tb_repro.v` all pass, riscv-tests pass |
| P2 | FPGA bring-up (BRAM mapping, program load, clocks) | Fits XC7A100T, runs a program on the board; perf counters live |
| P3 | Multicore software support (mhartid, atomics, FENCE) | Litmus tests and a parallel kernel pass on 4 cores |
| P4 | Core and memory performance on the bus | Baselines B0-B4 measured; speed-ups reported |
| P5 | 2x2 mesh NoC + directory MESI at inclusive L2 | Same coherence suite passes; bus kept as golden reference |
| P6 | Bus vs NoC evaluation | N1/N2 vs B4 latency, throughput and scaling results |
| P7 | ASIC flow | Synthesis, P&R and sign-off reports |

## Two performance stages

Performance is measured twice on purpose. **P4** proves the core and cache
upgrades on the snooping bus (and creates enough concurrent memory traffic for
the interconnect to matter). **P6** compares the bus against the NoC +
directory design using the same benchmarks, counters and RTL switches, so the
interconnect result is an apples-to-apples comparison.

## Reproducing the known bugs

See [`review/README.md`](../../review/README.md).
