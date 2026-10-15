`ifndef UPYCORE_DEFS_SVH
`define UPYCORE_DEFS_SVH
// Numeric opcodes and binary64 helpers for the uPyCore datapath.

localparam logic [4:0] UPY_ALU_ADD       = 5'd0;
localparam logic [4:0] UPY_ALU_SUB       = 5'd1;
localparam logic [4:0] UPY_ALU_MUL       = 5'd2;
localparam logic [4:0] UPY_ALU_FLOOR_DIV = 5'd3;
localparam logic [4:0] UPY_ALU_TRUE_DIV  = 5'd4;
localparam logic [4:0] UPY_ALU_MOD       = 5'd5;
localparam logic [4:0] UPY_ALU_POWER     = 5'd6;
localparam logic [4:0] UPY_ALU_LSHIFT    = 5'd7;
localparam logic [4:0] UPY_ALU_RSHIFT    = 5'd8;
localparam logic [4:0] UPY_ALU_AND       = 5'd9;
localparam logic [4:0] UPY_ALU_OR        = 5'd10;
localparam logic [4:0] UPY_ALU_XOR       = 5'd11;
localparam logic [4:0] UPY_ALU_NEG       = 5'd12;
localparam logic [4:0] UPY_ALU_POS       = 5'd13;
localparam logic [4:0] UPY_ALU_INVERT    = 5'd14;
localparam logic [4:0] UPY_ALU_NOT       = 5'd15;
localparam logic [4:0] UPY_ALU_EQ        = 5'd16;
localparam logic [4:0] UPY_ALU_NE        = 5'd17;
localparam logic [4:0] UPY_ALU_LT        = 5'd18;
localparam logic [4:0] UPY_ALU_LE        = 5'd19;
localparam logic [4:0] UPY_ALU_GT        = 5'd20;
localparam logic [4:0] UPY_ALU_GE        = 5'd21;
localparam logic [4:0] UPY_ALU_PASS      = 5'd22;
localparam logic [4:0] UPY_ALU_SUBSCR    = 5'd23;
localparam logic [4:0] UPY_ALU_ABS       = 5'd24;
localparam logic [4:0] UPY_ALU_ILLEGAL   = 5'd31;

`include "upycore_fp_defs.svh"

// Truncate a binary64 value toward zero into signed int64.
// ok=1 for finite values that fit; NaN, inf, and |x| >= 2^63 return ok=0.
function automatic logic upycore_float_trunc_int64(
    input  logic [63:0] value,
    output logic [63:0] out_int
);
    logic        f_sign;
    logic [10:0] f_exp;
    logic [51:0] f_frac;
    logic [10:0] f_uexp;
    logic [52:0] f_sig;
    logic [63:0] f_mag;
    begin
        f_sign  = value[63];
        f_exp   = value[62:52];
        f_frac  = value[51:0];
        f_uexp  = f_exp - 11'd1023;
        f_sig   = {1'b1, f_frac};
        f_mag   = 64'd0;
        out_int = 64'd0;
        upycore_float_trunc_int64 = 1'b0;
        if (f_exp == 11'h7FF) begin
        end else if (f_exp < 11'd1023) begin
            out_int = 64'd0;
            upycore_float_trunc_int64 = 1'b1;
        end else if (f_uexp >= 11'd63) begin
        end else begin
            if (f_uexp < 11'd52)
                f_mag = {11'b0, f_sig} >> (11'd52 - f_uexp);
            else
                f_mag = {11'b0, f_sig} << (f_uexp - 11'd52);
            out_int = f_sign ? (~f_mag + 64'd1) : f_mag;
            upycore_float_trunc_int64 = 1'b1;
        end
    end
endfunction
`endif
