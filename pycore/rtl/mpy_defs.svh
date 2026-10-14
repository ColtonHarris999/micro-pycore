`ifndef MPY_DEFS_SVH
`define MPY_DEFS_SVH
// verilator lint_off UNUSEDPARAM
// MicroPython value encoding (planning/micropython_pivot_plan.md §0.5, §0.6).
// These codes are not the imported pycore tag map in pycore_defs.svh.
// One slot is a 32-bit payload plus a 4-bit tag nibble stored beside it.

localparam logic [3:0] MPY_TAG_CONTROL   = 4'b0000;
localparam logic [3:0] MPY_TAG_INT       = 4'b0001;
localparam logic [3:0] MPY_TAG_INT64     = 4'b0010;
localparam logic [3:0] MPY_TAG_FLOAT     = 4'b0011;
localparam logic [3:0] MPY_TAG_COMPLEX   = 4'b0100;
localparam logic [3:0] MPY_TAG_RESERVED  = 4'b0101;
localparam logic [3:0] MPY_TAG_QSTR      = 4'b0110;
localparam logic [3:0] MPY_TAG_SHORT_STR = 4'b0111;
localparam logic [3:0] MPY_TAG_STR       = 4'b1000;
localparam logic [3:0] MPY_TAG_TUPLE     = 4'b1001;
localparam logic [3:0] MPY_TAG_MUT       = 4'b1010;
localparam logic [3:0] MPY_TAG_RANGE     = 4'b1011;
localparam logic [3:0] MPY_TAG_ITER      = 4'b1100;
localparam logic [3:0] MPY_TAG_BYTES     = 4'b1101;
localparam logic [3:0] MPY_TAG_OBJECT    = 4'b1110;
localparam logic [3:0] MPY_TAG_CONT      = 4'b1111;

// CONTROL payload[3:0]. False and True are control kinds, not pointers.
localparam logic [3:0] MPY_CTL_EMPTY = 4'd0;
localparam logic [3:0] MPY_CTL_NONE  = 4'd1;
localparam logic [3:0] MPY_CTL_NULL  = 4'd2;
localparam logic [3:0] MPY_CTL_TOMB  = 4'd3;
localparam logic [3:0] MPY_CTL_FALSE = 4'd4;
localparam logic [3:0] MPY_CTL_TRUE  = 4'd5;

// MUT_COLLEC payload[1:0]. The address is the payload with these bits cleared.
localparam logic [1:0] MPY_MUT_LIST      = 2'd0;
localparam logic [1:0] MPY_MUT_DICT      = 2'd1;
localparam logic [1:0] MPY_MUT_SET       = 2'd2;
localparam logic [1:0] MPY_MUT_BYTEARRAY = 2'd3;

// OBJECT word 0. Field lists are §0.6; word 1 is the type pointer.
localparam logic [31:0] MPY_OBK_INSTANCE     = 32'd1;
localparam logic [31:0] MPY_OBK_TYPE         = 32'd2;
localparam logic [31:0] MPY_OBK_BOUND_METHOD = 32'd3;
localparam logic [31:0] MPY_OBK_BUILTIN      = 32'd4;
localparam logic [31:0] MPY_OBK_EXCEPTION    = 32'd6;
localparam logic [31:0] MPY_OBK_CELL         = 32'd7;
localparam logic [31:0] MPY_OBK_FUNCTION     = 32'd8;
localparam logic [31:0] MPY_OBK_MODULE       = 32'd11;
// verilator lint_on UNUSEDPARAM
`endif
