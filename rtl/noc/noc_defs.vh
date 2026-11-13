// ============================================================================
// noc_defs.vh - packet format of the 2x2 mesh NoC (NOC=1 build)
// ============================================================================
// Three separate networks, one per message class, so a message of one class
// can never be stuck behind a message of another (no protocol deadlock):
//
//   REQ  core -> home   GetS / GetM / Upgrade / PutM requests
//   RSP  core -> home   probe responses (with the line if it was dirty);
//        core -> core   the line, sent by its owner straight to the requester
//   OUT  home -> core   probes and grants. One network for both, so a grant
//                       and a later probe to the same core arrive in order
//                       (XY routing, FIFO buffers: point-to-point order)
//
// A link carries one flit plus a tail bit per cycle (valid/ready).
// A packet is a header flit, followed by the 256-bit line in DATA_FLITS
// data flits (low part first) when HDR_DATA is set.
// ============================================================================

`ifndef NOC_DEFS_VH
`define NOC_DEFS_VH

// Flit width: 64 (default), 128 or 256 bits (+define+NOC_FLIT_W=..., make
// NOC_FLIT=...). The header always uses the low 64 bits of its flit; a line
// takes 256 / FLIT_W data flits.
`ifndef NOC_FLIT_W
`define NOC_FLIT_W    64
`endif
`define FLIT_W        `NOC_FLIT_W
`define LINK_W        (`FLIT_W + 1)   // {tail, flit}
`define DATA_FLITS    (256 / `FLIT_W)

// Header flit fields
`define HDR_TYPE      2:0         // message type (below)
`define HDR_DST       4:3         // destination node
`define HDR_SRC       6:5         // source node (the core for REQ / RSP)
`define HDR_WAY       7           // L1 way the line is filled into / written back from
`define HDR_SHARED    8           // grant: another cache keeps a copy
`define HDR_DATA      9           // four data flits follow
`define HDR_IFETCH    10          // request is an I-cache line fetch
`define HDR_ADDR      37:11       // line address [31:5]
`define HDR_RESP      39:38       // probe response (`SNOOP_*)
`define HDR_CORE      41:40       // grant: the core it is for; forwarding probe: the requester
`define HDR_FWD       42          // probe: send the line straight to core HDR_CORE;
                                  // grant: the line follows in a MSG_DATA packet
`define HDR_SENT      43          // probe response: the line was sent to the requester

// Message types. REQ uses the bus command codes (`BUS_READ etc. in
// mesi_defines.vh) so the two builds speak the same language.
`define MSG_GRANT     3'd0        // OUT: transaction done (with the line if HDR_DATA)
`define MSG_PROBE_RD  3'd1        // OUT: probe, same as a BusRd snoop
`define MSG_PROBE_RDX 3'd2        // OUT: probe, same as a BusRdX snoop
`define MSG_PROBE_INV 3'd5        // OUT: probe, invalidate (BusUpgr snoop)
`define MSG_PRESP     3'd6        // RSP: probe response
`define MSG_DATA      3'd3        // RSP (from the owner) or OUT (from the home): the line
                                  // for a grant marked HDR_FWD

`endif
