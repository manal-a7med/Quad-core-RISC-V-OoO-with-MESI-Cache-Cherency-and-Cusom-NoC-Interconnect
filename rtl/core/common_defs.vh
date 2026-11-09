// ============================================================================
// common_defs.vh — Global Parameters for RISC-V OoO Quad-Core Processor
// ============================================================================
// This file defines all shared parameters, opcodes, and type encodings
// used across the entire processor design.
// ============================================================================

`ifndef COMMON_DEFS_VH
`define COMMON_DEFS_VH

// ----------------------------------------------------------------------------
// Data Widths
// ----------------------------------------------------------------------------
`define DATA_WIDTH        32
`define ADDR_WIDTH        32
`define INSTR_WIDTH       32
`define REG_ADDR_WIDTH     5    // 32 architectural registers

// ----------------------------------------------------------------------------
// Core Identification
// ----------------------------------------------------------------------------
`define NUM_CORES          4
`define CORE_ID_WIDTH      2

// ----------------------------------------------------------------------------
// OoO Pipeline Parameters
// ----------------------------------------------------------------------------
`define PHYS_REG_COUNT    64    // Physical register file size
`define PHYS_REG_WIDTH     6    // log2(64)
`define ROB_DEPTH         16    // Reorder buffer entries
`define ROB_IDX_WIDTH      4    // log2(16)
`define IQ_DEPTH           8    // Issue queue (reservation station) entries
`define IQ_IDX_WIDTH       3    // log2(8)
`define LSQ_DEPTH          8    // Load/Store queue depth
`define LSQ_IDX_WIDTH      3    // log2(8)
`define BTB_ENTRIES        16   // Branch Target Buffer entries
`define BTB_IDX_WIDTH      4    // log2(16)
`define FREE_LIST_DEPTH   32    // Free physical register list

// ----------------------------------------------------------------------------
// RV32I Opcode Encodings (bits [6:0])
// ----------------------------------------------------------------------------
`define OP_LUI        7'b0110111
`define OP_AUIPC      7'b0010111
`define OP_JAL        7'b1101111
`define OP_JALR       7'b1100111
`define OP_BRANCH     7'b1100011
`define OP_LOAD       7'b0000011
`define OP_STORE      7'b0100011
`define OP_IMM        7'b0010011
`define OP_REG        7'b0110011
`define OP_FENCE      7'b0001111
`define OP_SYSTEM     7'b1110011

// ----------------------------------------------------------------------------
// ALU Operation Codes
// ----------------------------------------------------------------------------
`define ALU_ADD       4'b0000
`define ALU_SUB       4'b0001
`define ALU_AND       4'b0010
`define ALU_OR        4'b0011
`define ALU_XOR       4'b0100
`define ALU_SLL       4'b0101
`define ALU_SRL       4'b0110
`define ALU_SRA       4'b0111
`define ALU_SLT       4'b1000
`define ALU_SLTU      4'b1001
`define ALU_PASS_B    4'b1010  // Pass operand B (for LUI)
`define ALU_ADD_PC    4'b1011  // PC + immediate (for AUIPC)

// ----------------------------------------------------------------------------
// Branch Comparison Types (funct3)
// ----------------------------------------------------------------------------
`define BR_BEQ        3'b000
`define BR_BNE        3'b001
`define BR_BLT        3'b100
`define BR_BGE        3'b101
`define BR_BLTU       3'b110
`define BR_BGEU       3'b111

// ----------------------------------------------------------------------------
// Load/Store Types (funct3)
// ----------------------------------------------------------------------------
`define MEM_BYTE      3'b000
`define MEM_HALF      3'b001
`define MEM_WORD      3'b010
`define MEM_BYTE_U    3'b100
`define MEM_HALF_U    3'b101

// ----------------------------------------------------------------------------
// Functional Unit Types
// ----------------------------------------------------------------------------
`define FU_ALU        2'b00
`define FU_BRANCH     2'b01
`define FU_LOAD       2'b10
`define FU_STORE      2'b11

// ----------------------------------------------------------------------------
// Exception Codes
// ----------------------------------------------------------------------------
`define EXC_NONE           4'b0000
`define EXC_ILLEGAL_INSTR  4'b0001
`define EXC_MISALIGNED     4'b0010
`define EXC_BREAKPOINT     4'b0011

// ----------------------------------------------------------------------------
// Pipeline Control Signals
// ----------------------------------------------------------------------------
`define PIPELINE_FLUSH     1'b1
`define PIPELINE_NORMAL    1'b0

`endif // COMMON_DEFS_VH
