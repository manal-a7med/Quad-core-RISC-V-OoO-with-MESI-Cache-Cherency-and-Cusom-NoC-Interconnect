`timescale 1ns / 1ps
// ============================================================================
// csr_file.v - Minimal machine-mode CSRs (RV32 Zicsr subset)
// ============================================================================
// Machine mode only, no interrupts. Implements what bare-metal multicore
// software and the benchmarks need: trap entry/return (mtvec, mepc, mcause,
// mtval, mstatus.MIE/MPIE), mscratch, mhartid, misa and the cycle/instret
// counters (machine and user read-only aliases).
//
// CSR instructions are serialized by the core (dispatched only when the ROB
// is empty), so reads and writes here are never speculative.
// ============================================================================

module csr_file (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  hartid,

    // Read port (combinational)
    input  wire [11:0] raddr,
    output reg  [31:0] rdata,
    output reg         rvalid,      // address implemented
    output wire        rreadonly,   // address is read-only (addr[11:10]==2'b11)

    // Write port
    input  wire        we,
    input  wire [11:0] waddr,
    input  wire [31:0] wdata,

    // Trap entry / return (from commit)
    input  wire        trap_enter,
    input  wire [31:0] trap_cause,
    input  wire [31:0] trap_pc,
    input  wire [31:0] trap_tval,
    input  wire        trap_mret,

    // Counters
    input  wire        instret_inc,

    output wire [31:0] mtvec_o,
    output wire [31:0] mepc_o
);

    localparam [11:0]
        A_MSTATUS  = 12'h300, A_MISA     = 12'h301, A_MIE      = 12'h304,
        A_MTVEC    = 12'h305, A_MCOUNTINH= 12'h320, A_MSCRATCH = 12'h340,
        A_MEPC     = 12'h341, A_MCAUSE   = 12'h342, A_MTVAL    = 12'h343,
        A_MIP      = 12'h344, A_MCYCLE   = 12'hB00, A_MINSTRET = 12'hB02,
        A_MCYCLEH  = 12'hB80, A_MINSTRETH= 12'hB82, A_CYCLE    = 12'hC00,
        A_INSTRET  = 12'hC02, A_CYCLEH   = 12'hC80, A_INSTRETH = 12'hC82,
        A_MVENDOR  = 12'hF11, A_MARCH    = 12'hF12, A_MIMP     = 12'hF13,
        A_MHARTID  = 12'hF14;

    reg        mie_bit, mpie_bit;
    reg [31:0] mie_r, mtvec, mscratch, mepc, mcause, mtval;
    reg [63:0] mcycle, minstret;

    assign mtvec_o   = mtvec;
    assign mepc_o    = mepc;
    assign rreadonly = (raddr[11:10] == 2'b11);

    wire [31:0] mstatus = {19'd0, 2'b11, 3'd0, mpie_bit, 3'd0, mie_bit, 3'd0}; // MPP = M

    always @(*) begin
        rvalid = 1'b1;
        case (raddr)
            A_MSTATUS:   rdata = mstatus;
            A_MISA:      rdata = 32'h40001101;          // RV32IMA
            A_MIE:       rdata = mie_r;
            A_MTVEC:     rdata = mtvec;
            A_MCOUNTINH: rdata = 32'd0;
            A_MSCRATCH:  rdata = mscratch;
            A_MEPC:      rdata = mepc;
            A_MCAUSE:    rdata = mcause;
            A_MTVAL:     rdata = mtval;
            A_MIP:       rdata = 32'd0;
            A_MCYCLE,  A_CYCLE:    rdata = mcycle[31:0];
            A_MCYCLEH, A_CYCLEH:   rdata = mcycle[63:32];
            A_MINSTRET, A_INSTRET:   rdata = minstret[31:0];
            A_MINSTRETH, A_INSTRETH: rdata = minstret[63:32];
            A_MVENDOR, A_MARCH, A_MIMP: rdata = 32'd0;
            A_MHARTID:   rdata = {30'd0, hartid};
            default: begin rdata = 32'd0; rvalid = 1'b0; end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mie_bit  <= 1'b0; mpie_bit <= 1'b0;
            mie_r    <= 32'd0; mtvec <= 32'd0; mscratch <= 32'd0;
            mepc     <= 32'd0; mcause <= 32'd0; mtval <= 32'd0;
            mcycle   <= 64'd0; minstret <= 64'd0;
        end else begin
            mcycle <= mcycle + 64'd1;
            if (instret_inc) minstret <= minstret + 64'd1;

            if (trap_enter) begin
                mepc     <= {trap_pc[31:2], 2'b00};
                mcause   <= trap_cause;
                mtval    <= trap_tval;
                mpie_bit <= mie_bit;
                mie_bit  <= 1'b0;
            end else if (trap_mret) begin
                mie_bit  <= mpie_bit;
                mpie_bit <= 1'b1;
            end else if (we) begin
                case (waddr)
                    A_MSTATUS:   begin mie_bit <= wdata[3]; mpie_bit <= wdata[7]; end
                    A_MIE:       mie_r    <= wdata;
                    A_MTVEC:     mtvec    <= {wdata[31:2], 2'b00};   // direct mode only
                    A_MSCRATCH:  mscratch <= wdata;
                    A_MEPC:      mepc     <= {wdata[31:2], 2'b00};
                    A_MCAUSE:    mcause   <= wdata;
                    A_MTVAL:     mtval    <= wdata;
                    A_MCYCLE:    mcycle[31:0]    <= wdata;
                    A_MCYCLEH:   mcycle[63:32]   <= wdata;
                    A_MINSTRET:  minstret[31:0]  <= wdata;
                    A_MINSTRETH: minstret[63:32] <= wdata;
                    default: ;
                endcase
            end
        end
    end

endmodule
