`timescale 1ns/1ps
// Single-core ISA test harness: 64 KB unified memory, 1-cycle handshake.
// Loads +hex=<file> (word-per-line), runs until the program writes TOHOST
// (0xFFF0) or +timeout cycles pass. Prints "RESULT PASS" or "RESULT FAIL".
// With +trace, prints one line per commit for the pipeline viewer.
module tb_isa;
  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  wire [31:0] ia; reg [31:0] ir; wire ireq; reg iack;
  wire [31:0] da, dw; reg [31:0] dr; wire dreq, dwr; reg dack; wire [2:0] dmt;

  riscv_ooo_core dut(.clk(clk), .rst_n(rst_n), .core_id(2'b0),
    .icache_addr(ia), .icache_rdata(ir), .icache_req(ireq), .icache_ack(iack),
    .dcache_addr(da), .dcache_wdata(dw), .dcache_rdata(dr), .dcache_req(dreq),
    .dcache_wr(dwr), .dcache_ack(dack), .dcache_mem_type(dmt));

  reg [31:0] mem [0:16383];
  reg [1023:0] hexfile;
  integer k, cycles, timeout, tohost_seen;
  reg trace;

  initial begin
    for (k = 0; k < 16384; k = k + 1) mem[k] = 32'h00000013;
    if (!$value$plusargs("hex=%s", hexfile)) begin
      $display("tb_isa: pass +hex=<file>"); $finish;
    end
    $readmemh(hexfile, mem);
    if (!$value$plusargs("timeout=%d", timeout)) timeout = 20000;
    trace = $test$plusargs("trace");
  end

  always @(*) begin iack = ireq; ir = mem[ia[15:2]]; end

  always @(posedge clk) begin
    dack <= 1'b0;
    if (rst_n && dreq && !dack) begin
      dack <= 1'b1;
      if (dwr) begin
        case (dmt)
          3'd0: mem[da[15:2]][da[1:0]*8 +: 8]  <= dw[7:0];
          3'd1: mem[da[15:2]][da[1]*16 +: 16]  <= dw[15:0];
          default: mem[da[15:2]] <= dw;
        endcase
        if (da[15:0] == 16'hFFF0) begin
          if (dw == 32'd1) $display("RESULT PASS cycles=%0d", cycles);
          else $display("RESULT FAIL test=%0d cycles=%0d", dw >> 1, cycles);
          $finish;
        end
      end else
        dr <= mem[da[15:2]] >> (da[1:0] * 8);
    end
  end

  // Commit trace: cycle, ROB index, architectural rd, value
  always @(posedge clk) if (trace && dut.rob_commit_valid)
    $display("COMMIT %0d rob=%0d rd=x%0d val=%h", cycles, dut.rob_commit_idx,
             dut.u_rob.commit_arch_rd, dut.u_rob.commit_result);

  initial begin
    cycles = 0;
    #22 rst_n = 1;
    forever begin
      @(posedge clk); cycles = cycles + 1;
      if (cycles >= timeout) begin
        $display("RESULT TIMEOUT cycles=%0d", cycles); $finish;
      end
    end
  end
endmodule
