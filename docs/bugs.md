# Bugs found and fixed

Bugs 1 to 18 were found by a design review of the imported code (11 Nov 2026):
"C" = confirmed by the repro testbench `review/tb_repro.v` (`make sim-repro`),
"R" = found by reading the code. Bugs 19 to 24 were found later by tests.
All 24 are fixed or shown to be unreachable.

## Core

| # | Bug | Fixed in |
|---|---|---|
| 1 | C. JAL executed as JALR: the target used immediate bits as a register | P1 |
| 2 | C. AUIPC added a register to `pc + imm` | P1 |
| 3 | C. A load could forward from a *younger* store | P1 |
| 4 | C. Store-to-load forwarding ignored the access size and sign extension | P1 |
| 5 | R. Store commit marked the wrong LSQ slot, so a speculative store could reach memory | P1 |
| 6 | R. Loads went to the cache in slot order, so two loads of one address could swap (breaks CoRR) | P1 |
| 7 | R. A flush during an outstanding load let the stale result reach a reallocated register | P1 |
| 8 | R. The issue-queue age counter saturated at 15, breaking the oldest-first pick | P1 |
| 9 | R. Illegal instructions, FENCE, ECALL, EBREAK and CSR ops ran as NOPs; traps looped forever | P1 |
| 10 | R. An I-cache fill racing a flush returned the old address's instruction | P2 |
| 11 | R. A latch was inferred on `older_store_pending` | P1 |
| 12 | R. One load in flight froze all issue | P4 |

## Caches and coherence

| # | Bug | Fixed in |
|---|---|---|
| 13 | R. A CPU write hit and a snoop on the same line in one cycle left a dirty line marked S (lost write) | P2 |
| 14 | R. Loose request/acknowledge handshake between the LSU and the D-cache | P2 to P4 |
| 15 | R. Snoop de-duplication could drop a second transaction to the same line | Unreachable: `snoop_valid` always drops between transactions; covered by `make coh-random` |
| 16 | R. I-cache misses bypassed the L2 and coherence, so code written by a store was not seen | P3 (with FENCE.I) |
| 17 | R. The L2 is not inclusive and uses a rotating replacement pointer, unlike the old docs | Not a bug; documented in [architecture.md](architecture.md) |
| 18 | R. `===` (simulation-only equality) in `l1_dcache.v` | 12 Nov (crosscheck) |

## Found later by tests

| # | Bug | Found by | Fixed in |
|---|---|---|---|
| 19 | Committed stores could reach the D-cache out of program order | 24 KB memory stress test | P2 |
| 20 | A D-cache acknowledge in the same cycle as a flush was lost, so the LSU waited forever | Four-core C programs | P2 |
| 21 | Two loads of the same address could be performed out of order in a corner case (CoRR) | Litmus tests | P3 |
| 22 | A store issued into a full LSQ was silently dropped | qsort and rsort timing out | P4 |
| 23 | A load waiting for older stores deadlocked while issue was frozen | `sw/memstress` | P4 |
| 24 | Bus build: a snoop could take a dirty victim line while the L1 waited to write it back; the late write-back then put old data over newer data in the L2 | `make coh-random` with more counter traffic, and the coverage bin for this case | 21 Nov (the L1 skips the write-back when the line is no longer M; mutant `wb_after_snoop`) |

Bugs in the new NoC code were found and fixed while it was written; the
mutation tests (`make coh-mutants`) show that the checks catch the important
ones.
