# Project plan and design review

The working plan lives in five living documents, kept outside the repo so
they can be commented on:

| Document | What it covers |
|---|---|
| [Design review and roadmap](https://claude.ai/artifact/7aUjMNPskuKsYJMgnQdEBK) | The 18 bugs found in the imported RTL, doc inconsistencies, repo hygiene, and the roadmap with a checklist and status per phase |
| [Verification and benchmarking strategy](https://claude.ai/artifact/D7Gc5MmsVvPDjYL7GPkim3) | Verification layers, coherence and memory-model checks, coverage, regression tiers, benchmarks and baselines |
| [Project debrief](https://claude.ai/artifact/SsBZ9FbDEvC3xLPtwwLTE6) | Plain-language account of what was done and why, including the NoC build |
| [Project review and improvements](https://claude.ai/artifact/9RL4WgFkAAA9UCwzcYdMDY) | Proposal vs project, inconsistencies, weak spots, and the ranked improvement list with its progress |
| [Final report (draft)](https://claude.ai/artifact/W2zurcH7FCR2DCVAGzrzAS) | First draft of the project report, written from the repository |

In the repo: [../scope.md](../scope.md) (scope, changes from the proposal,
reused vs original code) and [../bugs.md](../bugs.md) (every bug found).

## Scope (21 Nov 2026)

The project is evaluated in simulation. **FPGA work is on hold** and not part
of the evaluated scope: the FPGA files stay in the repo, but no FPGA result is
claimed. The evaluated design is the 4-core SoC with two interconnects that
share the same cores, L1s, L2 and memory: the snooping bus (baseline) and the
2x2 mesh NoC with a directory (the interconnect contribution).

## Roadmap

| Phase | Goal | Exit gate | State |
|---|---|---|---|
| P0 | Build, CI, repo hygiene | Clean Yosys synth, all testbenches green in CI | Done |
| P1 | Core correctness fixes (JAL, AUIPC, LSQ, flush) | `review/tb_repro.v` passes, riscv-tests pass | Done |
| P2 | System bring-up: memory map, I/O, program loading | C programs run on the 4-core SoC in simulation | Done in simulation; the FPGA half is on hold |
| P3 | Multicore software support (mhartid, atomics, FENCE, FENCE.I) | Litmus tests and parallel kernels pass on 4 cores | Done |
| P4 | Core and memory performance on the bus | Baselines measured, speed-ups reported | Done (fetch, prediction, multiply/divide) |
| P5 | 2x2 mesh NoC + directory MESI (duplicate L1 tags, no inclusive L2) | The same coherence suite passes; the bus stays the reference | Done |
| P6 | Bus vs NoC evaluation | Latency, throughput and benchmark results, bus vs NoC | Done for 4 cores, plus speed-up on 1/2/4 cores and a 4/9/16-core model |
| P7 | ASIC flow | Synthesis, place and route, sign-off reports | Not started (later stretch work) |

## Two performance stages

Performance is measured twice on purpose. **P4** proves the core and cache
upgrades on the snooping bus. **P6** compares the bus against the NoC and
directory using the same benchmarks, counters and build switches, so the
difference comes from the interconnect alone.

## Reproducing the known bugs

See [`review/README.md`](../../review/README.md).
