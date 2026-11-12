// amo.vh - result of an atomic read-modify-write (RV32A), as a function.
// amo_apply(op, old, val): the new memory word for AMO op `op` (see
// common_defs.vh), given the old word and the rs2 value. SC stores `val`.
// Include inside a module; all inputs are arguments (see the iverilog note
// in issue_queue.v).
function [31:0] amo_apply(input [3:0] op, input [31:0] old, input [31:0] val);
    case (op)
        `AMO_ADD:  amo_apply = old + val;
        `AMO_XOR:  amo_apply = old ^ val;
        `AMO_AND:  amo_apply = old & val;
        `AMO_OR:   amo_apply = old | val;
        `AMO_MIN:  amo_apply = ($signed(old) < $signed(val)) ? old : val;
        `AMO_MAX:  amo_apply = ($signed(old) < $signed(val)) ? val : old;
        `AMO_MINU: amo_apply = (old < val) ? old : val;
        `AMO_MAXU: amo_apply = (old < val) ? val : old;
        default:   amo_apply = val;                  // SWAP, SC
    endcase
endfunction
