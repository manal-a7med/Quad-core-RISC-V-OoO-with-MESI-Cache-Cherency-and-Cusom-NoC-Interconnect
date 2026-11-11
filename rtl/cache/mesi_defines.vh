// ============================================================================
// mesi_defines.vh — MESI Cache Coherence Protocol Definitions
// ============================================================================
// Defines MESI states, bus transaction types, cache parameters, and
// coherence-related constants used across the cache and coherence modules.
// ============================================================================

`ifndef MESI_DEFINES_VH
`define MESI_DEFINES_VH

// ----------------------------------------------------------------------------
// MESI State Encodings (2-bit per cache line)
// ----------------------------------------------------------------------------
`define MESI_INVALID    2'b00   // I - Line not present / stale
`define MESI_SHARED     2'b01   // S - Clean copy, other caches may have copies
`define MESI_EXCLUSIVE  2'b10   // E - Clean copy, only copy in system
`define MESI_MODIFIED   2'b11   // M - Dirty copy, only copy in system

`define MESI_STATE_WIDTH 2

// ----------------------------------------------------------------------------
// Bus Transaction Types (from requesting cache controller)
// ----------------------------------------------------------------------------
`define BUS_NONE        3'b000  // No bus transaction
`define BUS_READ        3'b001  // BusRd  - Read miss, need clean copy
`define BUS_READX       3'b010  // BusRdX - Read-exclusive (write miss)
`define BUS_UPGR        3'b011  // BusUpgr - Upgrade S->M (write hit on Shared)
`define BUS_FLUSH       3'b100  // Flush/Writeback - Write dirty line to memory
`define BUS_INVAL       3'b101  // Invalidate - Force invalidation

`define BUS_CMD_WIDTH    3

// ----------------------------------------------------------------------------
// Snoop Response Types (from snooped cache controllers)
// ----------------------------------------------------------------------------
`define SNOOP_NONE      2'b00   // No response (line not present)
`define SNOOP_HIT       2'b01   // Line present, clean
`define SNOOP_HITM      2'b10   // Line present, modified (will supply data)
`define SNOOP_ACK       2'b11   // Acknowledge invalidation

`define SNOOP_RESP_WIDTH 2

// ----------------------------------------------------------------------------
// Cache Parameters — L1 Data Cache
// ----------------------------------------------------------------------------
`define L1D_SIZE_BYTES     4096  // 4 KB
`define L1D_LINE_SIZE       32   // 32 bytes per cache line
`define L1D_NUM_WAYS         2   // 2-way set associative
`define L1D_NUM_SETS        64   // 4096 / (32 * 2) = 64 sets
`define L1D_SET_IDX_WIDTH    6   // log2(64)
`define L1D_LINE_OFFSET      5   // log2(32) = 5 bits for byte offset
`define L1D_TAG_WIDTH       21   // 32 - 6 - 5 = 21 bits for tag
`define L1D_WORDS_PER_LINE   8   // 32 bytes / 4 bytes per word

// ----------------------------------------------------------------------------
// Cache Parameters — L1 Instruction Cache
// ----------------------------------------------------------------------------
`define L1I_SIZE_BYTES     4096  // 4 KB
`define L1I_LINE_SIZE       32   // 32 bytes per cache line
`define L1I_NUM_WAYS         1   // Direct-mapped
`define L1I_NUM_SETS       128   // 4096 / 32 = 128 sets
`define L1I_SET_IDX_WIDTH    7   // log2(128)
`define L1I_LINE_OFFSET      5   // log2(32) = 5 bits
`define L1I_TAG_WIDTH       20   // 32 - 7 - 5 = 20 bits

// ----------------------------------------------------------------------------
// Cache Parameters — L2 Shared Cache
// ----------------------------------------------------------------------------
`define L2_SIZE_BYTES     16384  // 16 KB
`define L2_LINE_SIZE         32  // 32 bytes per line
`define L2_NUM_WAYS           4  // 4-way set associative
`define L2_NUM_SETS         128  // 16384 / (32 * 4) = 128 sets
`define L2_SET_IDX_WIDTH      7  // log2(128)
`define L2_LINE_OFFSET        5  // log2(32)
`define L2_TAG_WIDTH         20  // 32 - 7 - 5 = 20 bits
`define L2_WORDS_PER_LINE     8  // 32 bytes / 4 bytes

// ----------------------------------------------------------------------------
// Main Memory Parameters
// ----------------------------------------------------------------------------
`define MEM_SIZE_BYTES    65536  // 64 KB for simulation
`define MEM_ADDR_BITS       16  // log2(65536)
`define MEM_LATENCY          5  // Cycles latency for memory access

// ----------------------------------------------------------------------------
// Bus Arbiter Parameters
// ----------------------------------------------------------------------------
`define BUS_DATA_WIDTH      256  // Full cache line width (32 bytes = 256 bits)
`define BUS_ADDR_WIDTH       32
`ifndef ADDR_WIDTH
`define ADDR_WIDTH           32
`endif

`endif // MESI_DEFINES_VH
