# Quad-core RISC-V OoO with MESI cache coherence

A four-core RV32I out-of-order processor (rename, 8-entry issue queue,
16-entry ROB, load/store queue) with private L1 caches, a shared L2, and
MESI coherence over a snooping bus. A 2x2 mesh NoC with directory coherence
is planned. Targets: FPGA (Artix-7 XC7A100T) first, then an ASIC flow.

## Quick start (Linux)

```
sudo apt-get install iverilog yosys
make sim          # all RTL testbenches, fails on any failed check
make sim-repro    # known-bug reproduction testbench (see review/)
make synth        # Yosys synthesis check of quad_core_top
make help         # all targets
```

Build outputs (logs, VCD waveforms) go to `build/`. On Windows, pass tool
paths, e.g. `make IVERILOG=C:/iverilog/bin/iverilog.exe VVP=C:/iverilog/bin/vvp.exe sim`.

## Layout

| Path | Contents |
|---|---|
| `rtl/core` | Out-of-order core |
| `rtl/cache` | L1I, L1D, L2 |
| `rtl/coherence` | Bus arbiter, coherence bus, snoop controller |
| `rtl/memory` | Main memory and controller |
| `rtl/top` | `quad_core_top`, `fpga_top` |
| `tb` | Testbenches and test programs |
| `review` | Bug reproduction testbench from the design review |
| `docs` | Reports, diagrams, and `docs/plan/` (roadmap and strategy) |
| `synth` | FPGA constraints |

## Plan

See [docs/plan/README.md](docs/plan/README.md) for the 8-phase roadmap,
design review, and verification and benchmarking strategy.
