# Architecture

This file describes the design as it is in `rtl/` today. It is the reference
for the other documents; where a report in this folder disagrees with it, this
file (and the code) is right.

## 1. Overview

Four RV32IMA + Zicsr cores, machine mode only, each a **single-issue
out-of-order** core with private L1 caches. The four L1 data caches are kept
coherent with the MESI protocol over a snooping bus (or, built with `NOC=1`,
over a 2x2 mesh network with a directory; section 4.2), in front of a shared
L2 cache and a 64 KB main memory. A small I/O block (UART, LEDs, 7-segment
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
the AMOs, FENCE and FENCE.I are dispatched only into an empty ROB and run alone. They
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

An L1I miss is a BusRd on the coherence bus (through the bus port of the same
core's L1D, which waits meanwhile). All four L1Ds are snooped, the core's own
included, so the fetched line is the newest copy wherever it is: an L1D, the
L2 or memory. The L1I is not a MESI participant: it keeps its copy when a
store later changes the line. FENCE.I is what brings it up to date. It waits
until every older store of the hart has reached its L1D, empties the hart's
L1I, and restarts fetch at the next instruction. As the RISC-V specification
says, it affects only the hart that executes it.

Known limits: an L1D hit is answered two cycles after the request, and the
cache handles one request at a time (blocking).

## 4. Coherence (`rtl/coherence`)

MESI over an atomic snooping bus: `bus_arbiter.v` grants one core's bus port at a time
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

### 4.1 The L1 coherence port

Each L1 data cache talks to the rest of the memory system through one port
with a request half (BusRd / BusRdX / BusUpgr / BusFlush, acknowledged with
the line and a shared bit) and a probe half (the snoop port: the interconnect
looks a line up and the cache answers the next cycle). The contract is
written out in `rtl/coherence/coh_port.vh`. The core's I-cache misses use the
same port (a BusRd that also probes the core's own L1D). Two interconnects
sit behind this port, chosen when the system is built:

| Build | Module | How a request reaches the other caches |
|---|---|---|
| default | `rtl/coherence/bus_interconnect.v` | snooping bus (above): broadcast to every cache |
| `NOC=1` | `rtl/noc/noc_interconnect.v` | 2x2 mesh network + directory: sent only to the caches that hold the line |

Both use the same L1 caches, the same L2, memory and I/O, so any difference
in a result comes from the interconnect alone. The bus build is unchanged
cycle for cycle by this split.

### 4.2 NoC + directory build (`NOC=1`, `rtl/noc`)

```
   node 2 --- node 3        each node: one core tile (core, L1I, L1D,
     |          |           network interface) and a router per network
   node 0 --- node 1        NOC_BANKS=1: directory home at node 0
                            NOC_BANKS=4: a home at every node
```

* **Networks.** Three separate 2x2 meshes, one per message class, so a
  message can never wait behind one of another class (no protocol
  deadlock): REQ (core to home: GetS, GetM, Upgrade, PutM), RSP (core to
  home: probe answers; core to core: a line sent by its owner straight to
  the requester) and OUT (home to core: probes, grants and lines). Grants
  and probes share OUT so that they reach a core in the order the home sent
  them. At each node the RSP exit is split: lines go to the core, answers
  to the home.
* **Routers** (`noc_router.v`): 3 ports (local, X neighbour, Y neighbour),
  XY routing, wormhole switching, a 2-flit buffer per input, round-robin
  output allocation, valid/ready flow control. A flit is 64 bits by default
  (`NOC_FLIT=128` or `256` for wider links); a packet is a header flit plus,
  when it carries a 32-byte line, 4, 2 or 1 data flits.
* **Network interface** (`noc_ni.v`, one per core): turns an L1 request into
  a packet to the line's home, a grant into the L1 acknowledge, and a probe
  into a snoop of the L1 whose answer goes back to the home. A forwarding
  probe also makes it send the line to the requester. A grant that says
  "the line follows" makes it wait for that line; probes for the same line
  wait too, because they belong to later requests. After a grant it holds
  any probe back for three cycles so the L1 can finish the access it
  fetched the line for (without this, two cores storing to one line take it
  from each other forever).
* **Directory home** (`dir_home.v`): keeps a copy of every L1D tag with a
  state (I, S, or EM = only copy, clean or dirty), 4 cores x 128 entries.
  A request carries the L1 way it fills, so the copy stays exact and no
  inclusive L2 is needed (an inclusive 16 KB L2 would have to hold all
  16 KB of the four L1Ds).

**Several lines at once.** A core has at most one request outstanding, so
the home has one request slot and one transaction engine per core. Engines
on different lines run at the same time; a request for a line another engine
is working on waits for it, so each line still sees its requests one at a
time. The engines share the directory, the OUT sender and the L2 port, each
given round-robin. The directory is looked up when an engine starts (whom to
probe) and again when it grants (what to write), so a grant of another line
in the same set in between is seen.

| Request | Probes sent to | Data from | Grant |
|---|---|---|---|
| GetS (BusRd), another cache owns it | the owner, naming the requester | the owner, straight to the requester (the home writes a dirty line to L2 too); L2 if the owner had no copy | S, sent with the probe |
| GetS, no owner | none | L2 | S if another copy stays, else E |
| GetS from the I-cache | the owner, including the requester's own L1D | the owner's answer, else L2 | the line |
| GetM (BusRdX) | the owner (forwarding, as for GetS), or every sharer | the owner, or L2 (read while the sharers are invalidated) | M |
| Upgrade (BusUpgr) | every other holder (invalidate) | none | ack; if the requester lost the line meanwhile it is served as GetM |
| PutM (BusFlush) | none | written to L2 after the ack, if the sender still owns the line | ack |

**Victims.** A fill overwrites the directory entry of the line the core had
in that place, but the core keeps that line until the fill arrives. The home
therefore keeps the old entry as the core's "victim" until the core's next
request reaches it (sent only after the fill): until then it counts as a
copy and probes for it go to that core. A line written back with PutM is
kept the same way, because the L1 drops it only at its next fill. Without this, another core could be
given E or M while the old copy still sat in the first core's cache (found
by the random test, now a mutant).

With `NOC_BANKS=4` each node is home for a quarter of the lines (line
address bits [6:5]); the four homes share the one L2 through a round-robin
port arbiter in `noc_interconnect.v`.

**Assertions.** In simulation (iverilog and Verilator) the NoC blocks check
their own protocol and stop the run on a failure (`ERROR SVA ...`):

| Where | Check |
|---|---|
| home | after every grant at most one cache owns the line, and an owner is the only holder (single writer) |
| home | no two engines on the same line; one request per core at a time |
| home | probe answers come only from probed cores, to the engine on that line; a grant waits for every answer, except a forwarded one, whose transaction ends only then (no lost answers) |
| home | a transaction ends within 5000 cycles |
| network interface | a grant (or the line after it) answers a request that was sent, for the same line; every request is granted within 20000 cycles |
| router | the flits of a packet leave an output one after another, never mixed with another packet; a waiting flit is not dropped or changed; a packet leaves the mesh only at its destination |

The directory mutants of `make coh-mutants NOC=1` are caught by the
single-writer assertion at the grant, before any cache misbehaves.

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

Yosys estimate for `fpga_top` (`make synth-fpga`), 2026-11-12:

| Resource | Used | XC7A100T | Share |
|---|---|---|---|
| LUT | 56,436 | 63,400 | 89.0% |
| FF | 26,061 | 126,800 | 21% |
| BRAM36 | 78.5 | 135 | 58% |
| DSP48 | 16 | 240 | 7% |

These are estimates from Yosys. There is no Vivado utilisation or timing
report yet, and the design has not run on a board.

## 7. Performance

Simulated on the four-core SoC (`make bench`), riscv-tests benchmarks, GCC
13.2 `-O2`. Dhrystone: 1.36 cycles per instruction, 0.75 DMIPS/MHz. The other
single-hart benchmarks run at 1.2 to 2.6 cycles per instruction. Numbers and
the per-feature ablation are in `results/`.

**Bus vs NoC** (same cores, L1s, L2 and memory; `make compare-ic`,
`make traffic`, numbers in `results/2026-11-13/`):

* A single miss takes longer on the NoC: about 14 to 16 cycles at the CPU
  port with no load, against 9 on the bus, because a request and its line
  each cross the mesh as packets. Benchmarks that run on one hart and miss
  a lot lose most (rsort runs at 0.70 to 0.83 of the bus speed, memcpy at
  0.89 to 0.94); the others are within 6 %.
* When the four cores miss on different lines at the same time, the NoC
  carries more: the bus stops at about 170 accesses per 1000 cycles, the
  NoC with a home per node and 256-bit links reaches about 260 (1.5x).
* When cores share lines, the NoC with 256-bit links now also carries more
  than the bus under heavy load (about 200 against 173), thanks to the
  owner sending the line straight to the requester and the home working on
  several lines at once. At light load the bus is still quicker (9 against
  17 cycles), because a probe and its answer cross the mesh while the bus
  snoops everyone in one cycle.
* On one hot set (two lines) the bus stays ahead: about 270 against 190
  accesses per 1000 cycles, since every access there is a probe round.
* The two multi-thread benchmarks: mt-matmul runs 2 to 5 % faster than on
  the bus on every NoC build, mt-vvadd at 0.86 to 0.92 of the bus speed.

## 8. Verification

See the README for the commands. In short: block and core testbenches,
riscv-tests (rv32ui, rv32um, rv32ua) on one core and on the SoC, C programs on
the SoC and on a board-level model, a random coherence test with a reference
memory and a single-writer check every cycle, and a mutation check of that
test.
