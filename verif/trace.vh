// Pipeline event trace for the pipeline viewer (scripts/viz).
// Include inside a testbench module that instantiates riscv_ooo_core as `dut`.
// Enabled with +trace. One line per event:
//   T D <cycle> <rob> <pc> <instr>   dispatch (ROB allocate)
//   T I <cycle> <rob>                issue from IQ
//   T C <cycle> <rob>                complete (CDB write)
//   T R <cycle> <rob>                retire (commit)
//   T F <cycle>                      pipeline flush
reg        tr_on;
integer    tr_cyc;
initial begin tr_on = $test$plusargs("trace"); tr_cyc = 0; end
always @(posedge clk) begin
  tr_cyc <= tr_cyc + 1;
  if (tr_on && dut.rst_n) begin
    if (dut.dispatch_en)      $display("T D %0d %0d %h %h", tr_cyc, dut.rob_alloc_idx, dut.fd_pc, dut.fd_instr);
    if (dut.iq_issue_valid)   $display("T I %0d %0d", tr_cyc, dut.iq_rob_idx);
    if (dut.rob_complete_en)  $display("T C %0d %0d", tr_cyc, dut.cdb_rob_idx);
    if (dut.rob_commit_valid) $display("T R %0d %0d", tr_cyc, dut.rob_commit_idx);
    if (dut.pipeline_flush)   $display("T F %0d", tr_cyc);
  end
end
