# Quad-core RISC-V out-of-order processor with MESI cache coherence

[![CI](https://github.com/manal-a7med/Quad-core-RISC-V-OoO-with-MESI-Cache-Cherency-and-Cusom-NoC-Interconnect/actions/workflows/ci.yml/badge.svg)](https://github.com/manal-a7med/Quad-core-RISC-V-OoO-with-MESI-Cache-Cherency-and-Cusom-NoC-Interconnect/actions/workflows/ci.yml)

Four RISC-V cores that share memory, written in Verilog for the Digilent
Nexys A7-100T FPGA board. Each core executes instructions out of order, and a
snooping bus keeps the cores' private data caches coherent with the MESI
protocol. The cores run C programs compiled with the standard RISC-V GCC
toolchain.

Every result in this README can be reproduced with free tools on Linux, or on
Windows through WSL. The section [Reproduce every result](#reproduce-every-result)
gives the command for each claim and what it should print.

## At a glance

| | |
|---|---|
| ISA | RV32IMA + Zicsr + Zifencei, machine mode |
| Core | Single-issue out-of-order: 64 physical registers, 8-entry issue queue, 16-entry reorder buffer, 8-entry load/store queue, branch prediction (256 two-bit counters, 8-entry return address stack) |
| Caches | Per core: 4 KB L1 instruction cache, 4 KB 2-way L1 data cache. Shared: 16 KB 4-way L2 |
| Coherence | MESI over a snooping bus, round-robin arbitration, cache-to-cache transfer |
| Memory and I/O | 64 KB block RAM; UART, LEDs and 7-segment display at 0x8000_0000 |
| Target | Xilinx XC7A100T (Nexys A7-100T), 50 MHz |

## Results

All of these come from simulation, and each has a command below that
reproduces it.

| Check | Result |
|---|---|
| Official RISC-V tests on one core: rv32ui / rv32ua / rv32um | 41/41, 10/10, 8/8 |
| The same 61 test programs on the full four-core system | 61/61 |
| C demo programs on four cores (locks, queues, memory-ordering tests, self-modifying code) | 7/7 |
| Random coherence test, checked every cycle | Pass (3 seeds) |
| Deliberately broken designs caught by that test | 6/6 |
| Dhrystone | 1.36 cycles per instruction, 0.75 DMIPS/MHz (3.05x faster than before the performance work) |
| FPGA logic estimate (Yosys) | 56,436 LUTs, 89% of the XC7A100T |

**Not yet done:** a Vivado build (real utilisation and timing) and a run on the
board. The FPGA figure above is a Yosys estimate, not a Vivado result.

A visual summary for evaluators is in
[docs/results/index.html](docs/results/index.html) (download it and open it in
a browser).

## Contents

- [How it works](#how-it-works)
- [Repository layout](#repository-layout)
- [Install the tools](#install-the-tools)
  - [Linux (Ubuntu 24.04)](#linux-ubuntu-2404)
  - [Windows (WSL 2)](#windows-wsl-2)
  - [Vivado](#vivado)
- [Quick start](#quick-start)
- [Reproduce every result](#reproduce-every-result)
- [Run on the FPGA board](#run-on-the-fpga-board)
- [Write your own program](#write-your-own-program)
- [Troubleshooting](#troubleshooting)
- [Documentation and history](#documentation-and-history)

## How it works

```
   I/O at 0x8000_0000: UART, LEDs, 7-segment     (uncached, shared)
     |          |          |          |
  +------+   +------+   +------+   +------+
  |core 0|   |core 1|   |core 2|   |core 3|     out-of-order CPU
  | L1I  |   | L1I  |   | L1I  |   | L1I  |     4 KB instruction cache
  | L1D  |   | L1D  |   | L1D  |   | L1D  |     4 KB data cache, MESI
  +--+---+   +--+---+   +--+---+   +--+---+
     |          |          |          |
  ===+==========+==========+==========+===     snooping bus
                     |
                +----+----+
                | L2 16 KB|                     shared cache
                +----+----+
                |  64 KB  |                     main memory
                +---------+
```

Each data-cache line is in one of four states: Modified, Exclusive, Shared or
Invalid. A core that needs a line it may not use locally asks on the bus
(BusRd to read, BusRdX to write, BusUpgr to upgrade a shared copy), and the
other three caches watch the bus and give up or hand over their copies. Only
one request is on the bus at a time, so all cores see memory operations in the
same order.

Inside a core, an instruction is fetched (with a predicted next address),
decoded, renamed to a free physical register, and placed in the issue queue
and the reorder buffer. It runs as soon as its inputs are ready, even ahead of
older instructions, and the reorder buffer makes results permanent in program
order. A wrong branch guess is repaired when the branch reaches the head of
the reorder buffer.

The full description, written from the code, is in
[docs/architecture.md](docs/architecture.md).

## Repository layout

| Path | Contents |
|---|---|
| `rtl/core` | Out-of-order core: fetch and prediction, decode, rename, issue queue, ALU, branch unit, multiply/divide, load/store unit, reorder buffer, CSRs |
| `rtl/cache` | L1 instruction cache, L1 data cache (MESI), L2 |
| `rtl/coherence` | Bus arbiter, coherence bus, snoop controller |
| `rtl/memory` | Main memory and its controller |
| `rtl/io` | UART, memory-mapped I/O registers, 7-segment driver |
| `rtl/top` | `quad_core_top` (the system), `fpga_top` (board wrapper with clock and pins) |
| `sw` | Bare-metal C programs, start-up code, linker script, `soc.h` |
| `tb` | Block and core testbenches |
| `verif` | riscv-tests harness, system tests, four-core and board-level testbenches, random coherence test |
| `review` | Testbench reproducing the bugs found in the design review |
| `scripts` | Test runners, benchmark and area scripts, results page generator |
| `synth` | Nexys A7 constraints, Vivado build and program scripts |
| `results` | Benchmark numbers, one folder per date |
| `docs` | Architecture, plan, results page, reports from the original repository |

## Install the tools

All tools are free. The results above were produced with Icarus Verilog 12.0,
Verilator 5.020, Yosys 0.33, riscv64-unknown-elf-gcc 13.2.0 with binutils 2.42,
and Python 3. These are the versions Ubuntu 24.04 installs.

| Tool | Needed for |
|---|---|
| `make`, `git`, `python3` | everything |
| Icarus Verilog (`iverilog`) | all simulations |
| RISC-V GCC (`riscv64-unknown-elf-gcc`) | ISA tests, C programs, benchmarks |
| riscv-tests (a source checkout; nothing to build) | ISA tests and benchmarks |
| Verilator 5.x | `make bench`, `make ablation`, `make lint` |
| Yosys | `make synth`, `make synth-fpga` |
| Vivado (optional) | bitstream for the board |
| `python3-matplotlib`, `python3-numpy` (optional) | `make animate` and `make gui` only |

### Linux (Ubuntu 24.04)

```
sudo apt-get update
sudo apt-get install -y git make python3 iverilog verilator yosys gcc-riscv64-unknown-elf

git clone https://github.com/manal-a7med/Quad-core-RISC-V-OoO-with-MESI-Cache-Cherency-and-Cusom-NoC-Interconnect.git
git clone --depth 1 https://github.com/riscv-software-src/riscv-tests.git
cd Quad-core-RISC-V-OoO-with-MESI-Cache-Cherency-and-Cusom-NoC-Interconnect
```

The riscv-tests checkout sits next to this repository, which is where the
Makefile looks by default (`../riscv-tests`). If you put it somewhere else, add
`RISCV_TESTS=/path/to/riscv-tests` to the `make isa`, `make bench`,
`make regress` and `make results` commands.

Other distributions: install the same tools with your package manager.
Ubuntu 22.04 ships Verilator 4, which is too old for `make bench`; everything
else works there.

### Windows (WSL 2)

The build scripts are shell scripts, so on Windows they run inside WSL
(Windows Subsystem for Linux), which gives you a real Ubuntu alongside
Windows. Vivado stays a normal Windows program.

1. Open PowerShell **as administrator** and install Ubuntu 24.04:
   ```
   wsl --install -d Ubuntu-24.04
   ```
   Restart when asked, then open "Ubuntu 24.04" from the Start menu and choose
   a user name and password.

2. Keep the repository on the Windows drive, so that WSL and Windows Vivado
   use the same folder. In the Ubuntu window:
   ```
   sudo apt-get update
   sudo apt-get install -y git make python3 iverilog verilator yosys gcc-riscv64-unknown-elf
   git config --global core.autocrlf false
   mkdir -p /mnt/c/work && cd /mnt/c/work
   git clone https://github.com/manal-a7med/Quad-core-RISC-V-OoO-with-MESI-Cache-Cherency-and-Cusom-NoC-Interconnect.git
   git clone --depth 1 https://github.com/riscv-software-src/riscv-tests.git
   cd Quad-core-RISC-V-OoO-with-MESI-Cache-Cherency-and-Cusom-NoC-Interconnect
   ```
   The same folder is `C:\work\Quad-core-RISC-V-...` in Windows Explorer.

3. Run every `make` command in this README from that Ubuntu window.

`core.autocrlf false` matters. If Git converts the shell scripts to Windows
line endings, they fail with `/bin/sh^M: bad interpreter` or
`$'\r': command not found`. The repository's `.gitattributes` also asks for
Unix line endings.

Simulation is slower on `/mnt/c` than in the WSL home folder. If you only
simulate, clone into `~` instead; copy `build/sw/*.line.hex` to Windows when
you need one for Vivado.

Running the tools natively on Windows, without WSL, has not been tested.

### Vivado

Install the free "Vivado ML Standard" edition from AMD, which supports the
XC7A100T. Select the Artix-7 device family and the cable drivers during
installation. On Linux, put Vivado on the `PATH` with
`source <install folder>/settings64.sh`.

## Quick start

```
make sim                      # block and core testbenches
make isa                      # official RISC-V tests on one core
make soc-run PROG=hello       # C program on the four-core system
```

The last command prints, among the simulator messages:

```
hello from hart 0
hello from hart 1
hello from hart 2
hello from hart 3
RESULT PASS cycles=...
check_uart: 4 expected lines found
```

`make help` lists every target.

## Reproduce every result

Every test checks its own result: it prints `PASS` or a clear failure, and
`make` stops with an error if anything fails. You do not need to read
waveforms to know whether it worked.

### Everything at once

```
make regress
```

Runs every check in the table below except linting and synthesis, and stops at
the first failure. It ends with `regress: all checks passed`. With Icarus
Verilog it takes roughly 45 minutes.

### One check at a time

| Command | What it checks | You should see |
|---|---|---|
| `make sim` | Block and core testbenches: MESI state machine, bus arbiter, cache, core, dependent instructions, corner cases, four-core system | `All testbenches passed.` |
| `make sim-repro` | The bugs found in the design review stay fixed | `check_log: build/repro.log OK` |
| `make isa` | Official RISC-V tests on one core, plus a CSR/trap test and a memory stress test | `rv32ui: 41 passed, 0 failed`, `rv32ua: 10 passed`, `rv32um: 8 passed`, `system: 2 passed` |
| `make soc-isa` (after `make isa`) | The same 61 programs on the full system with caches, bus and memory | `soc: 61 passed, 0 failed` |
| `make soc-run PROG=hello` | Each core prints a line over the UART | `hello from hart 0` to `3` |
| `make soc-run PROG=parsum` | Four cores sum an array in parallel | `total=0x001ffc00 OK` |
| `make soc-run PROG=atomics` | A shared counter: wrong without atomics, exact with `amoadd` and with an LR/SC lock | `amoadd.w: 800 of 800 OK` |
| `make soc-run PROG=prodcons` | A producer/consumer queue across cores, using fences | `total 200 items, sum 20100 OK, duplicates 0, missing 0` |
| `make soc-run PROG=litmus` | Memory-ordering experiments (MP, SB, CoRR, LB, IRIW), with and without fences | `litmus: no forbidden outcome` |
| `make soc-run PROG=memstress` | The load/store queue under pressure | `memstress: 896 checks, 0 errors` |
| `make soc-run PROG=selfmod` | Code written by stores and run after FENCE.I, including code written by another core | `selfmod: 0 errors` |
| `make fpga-sim PROG=<name>` | The same programs through the board wrapper `fpga_top`, reading the UART pin like a terminal | as for `soc-run` |
| `make coh-random` | Thousands of random reads, writes and atomics into the four data caches; every value, and the one-writer rule, checked every cycle | `RESULT PASS` for each of 3 seeds |
| `make coh-mutants` | The random test fails on six designs with a planted coherence bug | `mutants caught: 6 of 6` |
| `make lint`, `make lint-soc` | Verilator lint finds no errors | no `%Error` lines |
| `make synth` | One core synthesises with Yosys | a cell count |

Each demo program has its expected output in `sw/<name>/expect.txt`, and
`soc-run` and `fpga-sim` check the UART output against it
(`check_uart: N expected lines found`).

### Performance

```
make bench          # 10 riscv-tests benchmarks on a Verilator model of the system
make bench-check    # compare with the committed reference numbers
```

`make bench-check` prints the reference cycle counts and yours side by side.
With GCC 13.2.0 (the Ubuntu 24.04 version) they are identical, because the
simulation is fully deterministic. A different compiler produces slightly
different programs and so slightly different counts, but every benchmark must
still pass.

```
make ablation       # the same benchmarks with one feature switched off
```

Builds the design without branch prediction, with in-order issue, with
neither, and with MSI instead of MESI, and writes the numbers to
`build/ablation/`. Committed results are in `results/`.

### FPGA area estimate

```
make synth-fpga     # about 15 minutes
```

Prints LUT, flip-flop, block RAM and DSP use against the XC7A100T. Expect
about 56,400 LUTs (89%).

### Results page

```
make results
```

Reruns the evidence and regenerates `docs/results/index.html`. Run
`make synth-fpga` first if you want the area section refreshed.

## Run on the FPGA board

The Vivado flow is written but has not yet been run end to end. Treat this
section as untested until the first board run is reported here.

**Linux:**

```
make sw                       # builds build/sw/<prog>.line.hex for every program
make fpga PROG=hello          # Vivado: bitstream with the program in memory
make program                  # load it onto the board over USB
```

**Windows:** build the program images in WSL with `make sw`. Then open
"Vivado Tcl Shell" from the Start menu and run:

```
cd C:/work/Quad-core-RISC-V-OoO-with-MESI-Cache-Cherency-and-Cusom-NoC-Interconnect
vivado -mode batch -source synth/build.tcl -tclargs build/sw/hello.line.hex 20
vivado -mode batch -source synth/program.tcl -tclargs build/vivado/fpga_top.bit
```

Program the board from Windows, not from WSL: WSL does not see USB devices by
default.

The reports (`utilization.rpt`, `timing.rpt`) and the bitstream go to
`build/vivado/`. The core clock is 50 MHz. If timing fails, rebuild at 40 MHz
with `CLKOUT_DIV=25` on Linux, or `25` as the last argument on Windows.

On the board: open a serial terminal on the board's USB port at 115200 baud,
8N1, to see the UART output. The LEDs show the program's `LEDS` register and
the 7-segment display its `HEX` register; the rightmost decimal point lights
when the program has finished. CPU_RESET restarts the program.

## Write your own program

Copy `sw/hello` to `sw/myprog`, edit the C file, and run
`make soc-run PROG=myprog`. Every core starts in `main(hart)` with its own hart
number; core 0 runs the start-up code first and the others wait for it.
`sw/common/soc.h` has the I/O helpers (`uart_puts`, `LEDS`, `HEX`, `EXIT`) and
the cycle counter. Writing `EXIT = 1` ends a simulation as a pass, and any
other value as a fail. If you add `sw/myprog/expect.txt`, the UART output is
checked against it.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `riscv_test.h: No such file or directory` | Your copy is older than commit d23abfc, which first committed `verif/riscv-tests/env/`. Update the repository |
| Every ISA test says `RESULT TIMEOUT` | Your copy is older than commit 2c6cd88 and sits in a folder with a long path (as on GitHub Actions), so the test file name was cut off. Update the repository |
| `make isa` cannot find the tests | riscv-tests is not at `../riscv-tests`; pass `RISCV_TESTS=/path/to/riscv-tests` |
| `/bin/sh^M: bad interpreter` or `$'\r': command not found` | Windows line endings. Run `git config --global core.autocrlf false`, delete the clone and clone again |
| `make bench` fails while building the model | Verilator is older than 5.0. Use Ubuntu 24.04 or install Verilator 5 |
| `riscv64-unknown-elf-gcc: not found` | Install `gcc-riscv64-unknown-elf` |
| A CI job is red on GitHub | Open the job, then the failed step. "Install tools" or "Fetch riscv-tests" failures are usually network problems; use "Re-run failed jobs". For anything else, run the same `make` command locally |

## Documentation and history

| Document | What it covers |
|---|---|
| [docs/architecture.md](docs/architecture.md) | The design as it is in the code; the reference for everything else |
| [docs/plan/README.md](docs/plan/README.md) | The 8-phase roadmap, with links to the design review, the verification and benchmarking strategy, and a plain-language debrief of the work |
| [docs/results/index.html](docs/results/index.html) | Visual evidence: bug fixes, ISA tests, pipeline trace, multicore demos, performance, FPGA fit |
| [review/README.md](review/README.md) | The testbench that reproduces the original bugs |
| `docs/detailed_report.md`, `docs/academic_report.md` | Reports from the original repository. They describe the design before this work and are kept for reference |

**History.** The design was imported from
[Ratan-Y-Mallya/Major-project](https://github.com/Ratan-Y-Mallya/Major-project).
A design review found 18 bugs, several of which stopped real programs from
running. The work since then follows the roadmap: P0 build and CI, P1 a
correct core, P2 FPGA readiness, P3 multicore software (atomics, fences,
coherence tests), P4 performance (fetch, branch prediction, multiply and
divide). A network-on-chip with directory coherence (P5, P6) and an ASIC flow
(P7) are planned as later stretch work.

**Status:** P0 to P3 and the first part of P4 are complete in simulation.
Vivado and board results are pending.
