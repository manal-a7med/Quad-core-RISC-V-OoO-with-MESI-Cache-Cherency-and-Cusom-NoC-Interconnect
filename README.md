# Quad-core RISC-V OoO with MESI cache coherence

A four-core RV32IA (+ Zicsr, machine mode) out-of-order processor (rename,
8-entry issue queue, 16-entry ROB, load/store queue) with private L1 caches,
a shared L2, and MESI coherence over a snooping bus, plus a small I/O block
(UART, LEDs, 7-segment display). A 2x2 mesh NoC with directory coherence
is planned. Targets: FPGA (Artix-7 XC7A100T) first, then an ASIC flow.

## Quick start (Linux)

```
sudo apt-get install iverilog yosys
make sim          # all RTL testbenches, fails on any failed check
make sim-repro    # known-bug reproduction testbench (see review/)
make synth        # Yosys synthesis check of one core
make help         # all targets
```

With a RISC-V GCC (`sudo apt-get install gcc-riscv64-unknown-elf`) and a
[riscv-tests](https://github.com/riscv-software-src/riscv-tests) checkout:

```
make isa RISCV_TESTS=../riscv-tests   # rv32ui + rv32ua + system tests on one core
make soc-isa                          # the same programs on the 4-core SoC
make soc-run PROG=hello               # C demo on the SoC: "hello from hart N"
make soc-run PROG=parsum              # 4-hart parallel array sum
make soc-run PROG=atomics             # shared counter: plain vs amoadd vs LR/SC lock
make soc-run PROG=prodcons            # producer/consumer ring buffer (fences + CAS)
make soc-run PROG=litmus              # memory-model litmus tests (MP, SB, CoRR, LB, IRIW)
make fpga-sim PROG=hello              # board-level simulation of fpga_top
```

`make coh-random` (no RISC-V GCC needed) drives random loads, stores and
atomics into the four L1 data caches of the real memory system and checks
every result for coherence (3 seeds by default; `SEEDS="1 2" OPS=5000`).

## FPGA (Digilent Nexys A7-100T)

```
make sw                         # builds build/sw/<prog>.line.hex
make fpga PROG=hello            # Vivado: bitstream with the program in memory
make program                    # load it over USB
```

The core clock is 50 MHz (`CLKOUT_DIV=20`; use `CLKOUT_DIV=25` for 40 MHz if
timing fails). Open a terminal on the board's USB serial port at 115200 8N1
to see the UART output. LEDs show the program's `LEDS` register and the
7-segment display shows its `HEX` register; the rightmost decimal point
lights when the program has finished. CPU_RESET restarts the program (start-up
code clears `.bss`; initialised data is not reloaded).
The I/O registers are listed in `rtl/io/soc_io.v` and `sw/common/soc.h`.

Build outputs (logs, VCD waveforms) go to `build/`. On Windows, pass tool
paths, e.g. `make IVERILOG=C:/iverilog/bin/iverilog.exe VVP=C:/iverilog/bin/vvp.exe sim`.

## Layout

| Path | Contents |
|---|---|
| `rtl/core` | Out-of-order core |
| `rtl/cache` | L1I, L1D, L2 |
| `rtl/coherence` | Bus arbiter, coherence bus, snoop controller |
| `rtl/memory` | Main memory and controller |
| `rtl/io` | UART, memory-mapped I/O, 7-segment driver |
| `rtl/top` | `quad_core_top`, `fpga_top` |
| `sw` | Bare-metal C demos and start-up code |
| `tb` | Testbenches and test programs |
| `verif` | riscv-tests harness, system tests, SoC and board-level testbenches, random coherence test |
| `review` | Bug reproduction testbench from the design review |
| `docs` | Reports, diagrams, and `docs/plan/` (roadmap and strategy) |
| `synth` | Nexys A7 constraints, Vivado build and program scripts |

## Plan

See [docs/plan/README.md](docs/plan/README.md) for the 8-phase roadmap,
design review, and verification and benchmarking strategy.
