// ============================================================================
// coh_port.vh - the L1 coherence port: the contract between an L1 data cache
// and the interconnect (bus_interconnect, or noc_interconnect with NOC=1)
// ============================================================================
// Each core has one port with two halves. All signals are per core; in the
// interconnect modules they are flattened, core n in bits [n*W +: W].
//
// Request half (the L1 asks for a line, or writes one back)
//   l1_req     held high until l1_ack; may start again the cycle after ack
//   l1_cmd     `BUS_READ   (GetS: a readable copy, E if nobody else has one)
//              `BUS_READX  (GetM: a writable copy, others invalidated)
//              `BUS_UPGR   (Upgrade S -> M; the reply may carry data, see below)
//              `BUS_FLUSH  (PutM: write a dirty line back)
//   l1_addr    line address (bits [4:0] zero)
//   l1_wdata   the line, for `BUS_FLUSH
//   l1_ifetch  request comes from the I-cache (a `BUS_READ that must also see
//              the requester's own L1D, and gives no cache state)
//   l1_ack     one cycle: transaction complete
//   l1_rdata   the line, valid with l1_ack (READ, READX; UPGR if the L1 lost
//              its copy while waiting, which it detects itself)
//   l1_shared  valid with l1_ack: another L1 keeps a copy (READ -> S, else E)
//   l1_busy    the interconnect is still finishing this port's transaction
//              (high from the start of service until at least the cycle
//              after l1_ack); the I-cache only takes the port when it is low
//
// Probe half (the interconnect looks into the L1; the L1 never refuses)
//   pr_valid   one cycle per probe (the L1 also ignores a repeat of the same
//              probe in consecutive cycles)
//   pr_cmd     `BUS_READ  -> M/E become S, data returned
//              `BUS_READX -> line invalidated, data returned if it was M
//              `BUS_UPGR / `BUS_INVAL -> line invalidated
//   pr_addr    line address
//   pr_resp    in the cycle after pr_valid: `SNOOP_NONE (no copy),
//              `SNOOP_HIT (clean copy), `SNOOP_HITM (dirty copy, data
//              follows), `SNOOP_ACK (invalidated)
//   pr_data, pr_dvalid  the line, in the same cycle as pr_resp
//
// Rules the interconnect keeps (both builds):
//   * one transaction per line at a time is serialised at a single point
//     (the bus owner; the line's home directory entry in the NoC build)
//   * a probe may arrive while the L1's own request is waiting, including for
//     the same line; the L1 re-checks its state when the reply comes
//   * a BUS_FLUSH from an L1 that has already lost the line to a probe is
//     acknowledged but must not overwrite newer data
// ============================================================================
