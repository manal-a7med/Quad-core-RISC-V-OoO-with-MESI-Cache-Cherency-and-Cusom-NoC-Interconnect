# Scope, changes from the proposal, and what is reused

This file records three things an evaluator will ask about: what the project
covers today, how it differs from the August proposal and why, and which parts
were reused and which are original. Line counts come from
`git diff --numstat 5cacf48 HEAD`, where `5cacf48` is the last commit of the
imported code.

## 1. Scope today (21 Nov 2026)

The project is evaluated **in simulation**. All results come from Icarus
Verilog and Verilator runs that anyone can repeat with `make`.

| In scope | Not in scope for now |
|---|---|
| Four RV32IMA out-of-order cores with private L1 caches, a shared L2 and a 64 KB memory | FPGA bring-up and board demos (on hold since 21 Nov) |
| MESI over a snooping bus: the **baseline** build | ASIC flow (P7), as later stretch work |
| MESI over a 2x2 mesh network with a directory (`NOC=1`): the **interconnect contribution** | Inclusive L2 (decided against on 13 Nov) |
| Bus vs NoC comparison with the same cores, L1s, L2 and memory | |
| Verification: directed tests, riscv-tests, random coherence tests, mutation tests, litmus tests, assertions | |

The FPGA files stay in the repo (`rtl/top/fpga_top.v`, `synth/`, `make fpga`,
`make program`), and `make fpga-sim` still simulates the FPGA top level with
its UART, because it is a useful system test. No FPGA result is claimed.

## 2. Changes from the proposal

The proposal ("Design, Integration, and Verification of a Cache-Coherent
Dual-Core RISC-V SoC with a Custom NoC Interconnect") was written before the
borrowed code was examined. The table lists each promise, what was built, and
why.

| Proposal | Built | Why |
|---|---|---|
| 2 cores | 4 cores | The imported design already had four cores. Four cores also make the interconnect matter, which is the point of the NoC comparison. |
| A verified superscalar OoO core, used unmodified | A single-issue OoO core, repaired and extended | A review found 18 bugs in the imported RTL, several of which stopped real programs from running, and 5 more were found later ([bugs.md](bugs.md)). The core was never superscalar. It had no CSRs, traps, multiply, atomics or branch predictor, and these were added. |
| RV32I / RV32IM | RV32IMA + Zicsr + Zifencei, machine mode | Multicore software needs atomics (A), `mhartid` and traps; benchmarks need M. |
| 2-level adaptive branch predictor (in the core) | 256 two-bit counters, 8-entry return stack, 16-entry indirect target table | The imported core predicted every branch not taken. A simple predictor gave most of the speed-up. |
| Point-to-point / ring link, round-robin, credit-based flow control | Snooping bus (baseline) and a 2x2 mesh with XY wormhole routers and valid/ready flow control (`NOC=1`) | A 2-node link does not scale to 4 cores. Valid/ready with small FIFOs gives the same "never overflow" guarantee as credits on one-cycle links, with less logic. Credits matter when a link is several cycles long. |
| MSI, MESI as a stretch | MESI; MSI kept as a build switch (`CFG_MSI`) for measurement | The imported design already used MESI. |
| Snooping only; directory as future scope | Snooping bus and a duplicate-tag directory with 1 or 4 homes | The NoC needs a directory, because a mesh has no broadcast. |
| LSQ squash and replay of a speculative load hit by a snoop | Not needed; loads of the same bytes are performed in program order, one cache access at a time | RISC-V's memory model (RVWMO) only needs same-address loads in order. See [architecture.md §2.1](architecture.md#21-memory-ordering-and-why-no-load-replay-is-needed); `sw/ldorder` and `make core-mutants` test it. |
| Directed tests, random tests, SVA, functional coverage report (95 %+) | Directed tests, riscv-tests, random coherence tester, 9 mutants, litmus tests, SVA, functional coverage (`make coverage`) | Mutation tests were added to prove that the checks catch real bugs. |
| Simulation demo required, FPGA as a stretch | Simulation only; FPGA on hold | As in the proposal: FPGA was always optional. |
| QuestaSim / Xcelium, or Icarus + cocotb | Icarus Verilog 12 and Verilator 5 | Free tools, so anyone can repeat every result. |
| Stretch: IPC vs an idealised no-contention baseline | 1/2/4-core speed-up and an ideal-memory run (`make scaling`) | |

Things the proposal listed as **future scope** that were done: four cores
(12.1), a 2x2 mesh with XY routing and buffered routers (12.1), and directory
coherence (12.2).

## 3. Reused and original work

### Where the reused code comes from

The starting point is the repository
[Ratan-Y-Mallya/Major-project](https://github.com/Ratan-Y-Mallya/Major-project),
imported with its full history on 11 Nov 2026 (its 8 commits keep their
original author in git). It held about 3,850 lines of Verilog: the OoO core,
the L1 and L2 caches, the MESI protocol module, the snoop controller, the bus
arbiter, the memory, the 4-core top level, 7 testbenches and a MESI
visualiser script. The proposal describes the core as a senior's design; the
report should name this repository as the source and the guide's sign-off
should cover all of it, not only the core.

### In numbers

| Part | Imported | Now | Since the import |
|---|---|---|---|
| RTL (`rtl/`) | 3,850 lines, 24 files | 6,800 lines, 40 files | 4,030 lines added, 1,080 removed; 16 new files |
| Testbenches (`tb/`) | 7 testbenches | 8 | Moved from `test_bench/`, fixed, plus `tb_noc_mesh.v` |
| System tests (`verif/`) | none | 1,050 lines | All new |
| Software (`sw/`) | none | 1,120 lines | All new |
| Scripts (`scripts/`) | `mesi_visualizer.py` | 13 scripts | 12 new |

About 41 % of today's RTL lines are imported lines that were kept; 59 % were
written in this project.

### File by file (RTL)

| File | Status | Change since the import |
|---|---|---|
| `core/alu.v`, `core/branch_unit.v`, `core/rename_unit.v` | Reused | unchanged |
| `core/register_file.v` | Reused, small fix | +10 / −7 |
| `core/common_defs.vh` | Reused, extended | +16 |
| `core/decode_unit.v` | Reused, extended (JAL, AUIPC, traps, M, A, CSR) | +77 / −2 |
| `core/issue_queue.v` | Reused, fixed (age, latch, LSQ gating) | +71 / −9 |
| `core/reorder_buffer.v` | Reused, fixed (traps, redirect) | +57 / −7 |
| `core/fetch_unit.v` | Mostly rewritten (pipelined fetch, predictor) | +139 / −22 |
| `core/load_store_unit.v` | Mostly rewritten (forwarding, ordering, flush) | +263 / −106 |
| `core/riscv_ooo_core.v` | Reworked | +248 / −33 |
| `core/csr_file.v`, `core/muldiv_unit.v`, `core/amo.vh` | New | |
| `cache/l1_dcache.v` | Mostly rewritten (races, handshake, atomics) | +347 / −267 |
| `cache/l1_icache.v` | Mostly rewritten (pipelined, coherent fills) | +93 / −114 |
| `cache/l2_cache.v` | Reworked | +161 / −80 |
| `cache/cache_controller.v` | Reused, unused | unchanged |
| `cache/mesi_defines.vh` | Reused | +3 / −2 |
| `coherence/mesi_protocol.v` | Reused | +2 / −2 |
| `coherence/snoop_controller.v` | Reused | +3 / −2 |
| `coherence/bus_arbiter.v` | Reused | +1 / −1 |
| `coherence/coherence_bus.v` | Reused, trimmed | +17 / −41 |
| `coherence/coh_port.vh`, `coherence/bus_interconnect.v` | New (common L1 port, so bus and NoC are swappable) | |
| `noc/*` (8 files: routers, mesh, network interfaces, directory home) | New | 1,570 lines |
| `memory/main_memory.v` | Reworked | +50 / −82 |
| `memory/memory_controller.v` | Reused | +1 / −1 |
| `io/*` (UART, LEDs, 7-segment) | New | |
| `top/quad_core_top.v` | Reworked | +153 / −231 |
| `top/fpga_top.v` | Reworked (FPGA on hold) | +86 / −71 |

**What this means for the report.** The MESI protocol table, the snoop
controller and the bus arbiter are reused almost unchanged, so the coherence
*protocol* should not be claimed as original. The original contributions are:

1. finding and fixing 23 bugs, and making the system run real C programs on
   four cores;
2. the multicore ISA support (atomics, fences, CSRs, traps, FENCE.I) and the
   race-free L1 data cache;
3. the performance work (pipelined fetch, branch prediction, multiply/divide),
   3.0x on Dhrystone;
4. the NoC and directory build, which is all new, and the bus vs NoC study;
5. the verification suite: system tests, random coherence tester, mutation
   tests, litmus tests, assertions and coverage.

## 4. Tools and AI assistance

Since 11 Nov 2026 most code changes, tests and documents were written with
the help of an AI coding assistant (Claude, by Anthropic), directed and
reviewed by the author; those commits carry a `Co-Authored-By: Claude` line.
Check the department's rules on AI tools and state their use in the report's
declaration, next to the reused code.
