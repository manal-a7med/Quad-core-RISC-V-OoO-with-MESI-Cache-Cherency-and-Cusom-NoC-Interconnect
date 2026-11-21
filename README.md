# Quad-core RISC-V out-of-order processor with MESI cache coherence

[![CI](https://github.com/manal-a7med/Quad-core-RISC-V-OoO-with-MESI-Cache-Cherency-and-Cusom-NoC-Interconnect/actions/workflows/ci.yml/badge.svg)](https://github.com/manal-a7med/Quad-core-RISC-V-OoO-with-MESI-Cache-Cherency-and-Cusom-NoC-Interconnect/actions/workflows/ci.yml)

Four RISC-V cores that share memory, written in Verilog. Each core executes
instructions out of order, and the cores' private data caches are kept
coherent with the MESI protocol over one of two interconnects, chosen at
build time: a snooping bus (the baseline) or a 2x2 mesh network-on-chip with
a directory (`NOC=1`). Both builds use the same cores, L1 caches, L2 and
memory, so any difference between them comes from the interconnect alone.
The cores run C programs compiled with the standard RISC-V GCC toolchain.

The project is evaluated in simulation. FPGA work is on hold (see
[docs/scope.md](docs/scope.md)); the FPGA files stay in the repository, but no
FPGA result is claimed. The design started from an imported repository; what
was reused and what is new is listed in [docs/scope.md](docs/scope.md).

Every result in this README can be reproduced with free tools on Linux, or on
Windows through WSL. The section [Reproduce every result](#reproduce-every-result)
gives the command for each claim and what it should print.

## At a glance

| | |
|---|---|
| ISA | RV32IMA + Zicsr + Zifencei, machine mode |
| Core | Single-issue out-of-order: 64 physical registers, 8-entry issue queue, 16-entry reorder buffer, 8-entry load/store queue, branch prediction (256 two-bit counters, 8-entry return address stack) |
| Caches | Per core: 4 KB L1 instruction cache, 4 KB 2-way L1 data cache. Shared: 16 KB 4-way L2 |
| Coherence, bus build | MESI over a snooping bus, round-robin arbitration, cache-to-cache transfer |
| Coherence, NoC build | MESI with a duplicate-tag directory (1 home, or a home at each of the 4 nodes), three 2x2 meshes with XY wormhole routers, the owner sends the line straight to the requester |
| Memory and I/O | 64 KB memory; UART, LEDs and 7-segment display registers at 0x8000_0000 |
| Evaluated in | Simulation: Icarus Verilog 12 and Verilator 5 (FPGA on hold) |

## Results

All of these come from simulation, and each has a command below that
reproduces it.

| Check | Result |
|---|---|
| Official RISC-V tests on one core: rv32ui / rv32ua / rv32um | 41/41, 10/10, 8/8 |
| The same 61 test programs on the full four-core system | 61/61 on the bus and on the NoC builds |
| C demo programs on four cores (locks, queues, memory-ordering tests, self-modifying code, load ordering) | 8/8 on the bus and on the NoC builds |
| Random coherence test, every value checked against a reference memory | Pass (bus and three NoC builds) |
| Deliberately broken designs caught by the tests | 7/7 coherence bugs on the bus, 9/9 on the NoC, 2/2 load/store ordering bugs in the core |
| Functional coverage of the coherence protocol | Every reachable bin hit: 37/37 on the bus, 41/41 on the NoC, no illegal event |
| Formal proof (Yosys) of the bus arbiter | One grant at a time, round-robin order, no starvation: proved |
| Dhrystone | 1.36 cycles per instruction, 0.75 DMIPS/MHz (3.05x faster than before the performance work) |
| Bus vs NoC, four cores, misses on different lines | The bus stops at about 170 accesses per 1000 cycles, the NoC reaches about 260 (1.5x); a single miss is slower on the NoC (14 against 9 cycles) |
| Bus vs mesh at 9 and 16 cores (calibrated model) | Under heavy load the mesh carries 3.2x (9 cores) and 5.1x (16 cores) what the bus does; on one hot line it gains only 1.2x, because one home serves every miss |
| Parallel speed-up, 1 to 4 cores | On 4 cores the multi-thread benchmarks run 2.9x to 3.7x faster than on 1 core on the bus, and 2.8x to 3.8x on the NoC with a home per node |

The 24 bugs found and fixed along the way are listed in
[docs/bugs.md](docs/bugs.md).

A visual summary for evaluators is in
[docs/results/index.html](docs/results/index.html) (download it and open it in
a browser). Charts for presentations and a slide deck with a short explanation
of each result are in [results/visual/](results/visual/) (`make visuals`).

## Contents

- [How it works](#how-it-works)
- [Repository layout](#repository-layout)
- [Install the tools](#install-the-tools)
  - [Linux (Ubuntu 24.04)](#linux-ubuntu-2404)
  - [Linux (Ubuntu 22.04)](#linux-ubuntu-2204)
  - [Docker (any system, exact tool versions)](#docker-any-system-exact-tool-versions)
  - [Windows (WSL 2)](#windows-wsl-2)
- [Quick start](#quick-start)
- [Reproduce every result](#reproduce-every-result)
- [Write your own program](#write-your-own-program)
- [Troubleshooting](#troubleshooting)
- [Documentation and history](#documentation-and-history)
- [FPGA (on hold)](#fpga-on-hold)

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

With `NOC=1` the bus is replaced by a 2x2 mesh: each core sits at one node,
its requests travel as packets to the line's directory home, and the home
asks the owner (if any) to send the line straight to the requester:

```
  node 0 ---- node 1        each node: a core with its L1s, a router on each
    |           |           of three meshes (requests, home to core, owner
  node 2 ---- node 3        to core), and a directory home (NOC_BANKS=4) or
                            only at node 0 (default); the L2 and memory are shared
```

Each data-cache line is in one of four states: Modified, Exclusive, Shared or
Invalid. A core that needs a line it may not use locally asks on the bus
(BusRd to read, BusRdX to write, BusUpgr to upgrade a shared copy), and the
other three caches watch the bus and give up or hand over their copies. Only
one request is on the bus at a time, so all cores see memory operations in the
same order. In the NoC build the directory home plays that role for each line.

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
| `rtl/coherence` | Bus arbiter, coherence bus, snoop controller, the L1 coherence port contract (`coh_port.vh`) |
| `rtl/noc` | NoC + directory build (`NOC=1`): mesh router, network interface, directory home |
| `rtl/memory` | Main memory and its controller |
| `rtl/io` | UART, memory-mapped I/O registers, 7-segment driver |
| `rtl/top` | `quad_core_top` (the system), `fpga_top` (board wrapper with clock and pins) |
| `sw` | Bare-metal C programs, start-up code, linker script, `soc.h` |
| `tb` | Block and core testbenches |
| `verif` | riscv-tests harness, system tests, four-core and board-level testbenches, random coherence test and its coverage bins, synthetic traffic, the bus-vs-mesh scaling model |
| `review` | Testbench reproducing the bugs found in the design review |
| `scripts` | Test runners, mutation tests, benchmark, coverage, scaling and formal scripts, results page generator |
| `synth` | Nexys A7 constraints, Vivado build and program scripts (FPGA on hold) |
| `results` | Benchmark numbers, one folder per date; `results/visual` holds the presentation charts and slide deck |
| `docs` | Architecture, scope, bug list, plan, results page; `docs/archive` holds the reports from the original repository |

## Install the tools

All tools are free. The results above were produced with Icarus Verilog 12.0,
Verilator 5.020, Yosys 0.33, riscv64-unknown-elf-gcc 13.2.0 with binutils 2.42,
and Python 3. These are the versions Ubuntu 24.04 installs.

| Tool | Needed for |
|---|---|
| `make`, `git`, `python3` | everything |
| Icarus Verilog (`iverilog`) | all simulations |
| RISC-V GCC (`riscv64-unknown-elf-gcc`) | ISA tests, C programs, benchmarks |
| riscv-tests (included as a git submodule; nothing to install) | ISA tests and benchmarks |
| Verilator 5.x | `make bench`, `make ablation`, `make lint` |
| Yosys | `make synth`, `make formal` |
| `python3-matplotlib`, `python3-numpy` (optional) | `make visuals`, `make animate` and `make gui` only |

### Linux (Ubuntu 24.04)

```
sudo apt-get update
sudo apt-get install -y git make python3 python3-matplotlib iverilog verilator yosys gcc-riscv64-unknown-elf

git clone --recurse-submodules https://github.com/manal-a7med/Quad-core-RISC-V-OoO-with-MESI-Cache-Cherency-and-Cusom-NoC-Interconnect.git
cd Quad-core-RISC-V-OoO-with-MESI-Cache-Cherency-and-Cusom-NoC-Interconnect
```

`--recurse-submodules` also downloads
[riscv-tests](https://github.com/riscv-software-src/riscv-tests) into
`third_party/riscv-tests`, pinned to the exact commit the published results
were made with, so your ISA test and benchmark numbers match ours. If you
already cloned without it, run this once inside the repository:

```
git submodule update --init --recursive
```

To use a different riscv-tests checkout, add `RISCV_TESTS=/path/to/riscv-tests`
to the `make isa`, `make bench`, `make regress` and `make results` commands.

`sh scripts/setup_ubuntu.sh` does all of this in one step (it also fetches the
riscv-tests submodule if it is missing).

Other distributions: install the same tools with your package manager.

### Linux (Ubuntu 22.04)

Ubuntu 22.04 has older tools: Icarus Verilog 11, Yosys 0.9, RISC-V GCC 10.2
and Verilator 4.038. Everything works with them except the Verilator model,
which needs Verilator 5. The setup script installs the rest from apt and
builds Verilator 5.020 from source into `/usr/local` (about 10 minutes, once):

```
sudo apt-get update && sudo apt-get install -y git
git clone --recurse-submodules https://github.com/manal-a7med/Quad-core-RISC-V-OoO-with-MESI-Cache-Cherency-and-Cusom-NoC-Interconnect.git
cd Quad-core-RISC-V-OoO-with-MESI-Cache-Cherency-and-Cusom-NoC-Interconnect
sh scripts/setup_ubuntu.sh
make regress
```

Tested on 21 Nov 2026 from a fresh clone in an Ubuntu 22.04 container:
`make regress`, `make formal`, `make synth`, `make lint`, `make bench` and
`make visuals` all pass. Without Verilator 5 (`SKIP_VERILATOR=1`) everything
except `make bench`, `make ablation`, `make compare-ic`, `make scaling` and
`make lint` still works.

GCC 10 compiles the benchmarks a little differently from GCC 13, so
`make bench` on 22.04 gives slightly different cycle counts from the committed
ones (most within 1 %; towers 19 % slower, mt-matmul 10 % faster, median 5 %
faster). The hardware is the same; the programs differ. For the exact
published numbers use Ubuntu 24.04 or the Docker image below.

### Docker (any system, exact tool versions)

The `Dockerfile` gives the exact Ubuntu 24.04 tool versions the results were
made with, on any machine with Docker (Ubuntu 22.04, other Linux, macOS,
Windows):

```
docker build -t quadcore .
docker run --rm -it -v "$PWD":/work -u "$(id -u):$(id -g)" quadcore make regress
```

Any `make` target works the same way, for example `... quadcore make bench`.

### Windows (WSL 2)

The build scripts are shell scripts, so on Windows they run inside WSL
(Windows Subsystem for Linux), which gives you a real Ubuntu alongside
Windows.

1. Open PowerShell **as administrator** and install Ubuntu 24.04:
   ```
   wsl --install -d Ubuntu-24.04
   ```
   Restart when asked, then open "Ubuntu 24.04" from the Start menu and choose
   a user name and password.

2. In the Ubuntu window:
   ```
   sudo apt-get update
   sudo apt-get install -y git make python3 iverilog verilator yosys gcc-riscv64-unknown-elf
   git config --global core.autocrlf false
   mkdir -p /mnt/c/work && cd /mnt/c/work
   git clone --recurse-submodules https://github.com/manal-a7med/Quad-core-RISC-V-OoO-with-MESI-Cache-Cherency-and-Cusom-NoC-Interconnect.git
   cd Quad-core-RISC-V-OoO-with-MESI-Cache-Cherency-and-Cusom-NoC-Interconnect
   ```
   The same folder is `C:\work\Quad-core-RISC-V-...` in Windows Explorer.

3. Run every `make` command in this README from that Ubuntu window.

`core.autocrlf false` matters. If Git converts the shell scripts to Windows
line endings, they fail with `/bin/sh^M: bad interpreter` or
`$'\r': command not found`. The repository's `.gitattributes` also asks for
Unix line endings.

Simulation is slower on `/mnt/c` than in the WSL home folder, so clone into
`~` if you do not need the files in Windows Explorer.

Running the tools natively on Windows, without WSL, has not been tested.

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
| `make soc-run PROG=ldorder` | Two loads of the same address are performed in program order, even when the older one misses (RISC-V's CoRR rule) | `ldorder: 32 rounds, same-address loads in order OK` |
| `make fpga-sim PROG=<name>` | The same programs through the board wrapper `fpga_top`, reading the UART pin like a terminal (a system test; the FPGA itself is on hold) | as for `soc-run` |
| `make coh-random` | Thousands of random reads, writes and atomics into the four data caches; every value, and the one-writer rule, checked every cycle | `RESULT PASS` for each of 3 seeds, and a coverage line |
| `make coh-mutants` | The random test fails on seven designs with a planted coherence bug | `mutants caught: 7 of 7` |
| `make core-mutants` | The core tests fail on two designs with a planted load/store ordering bug | `core mutants caught: 2 of 2` |
| `make coverage` | Functional coverage of the coherence protocol on the bus and two NoC builds (`build/coverage.txt`) | `bus: 37 of 37 bins hit`, `noc1: 41 of 41`, `noc4: 41 of 41`, 0 illegal events |
| `make formal` | Yosys proves the bus arbiter's properties for every input sequence, and fails on a broken copy | `bus_arbiter properties PROVED`, then `FAILED (must be FAILED)` |
| `make lint`, `make lint-soc` | Verilator lint finds no errors | no `%Error` lines |
| `make synth` | One core synthesises with Yosys | a cell count |

Each demo program has its expected output in `sw/<name>/expect.txt`, and
`soc-run` and `fpga-sim` check the UART output against it
(`check_uart: N expected lines found`).

### NoC + directory build

The same system can be built with a 2x2 mesh network-on-chip and a directory
in place of the snooping bus (see `docs/architecture.md`, section 4.2). Add
`NOC=1` to any command above; `NOC_BANKS=4` gives every node its own
directory home, and `NOC_FLIT=128` or `256` makes the network links wider
(the default is 64 bits). Outputs go to `build/noc1/`, `build/noc4/`,
`build/noc4_f256/` and so on, so the builds never mix.

| Command | You should see |
|---|---|
| `make regress NOC=1` | `regress: all checks passed` |
| `make coh-mutants NOC=1` | `mutants caught: 9 of 9` (six of the bus ones plus three directory bugs) |
| `make soc-run NOC=1 PROG=litmus` | `litmus: no forbidden outcome` |
| `make bench NOC=1` | benchmark cycle counts for the NoC build in `build/noc1/bench/results.txt` |
| `make sim-noc` | `RESULT PASS` (the mesh alone under random traffic; also part of `make sim`) |

### Bus vs NoC

Both builds use the same cores, L1s, L2 and memory, so any difference in
speed comes from the interconnect alone.

| Command | What it gives |
|---|---|
| `make compare-ic` | the benchmarks on the bus and four NoC builds, side by side (`build/compare_ic.txt`) |
| `make traffic` | latency and throughput under synthetic load: private lines, shared lines and one hot set (`build/traffic/traffic.txt`) |
| `make scaling` | the parallel benchmarks on 1, 2 and 4 cores, bus and NoC: speed-up over 1 core (`build/scaling.txt`) |
| `make mesh-scaling` | bus vs mesh at 4, 9 and 16 cores, from a model calibrated on `make traffic` (`build/mesh_scaling/mesh_scaling.txt`) |

The latest numbers are in `results/2026-11-13/` (`interconnect.txt`,
`traffic.txt`) and `results/2026-11-21/` (`scaling.txt`, `mesh_scaling.txt`,
`coverage.txt`). The SoC's NoC is 2x2, so `make mesh-scaling` uses a model
(`verif/scaling/tb_mesh_scaling.v`); its header says what it leaves out.

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

### Results page

```
make results
```

Reruns the evidence and regenerates `docs/results/index.html`.

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
| `riscv_test.h: No such file or directory` | Your copy is older than commit 20582bd, which first committed `verif/riscv-tests/env/`. Update the repository |
| Every ISA test says `RESULT TIMEOUT` | Your copy is older than commit 0f6c40e and sits in a folder with a long path (as on GitHub Actions), so the test file name was cut off. Update the repository |
| `riscv-tests not found at third_party/riscv-tests` | The repository was cloned without `--recurse-submodules`. Run `git submodule update --init --recursive` |
| `/bin/sh^M: bad interpreter` or `$'\r': command not found` | Windows line endings. Run `git config --global core.autocrlf false`, delete the clone and clone again |
| `make bench` fails while building the model | Verilator is older than 5.0. Use Ubuntu 24.04 or install Verilator 5 |
| `riscv64-unknown-elf-gcc: not found` | Install `gcc-riscv64-unknown-elf` |
| A CI job is red on GitHub | Open the job, then the failed step. "Install tools" or checkout (submodule) failures are usually network problems; use "Re-run failed jobs". For anything else, run the same `make` command locally |

## Documentation and history

| Document | What it covers |
|---|---|
| [docs/architecture.md](docs/architecture.md) | The design as it is in the code; the reference for everything else |
| [docs/scope.md](docs/scope.md) | What is evaluated, how the build differs from the proposal and why, and what was reused vs written new |
| [docs/bugs.md](docs/bugs.md) | Every bug found and fixed |
| [docs/plan/README.md](docs/plan/README.md) | The 8-phase roadmap with its status, and links to the design review, the verification and benchmarking strategy, a plain-language debrief and the project review |
| [docs/results/index.html](docs/results/index.html) | Visual evidence: bug fixes, ISA tests, pipeline trace, multicore demos, performance |
| [review/README.md](review/README.md) | The testbench that reproduces the original bugs |
| [docs/archive/](docs/archive/README.md) | Reports from the original repository. They describe the design before this work and are kept for reference |

**Basic flow.** The work follows the roadmap: P0 build and CI, P1 a correct
core, P2 system bring-up in simulation (the FPGA half is on hold), P3
multicore software (atomics, fences, coherence tests), P4 performance (fetch,
branch prediction, multiply and divide), P5 a network-on-chip with directory
coherence, and P6 the bus vs NoC comparison. An ASIC flow (P7) is planned as
later stretch work.

## FPGA (on hold)

FPGA work is on hold and is not part of the evaluated results. The files
stay in the repository: `rtl/top/fpga_top.v` (board wrapper for the Digilent
Nexys A7-100T, 50 MHz), `synth/` (constraints and Vivado scripts),
`make fpga PROG=<name>` (bitstream), `make program` (load it) and
`make synth-fpga` (Yosys LUT estimate, about 15 minutes). None of these has
been run end to end on a board. `make fpga-sim` still simulates the board
wrapper, as a system test.
