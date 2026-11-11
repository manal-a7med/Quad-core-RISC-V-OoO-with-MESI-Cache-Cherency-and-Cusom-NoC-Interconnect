# 4-Core RISC-V Out-of-Order Processor with MESI Cache Coherence

## Architecture Documentation

### 1. Overview

This project implements a **quad-core RISC-V (RV32I) out-of-order superscalar processor** with **MESI snooping cache coherence protocol**, fully synthesizable in Verilog for FPGA deployment.

### 2. Processor Core Architecture

Each core implements a 6-stage out-of-order pipeline:

```
┌─────────┐   ┌─────────┐   ┌─────────┐   ┌──────────┐   ┌──────────┐   ┌─────────┐
│  FETCH   │──>│  DECODE  │──>│  RENAME  │──>│  ISSUE   │──>│ EXECUTE  │──>│ COMMIT  │
│  (IF)    │   │  (ID)    │   │  (RN)    │   │  QUEUE   │   │  (EX)    │   │  (ROB)  │
│          │   │          │   │  RAT     │   │  Res.Stn │   │ ALU/BRU  │   │         │
│  BTB     │   │  RV32I   │   │  Free    │   │  8-entry │   │  LSU     │   │16-entry │
│  16-ent  │   │  Decoder │   │  List    │   │  Wakeup  │   │          │   │Circular │
└─────────┘   └─────────┘   └─────────┘   └──────────┘   └──────────┘   └─────────┘
                                                  ↑              │
                                                  └──── CDB ─────┘
                                            (Common Data Bus broadcast)
```

#### Key OoO Features:
- **Register Renaming**: 32 architectural → 64 physical registers via RAT
- **Reservation Stations**: 8-entry issue queue with operand wakeup via CDB
- **Reorder Buffer**: 16-entry circular ROB for in-order commit
- **Branch Prediction**: 16-entry BTB with misprediction recovery
- **Load/Store Queue**: 8-entry LSQ with store-to-load forwarding
- **Speculative Execution**: Instructions execute out-of-order, commit in-order

### 3. Cache Hierarchy

```
Per Core:
  ┌─────────────┐  ┌──────────────┐
  │ L1 I-Cache  │  │  L1 D-Cache  │
  │ 4KB Direct  │  │  4KB 2-Way   │
  │ 128 sets    │  │  64 sets     │
  │ Read-only   │  │  MESI states │
  └─────────────┘  └──────────────┘
                          │
Shared:              ┌────┴────┐
                     │L2 Cache │
                     │16KB 4-Way│
                     │128 sets │
                     │Inclusive │
                     └────┬────┘
                          │
                     ┌────┴────┐
                     │  Main   │
                     │ Memory  │
                     │  64KB   │
                     └─────────┘
```

**Cache Line**: 32 bytes (8 words, 256 bits)
**Write Policy**: Write-back, write-allocate
**Replacement**: LRU (pseudo-LRU for 4-way L2)

### 4. MESI Cache Coherence Protocol

#### State Definitions:
| State | Meaning | Dirty? | Shared? |
|-------|---------|--------|---------|
| **M** (Modified) | Only copy, dirty | Yes | No |
| **E** (Exclusive) | Only copy, clean | No | No |
| **S** (Shared) | Clean, others may have copies | No | Yes |
| **I** (Invalid) | Not present | N/A | N/A |

#### State Transition Table:

| Current | Processor Event | Next State | Bus Action |
|---------|----------------|------------|------------|
| I | PrRd | S or E | BusRd |
| I | PrWr | M | BusRdX |
| S | PrRd | S | — (hit) |
| S | PrWr | M | BusUpgr |
| E | PrRd | E | — (hit) |
| E | PrWr | M | — (silent) |
| M | PrRd | M | — (hit) |
| M | PrWr | M | — (hit) |

| Current | Snoop Event | Next State | Response |
|---------|-------------|------------|----------|
| M | BusRd | S | Flush data |
| M | BusRdX | I | Flush data |
| E | BusRd | S | — |
| E | BusRdX | I | — |
| S | BusRd | S | — |
| S | BusRdX | I | — |
| S | BusUpgr | I | — |

#### Snooping Architecture:
- **Bus Arbiter**: Round-robin for 4 cores
- **Snoop Controller**: Broadcasts snoops, collects responses
- **Cache-to-Cache Transfer**: When snooped core has Modified line, it supplies data directly

### 5. Memory Map

| Address Range | Description |
|--------------|-------------|
| 0x0000_0000 - 0x0000_FFFF | Main Memory (64KB) |
| 0x0000_0000 - 0x0000_0FFF | Code Section |
| 0x0000_1000 - 0x0000_1FFF | Data Section |

### 6. Supported Instructions (RV32I)

| Type | Instructions |
|------|-------------|
| R-type | ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU |
| I-type | ADDI, ANDI, ORI, XORI, SLTI, SLTIU, SLLI, SRLI, SRAI |
| Load | LB, LH, LW, LBU, LHU |
| Store | SB, SH, SW |
| Branch | BEQ, BNE, BLT, BGE, BLTU, BGEU |
| Jump | JAL, JALR |
| Upper | LUI, AUIPC |

### 7. FPGA Resource Estimates

| Resource | Estimated Per Core | Total (4 cores) |
|----------|-------------------|-----------------|
| LUTs | ~3,000 | ~12,000 |
| FFs | ~2,500 | ~10,000 |
| BRAM (36K) | 3-4 | 14-18 |
| DSP | 0 | 0 |

**Target FPGA**: Xilinx Artix-7 (XC7A100T) or larger
**Target Frequency**: 25-50 MHz

### 8. Simulation & Testing

Run tests with Icarus Verilog:
```batch
cd sim
run_all_tests.bat
```

View waveforms with GTKWave:
```batch
gtkwave mesi_coherence.vcd
```

### 9. Synthesis (Vivado)

1. Create Vivado project
2. Add all RTL sources from `rtl/` directory
3. Set `fpga_top.v` as top module
4. Add `synth/constraints.xdc`
5. Run Synthesis → Implementation → Generate Bitstream
