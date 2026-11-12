# Architecture

This file describes the design as it is in `rtl/` today. It is the reference
for the other documents; where a report in this folder disagrees with it, this
file (and the code) is right.

## 1. Overview

Four RV32IMA + Zicsr cores, machine mode only, each a **single-issue
out-of-order** core with private L1 caches. The four L1 data caches are kept
coherent with the MESI protocol over a snooping bus, in front of a shared L2
cache and a 64 KB main memory. A small I/O block (UART, LEDs, 7-segment
display) sits beside the caches. The FPGA target is the Digilent Nexys A7-100T
(Xilinx XC7A100T) at 50 MHz.

"Single-issue" means one instruction is fetched, renamed, issued and committed
per cycle. The core is not superscalar.

```
   I/O (0x8000_0000: UART, LEDs, 7-segment)      one request at a time,
     |          |          |          |          round-robin, uncached
  +------+   +------+   +------+   +------+
  |core 0|   |core 1|   |core 2|   |core 3|     OoO core
  |L1I   |   |L1I   |   |L1I   |   |L1I   |     4 KB direct-mapped
  |L1D   |   |L1D   |   |L1D   |   |L1D   |     4 KB 2-way, MESI
  +--+---+   +--+---+   +--+---+   +--+---+
     |          |          |          |
  ===+==========+==========+==========+===     snooping bus: arbiter,
                     |                          snoop controller
                +----+----+
                | L2 16 KB|                     4-way, shared, write-back
                +----+----+
                +----+----+
                | memory  |                     64 KB block RAM
                +---------+
```

## 2. The core (`rtl/core`)

| Stage | Module | What it does |
|---|---|---|
| Fetch | `fetch_unit.v` | PC, and branch prediction from the instruction itself (pre-decode) |
| Decode | `decode_unit.v` | RV32I, M, A, Zicsr, FENCE; anything else raises an illegal-instruction trap |
| Rename | `rename_unit.v` | 32 architectural to 64 physical registers, free list |
| Dispatch | `riscv_ooo_core.v` | Allocates a ROB entry and an issue-queue entry |
| Issue | `issue_queue.v` | 8 entries, oldest ready first, wakeup from the CDB with a same-cycle bypass |
| Execute | `alu.v`, `branch_unit.v`, `muldiv_unit.v`, `load_store_unit.v` | One result per cycle on the common data bus (CDB) |
| Commit | `reorder_buffer.v` | 16 entries, in order; traps and branch mispredictions are taken here |

Sizes: 64 physical registers, 8-entry issue queue, 16-entry reorder buffer,
8-entry load/store queue.

**Branch prediction.** The I-cache returns the instruction in the cycle its
address is presented, so the predictor decodes it directly and needs no table
to learn what sits at a PC. JAL: target computed, always correct. Conditional
branches: 256 two-bit counters indexed by PC, target computed. Returns (JALR
through x1 or x5): 8-entry return address stack. Other JALR: 16-entry untagged
target table. The I-cache looks up the predicted next PC, so the core fetches
one instruction per cycle on hits.

**Misprediction recovery.** A wrong prediction is detected at execute and
repaired when the branch commits: the pipeline is flushed and fetch restarts
at the correct PC. There are no rename checkpoints.

**Loads and stores.** The load/store unit keeps an 8-entry queue tagged with
ROB indices. A load takes its value from the youngest older store that fully
covers it, waits if an older store overlaps it only in part or has no address
yet, and otherwise goes to the data cache. Stores go to the cache only after
they commit, in program order. Loads and stores issue in program order among
themselves; everything else issues around them. A finished load or
multiply/divide result is held until the CDB is free, so a load in flight
does not stop other instructions from issuing.

**Multiply and divide.** `muldiv_unit.v`: 33 x 33 signed multiplier (DSP
blocks), result after two cycles; restoring divider, 34 cycles.

**Serialized instructions.** CSR accesses, ECALL, EBREAK, MRET, traps, LR/SC,
the AMOs and FENCE are dispatched only into an empty ROB and run alone. They
therefore act as full fences.

**CSRs and traps** (`csr_file.v`). mstatus, misa, mie, mtvec (direct mode),
mscratch, mepc, mcause, mtval, mip, mhartid, mvendorid, marchid, mimpid,
mcycle and minstret (64-bit, with the user read-only aliases). Traps: illegal
instruction, ECALL, EBREAK. There are no interrupts.

## 3. Caches (`rtl/cache`)

All lines are 32 bytes (8 words).

| Cache | Size | Organisation | Storage |
|---|---|---|---|
| L1I, per core | 4 KB | Direct-mapped, 128 sets | Block RAM |
| L1D, per core | 4 KB | 2-way, 64 sets, LRU, MESI state per line | Block RAM data, LUT-RAM tags |
| L2, shared | 16 KB | 4-way, 128 sets, write-back | Block RAM data, LUT-RAM tags |

The L2 is **not inclusive** (evicting an L2 line does not invalidate L1
copies) and replaces the first invalid way, otherwise the way named by a
per-set pointer. That is correct because every L1D is snooped on every bus
transaction.

Known limits: an L1D hit is answered two cycles after the request, and the
cache handles one request at a time (blocking). L1I misses read main memory
directly and do not go through the L2 or the bus, and FENCE.I is a no-op, so
code written by stores is not seen by fetch (review bug 16, open).

## 4. Coherence (`rtl/coherence`)

MESI over an atomic snooping bus: `bus_arbiter.v` grants one L1D at a time
(round-robin), `snoop_controller.v` broadcasts the request to the other three
caches, collects their responses and talks to the L2. A cache holding the line
in M supplies the data (cache-to-cache transfer).

| State | Processor read | Processor write | Snooped BusRd | Snooped BusRdX / BusUpgr |
|---|---|---|---|---|
| I | BusRd, to E (nobody else has it) or S | BusRdX, to M | - | - |
| S | hit | BusUpgr, to M | S | I |
| E | hit | silent, to M | S | I |
| M | hit | hit | supply data, to S | supply data, to I |

Snoops have priority over the processor side inside a data cache. LR sets a
reservation on a line; the reservation is lost when a snoop invalidates the
line or another line is filled, and SC then fails. AMOs run in one cycle on a
line held in M or E.

Building with `CFG_MSI` never grants E (measurement only; see
`scripts/ablation.sh`).

## 5. Memory map

| Address | Contents |
|---|---|
| 0x0000_0000 to 0x0000_DFFF | Program: code, read-only data, data, bss (`sw/common/link.ld`) |
| 0x0000_E000 to 0x0000_EFFF | Stacks, 1 KB per hart |
| 0x8000_0000 | UART_TX (write a byte) |
| 0x8000_0004 | STATUS (bit 0: UART busy) |
| 0x8000_0008 | EXIT (result word; ends a simulation, 1 = pass) |
| 0x8000_000C | LEDS (16 board LEDs) |
| 0x8000_0010 | HEX (8-digit 7-segment display) |
| 0x8000_0014 | BOOT (cleared by reset, set by hart 0 after start-up) |

All harts reset to PC 0. Start-up code reads `mhartid`; hart 0 clears `.bss`
and sets BOOT, the others wait for it.

## 6. FPGA

`rtl/top/fpga_top.v` wraps `quad_core_top` with an MMCM (50 MHz core clock),
reset synchronisation, the UART pin, LEDs and the 7-segment driver.
Constraints and Vivado scripts are in `synth/`.

Yosys estimate for `fpga_top` (`make synth-fpga`), 2026-11-11:

| Resource | Used | XC7A100T | Share |
|---|---|---|---|
| LUT | 57,987 | 63,400 | 91.5% |
| FF | 27,826 | 126,800 | 22% |
| BRAM36 | 78.5 | 135 | 58% |
| DSP48 | 16 | 240 | 7% |

These are estimates from Yosys. There is no Vivado utilisation or timing
report yet, and the design has not run on a board.

## 7. Performance

Simulated on the four-core SoC (`make bench`), riscv-tests benchmarks, GCC
13.2 `-O2`. Dhrystone: 1.36 cycles per instruction, 0.75 DMIPS/MHz. The other
single-hart benchmarks run at 1.2 to 2.6 cycles per instruction. Numbers and
the per-feature ablation are in `results/`.

## 8. Verification

See the README for the commands. In short: block and core testbenches,
riscv-tests (rv32ui, rv32um, rv32ua) on one core and on the SoC, C programs on
the SoC and on a board-level model, a random coherence test with a reference
memory and a single-writer check every cycle, and a mutation check of that
test.
