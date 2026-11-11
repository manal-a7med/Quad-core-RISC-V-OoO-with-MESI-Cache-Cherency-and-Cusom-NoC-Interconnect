`timescale 1ns / 1ps
`include "mesi_defines.vh"
`include "common_defs.vh"

module mesi_protocol (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [1:0] current_state,
    input  wire       proc_event,       // 0: PrRd, 1: PrWr
    input  wire       proc_event_valid,
    input  wire [2:0] bus_event,        // 0: None, 1: BusRd, 2: BusRdX, 3: BusUpgr
    input  wire       bus_event_valid,
    input  wire       shared_signal,
    output reg  [1:0] next_state,
    output reg  [2:0] bus_action,       // 0: None, 1: BusRd, 2: BusRdX, 3: BusUpgr
    output reg        need_flush,
    output reg        supply_data
);

    // Local state encoding (Standard MESI)
    localparam STATE_I = 2'b00;
    localparam STATE_S = 2'b01;
    localparam STATE_E = 2'b10;
    localparam STATE_M = 2'b11;

    // Processor events
    localparam PR_RD = 1'b0;
    localparam PR_WR = 1'b1;

    // Bus events/actions
    localparam BUS_NONE = 3'b000;
    localparam BUS_RD   = 3'b001;
    localparam BUS_RDX  = 3'b010;
    localparam BUS_UPGR = 3'b011;

    always @(*) begin
        // Default outputs
        next_state  = current_state;
        bus_action  = BUS_NONE;
        need_flush  = 1'b0;
        supply_data = 1'b0;

        if (proc_event_valid) begin
            case (current_state)
                STATE_I: begin
                    if (proc_event == PR_RD) begin
                        bus_action = BUS_RD;
                        next_state = shared_signal ? STATE_S : STATE_E;
                    end else if (proc_event == PR_WR) begin
                        bus_action = BUS_RDX;
                        next_state = STATE_M;
                    end
                end
                STATE_S: begin
                    if (proc_event == PR_RD) begin
                        next_state = STATE_S; // Hit, no bus
                    end else if (proc_event == PR_WR) begin
                        bus_action = BUS_UPGR;
                        next_state = STATE_M;
                    end
                end
                STATE_E: begin
                    if (proc_event == PR_RD) begin
                        next_state = STATE_E; // Hit, no bus
                    end else if (proc_event == PR_WR) begin
                        next_state = STATE_M; // Silent upgrade
                    end
                end
                STATE_M: begin
                    if (proc_event == PR_RD) begin
                        next_state = STATE_M; // Hit, no bus
                    end else if (proc_event == PR_WR) begin
                        next_state = STATE_M; // Hit, no bus
                    end
                end
                default: next_state = STATE_I;
            endcase
        end else if (bus_event_valid) begin
            case (current_state)
                STATE_I: begin
                    next_state = STATE_I;
                end
                STATE_S: begin
                    if (bus_event == BUS_RD) begin
                        next_state = STATE_S;
                    end else if (bus_event == BUS_RDX || bus_event == BUS_UPGR) begin
                        next_state = STATE_I;
                    end
                end
                STATE_E: begin
                    if (bus_event == BUS_RD) begin
                        next_state = STATE_S;
                        supply_data = 1'b1; // E can optionally supply data depending on specific impl.
                    end else if (bus_event == BUS_RDX) begin
                        next_state = STATE_I;
                    end
                end
                STATE_M: begin
                    if (bus_event == BUS_RD) begin
                        next_state = STATE_S;
                        need_flush = 1'b1;
                        supply_data = 1'b1;
                    end else if (bus_event == BUS_RDX) begin
                        next_state = STATE_I;
                        need_flush = 1'b1;
                        supply_data = 1'b1;
                    end
                end
                default: next_state = STATE_I;
            endcase
        end
    end

`ifdef SIM
    always @(posedge clk) begin
        if (proc_event_valid || bus_event_valid) begin
            $display("[MESI Protocol] State: %b -> %b | proc_ev: %b (v:%b) | bus_ev: %b (v:%b)", 
                     current_state, next_state, proc_event, proc_event_valid, bus_event, bus_event_valid);
        end
    end
`endif

endmodule

