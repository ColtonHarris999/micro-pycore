`include "pycore_defs.svh"

// uPyCore value adapter (planning/micropython_pivot_plan.md §0.5, §1.2).
//
// One architectural register is 36 bits: tag[35:32] and payload[31:0].
// Wide values occupy the following registers, each tagged CONT:
//   INT64     low 32, then high 32
//   COMPLEX   real binary32, then imaginary binary32
//   SHORT_STR length in the first payload's low byte, then up to 15 bytes
//             across this register and three CONT registers
//
// INT arithmetic is the existing 64-bit pycore_int_alu. A result that fits
// in signed 32 is one INT register. A result that fits in signed 64 is an
// INT64 pair. A result outside signed 64 is OverflowError (PY_TRAP_OVERFLOW).
//
// False and True are CONTROL kinds 4 and 5. Addition and dict hashing read
// them as int 0 and int 1 (mpy_as_int).
//
// FLOAT is one binary32. The operand is widened, pycore_fp_add runs, and
// the binary64 result is rounded back to binary32. COMPLEX add/sub is that
// scalar add twice, real then imaginary. There is no complex ALU.
//
// SHORT_STR case conversion is ASCII A-Z / a-z only. Bytes outside that
// range, including every non-ASCII byte, are copied unchanged. This path
// does not use the Latin-1 case tables. STR is a pointer and QSTR is an
// id; neither is case-mapped inline.

// verilator lint_off DECLFILENAME
package mpy_alu_pkg;
    localparam logic [3:0] MPY_TAG_CONTROL   = 4'b0000;
    localparam logic [3:0] MPY_TAG_INT       = 4'b0001;
    localparam logic [3:0] MPY_TAG_INT64     = 4'b0010;
    localparam logic [3:0] MPY_TAG_FLOAT     = 4'b0011;
    localparam logic [3:0] MPY_TAG_COMPLEX   = 4'b0100;
    localparam logic [3:0] MPY_TAG_QSTR      = 4'b0110;
    localparam logic [3:0] MPY_TAG_SHORT_STR = 4'b0111;
    localparam logic [3:0] MPY_TAG_STR       = 4'b1000;
    localparam logic [3:0] MPY_TAG_TUPLE     = 4'b1001;
    localparam logic [3:0] MPY_TAG_MUT_COLLEC = 4'b1010;
    localparam logic [3:0] MPY_TAG_RANGE     = 4'b1011;
    localparam logic [3:0] MPY_TAG_ITER      = 4'b1100;
    localparam logic [3:0] MPY_TAG_BYTES     = 4'b1101;
    localparam logic [3:0] MPY_TAG_OBJECT    = 4'b1110;
    localparam logic [3:0] MPY_TAG_CONT      = 4'b1111;

    localparam logic [3:0] MPY_CTL_EMPTY     = 4'd0;
    localparam logic [3:0] MPY_CTL_NONE      = 4'd1;
    localparam logic [3:0] MPY_CTL_NULL      = 4'd2;
    localparam logic [3:0] MPY_CTL_TOMBSTONE = 4'd3;
    localparam logic [3:0] MPY_CTL_FALSE     = 4'd4;
    localparam logic [3:0] MPY_CTL_TRUE      = 4'd5;

    // Above PY_ALU_ABS (24) and below PY_ALU_ILLEGAL (31).
    localparam logic [4:0] MPY_OP_HASH  = 5'd25;
    localparam logic [4:0] MPY_OP_UPPER = 5'd26;
    localparam logic [4:0] MPY_OP_LOWER = 5'd27;

    localparam int MPY_SHORT_BYTES = 15;

    function automatic logic [35:0] mpy_reg(
        input logic [3:0]  tag,
        input logic [31:0] pay
    );
        mpy_reg = {tag, pay};
    endfunction

    function automatic logic [3:0] mpy_tag(input logic [35:0] r);
        mpy_tag = r[35:32];
    endfunction

    function automatic logic [31:0] mpy_pay(input logic [35:0] r);
        mpy_pay = r[31:0];
    endfunction

    function automatic logic mpy_is_false(
        input logic [3:0]  tag,
        input logic [31:0] pay
    );
        mpy_is_false = (tag == MPY_TAG_CONTROL) && (pay[3:0] == MPY_CTL_FALSE);
    endfunction

    function automatic logic mpy_is_true(
        input logic [3:0]  tag,
        input logic [31:0] pay
    );
        mpy_is_true = (tag == MPY_TAG_CONTROL) && (pay[3:0] == MPY_CTL_TRUE);
    endfunction

    // STR, containers, and objects carry a pointer. QSTR is an id, not a pointer.
    function automatic logic mpy_is_ptr(input logic [3:0] tag);
        mpy_is_ptr = (tag == MPY_TAG_STR) || (tag == MPY_TAG_TUPLE) ||
                     (tag == MPY_TAG_MUT_COLLEC) || (tag == MPY_TAG_RANGE) ||
                     (tag == MPY_TAG_ITER) || (tag == MPY_TAG_BYTES) ||
                     (tag == MPY_TAG_OBJECT);
    endfunction

    function automatic logic mpy_int_ok(
        input logic [3:0]  tag0,
        input logic [31:0] pay0,
        input logic [3:0]  tag1
    );
        mpy_int_ok = mpy_is_false(tag0, pay0) || mpy_is_true(tag0, pay0) ||
                     (tag0 == MPY_TAG_INT) ||
                     ((tag0 == MPY_TAG_INT64) && (tag1 == MPY_TAG_CONT));
    endfunction

    // Shared by addition and dict hashing. False -> 0, True -> 1.
    // tag1 is checked by mpy_int_ok before this is used as an INT64.
    function automatic logic [63:0] mpy_as_int(
        input logic [3:0]  tag0,
        input logic [31:0] pay0,
        input logic [31:0] pay1
    );
        if (mpy_is_false(tag0, pay0))
            mpy_as_int = 64'd0;
        else if (mpy_is_true(tag0, pay0))
            mpy_as_int = 64'd1;
        else if (tag0 == MPY_TAG_INT)
            mpy_as_int = {{32{pay0[31]}}, pay0};
        else
            mpy_as_int = {pay1, pay0};
    endfunction

    function automatic logic mpy_fits_i32(input logic [63:0] v);
        mpy_fits_i32 = (v[63:32] == {32{v[31]}});
    endfunction

    function automatic logic [7:0] mpy_ascii_upper(input logic [7:0] b);
        if ((b >= 8'h61) && (b <= 8'h7A))
            mpy_ascii_upper = b - 8'h20;
        else
            mpy_ascii_upper = b;
    endfunction

    function automatic logic [7:0] mpy_ascii_lower(input logic [7:0] b);
        if ((b >= 8'h41) && (b <= 8'h5A))
            mpy_ascii_lower = b + 8'h20;
        else
            mpy_ascii_lower = b;
    endfunction

    function automatic logic [31:0] mpy_pack4(
        input logic [7:0] b0,
        input logic [7:0] b1,
        input logic [7:0] b2,
        input logic [7:0] b3
    );
        mpy_pack4 = {b3, b2, b1, b0};
    endfunction

    // Byte i lives at position i+1 in the little-endian 16-byte window
    // (byte 0 of that window is the length).
    function automatic logic [7:0] mpy_short_byte(
        input logic [31:0] p0,
        input logic [31:0] p1,
        input logic [31:0] p2,
        input logic [31:0] p3,
        input logic [3:0]  idx
    );
        logic [4:0]  pos;
        logic [31:0] word;
        logic [7:0]  lane;
        begin
            pos = {1'b0, idx} + 5'd1;
            unique case (pos[3:2])
                2'd0: word = p0;
                2'd1: word = p1;
                2'd2: word = p2;
                default: word = p3;
            endcase
            unique case (pos[1:0])
                2'd0: lane = word[7:0];
                2'd1: lane = word[15:8];
                2'd2: lane = word[23:16];
                default: lane = word[31:24];
            endcase
            mpy_short_byte = lane;
        end
    endfunction

    // binary32 -> binary64, exact for every finite value.
    function automatic logic [63:0] mpy_f32_to_f64(input logic [31:0] f);
        logic        sign;
        logic [7:0]  exp;
        logic [22:0] frac;
        logic [4:0]  sh;
        logic [22:0] shifted;
        integer      i;
        begin
            sign = f[31];
            exp  = f[30:23];
            frac = f[22:0];
            if (exp == 8'hFF) begin
                if (frac == 23'b0)
                    mpy_f32_to_f64 = {sign, 11'h7FF, 52'b0};
                else
                    mpy_f32_to_f64 = {sign, 11'h7FF, frac, 29'b0};
            end else if ((exp == 8'h00) && (frac == 23'b0)) begin
                mpy_f32_to_f64 = {sign, 63'b0};
            end else if (exp == 8'h00) begin
                sh = 5'd22;
                for (i = 0; i < 23; i++) begin
                    if (frac[i])
                        sh = 5'(22 - i);
                end
                shifted = frac << sh;
                mpy_f32_to_f64 = {sign, 11'd896 - {6'b0, sh}, shifted[21:0], 30'b0};
            end else begin
                mpy_f32_to_f64 = {sign, ({3'b0, exp} + 11'd896), frac, 29'b0};
            end
        end
    endfunction

    // binary64 -> binary32, round to nearest even.
    function automatic logic [31:0] mpy_f64_to_f32(input logic [63:0] d);
        logic               sign;
        logic [10:0]        exp;
        logic [51:0]        frac;
        logic signed [12:0] exp32;
        logic [23:0]        sumf;
        logic               round_up;
        logic [52:0]        sig;
        logic [11:0]        sh;
        logic [52:0]        shifted;
        logic [23:0]        mag;
        logic               guard;
        logic               sticky;
        integer             i;
        begin
            sign = d[63];
            exp  = d[62:52];
            frac = d[51:0];
            if (exp == 11'h7FF) begin
                if (frac == 52'b0)
                    mpy_f64_to_f32 = {sign, 8'hFF, 23'b0};
                else
                    mpy_f64_to_f32 = {sign, 8'hFF, 1'b1, 22'b0};
            end else if (d[62:0] == 63'b0) begin
                mpy_f64_to_f32 = {sign, 31'b0};
            end else if (exp == 11'b0) begin
                mpy_f64_to_f32 = {sign, 31'b0};
            end else begin
                exp32 = $signed({2'b0, exp}) - 13'sd896;
                if (exp32 >= 13'sd255) begin
                    mpy_f64_to_f32 = {sign, 8'hFF, 23'b0};
                end else if (exp32 >= 13'sd1) begin
                    round_up = d[28] && (|d[27:0] || d[29]);
                    sumf = {1'b0, d[51:29]} + {23'b0, round_up};
                    if (sumf[23]) begin
                        exp32 = exp32 + 13'sd1;
                        if (exp32 >= 13'sd255)
                            mpy_f64_to_f32 = {sign, 8'hFF, 23'b0};
                        else
                            mpy_f64_to_f32 = {sign, exp32[7:0], 23'b0};
                    end else begin
                        mpy_f64_to_f32 = {sign, exp32[7:0], sumf[22:0]};
                    end
                end else begin
                    sig = {1'b1, frac};
                    sh  = 12'd926 - {1'b0, exp};
                    if (sh >= 12'd54) begin
                        mpy_f64_to_f32 = {sign, 31'b0};
                    end else if (sh == 12'd53) begin
                        mpy_f64_to_f32 = {sign, 8'b0, 22'b0, (sig[52] && (|sig[51:0]))};
                    end else begin
                        shifted = sig >> sh[5:0];
                        mag     = {1'b0, shifted[22:0]};
                        guard   = sig[sh[5:0] - 6'd1];
                        sticky  = 1'b0;
                        for (i = 0; i < 52; i++) begin
                            if (12'(i) < (sh - 12'd1))
                                sticky = sticky | sig[i];
                        end
                        if (guard && (sticky || mag[0]))
                            mag = mag + 24'd1;
                        if (mag[23])
                            mpy_f64_to_f32 = {sign, 8'd1, 23'b0};
                        else
                            mpy_f64_to_f32 = {sign, 8'b0, mag[22:0]};
                    end
                end
            end
        end
    endfunction
endpackage
// verilator lint_on DECLFILENAME

module mpy_alu (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        start_i,
    input  logic [4:0]  op_i,

    input  logic [35:0] a_reg_i [4],
    input  logic [35:0] b_reg_i [4],

    output logic [35:0] res_reg_o [4],
    output logic [2:0]  res_nreg_o,

    output logic        done_o,
    output logic        trap_o,
    output logic [4:0]  trap_code_o,
    output logic        stall_o,
    output logic        busy_o
);
    import mpy_alu_pkg::*;

    typedef enum logic [2:0] {
        S_IDLE,
        S_FADD,
        S_CADD_R,
        S_CADD_I,
        S_DONE,
        S_TRAP
    } state_e;

    typedef enum logic [2:0] {
        ACC_TRAP,
        ACC_INT,
        ACC_HASH,
        ACC_STR,
        ACC_FADD,
        ACC_CADD
    } acc_e;

    function automatic logic mpy_combo_int_op(input logic [4:0] op);
        unique case (op)
            PY_ALU_ADD, PY_ALU_SUB,
            PY_ALU_LSHIFT, PY_ALU_RSHIFT,
            PY_ALU_AND, PY_ALU_OR, PY_ALU_XOR,
            PY_ALU_NEG, PY_ALU_POS, PY_ALU_INVERT, PY_ALU_NOT, PY_ALU_PASS,
            PY_ALU_EQ, PY_ALU_NE, PY_ALU_LT, PY_ALU_LE, PY_ALU_GT, PY_ALU_GE:
                mpy_combo_int_op = 1'b1;
            default:
                mpy_combo_int_op = 1'b0;
        endcase
    endfunction

    function automatic logic mpy_unary_int_op(input logic [4:0] op);
        mpy_unary_int_op = (op == PY_ALU_NEG) || (op == PY_ALU_POS) ||
                           (op == PY_ALU_INVERT) || (op == PY_ALU_NOT) ||
                           (op == PY_ALU_PASS);
    endfunction

    function automatic logic mpy_cmp_op(input logic [4:0] op);
        mpy_cmp_op = (op == PY_ALU_EQ) || (op == PY_ALU_NE) ||
                     (op == PY_ALU_LT) || (op == PY_ALU_LE) ||
                     (op == PY_ALU_GT) || (op == PY_ALU_GE) ||
                     (op == PY_ALU_NOT);
    endfunction

    logic [3:0]  a_tag [4];
    logic [31:0] a_pay [4];
    logic [3:0]  b_tag [4];
    logic [31:0] b_pay [4];

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi++) begin : g_split
            assign a_tag[gi] = mpy_tag(a_reg_i[gi]);
            assign a_pay[gi] = mpy_pay(a_reg_i[gi]);
            assign b_tag[gi] = mpy_tag(b_reg_i[gi]);
            assign b_pay[gi] = mpy_pay(b_reg_i[gi]);
        end
    endgenerate

    logic        a_ok, b_ok;
    logic [63:0] a_int, b_int;
    assign a_ok  = mpy_int_ok(a_tag[0], a_pay[0], a_tag[1]);
    assign b_ok  = mpy_int_ok(b_tag[0], b_pay[0], b_tag[1]);
    assign a_int = mpy_as_int(a_tag[0], a_pay[0], a_pay[1]);
    assign b_int = mpy_as_int(b_tag[0], b_pay[0], b_pay[1]);

    logic        float_pair, complex_pair, short_ok;
    assign float_pair = (a_tag[0] == MPY_TAG_FLOAT) && (b_tag[0] == MPY_TAG_FLOAT);
    assign complex_pair = (a_tag[0] == MPY_TAG_COMPLEX) && (b_tag[0] == MPY_TAG_COMPLEX) &&
                          (a_tag[1] == MPY_TAG_CONT) && (b_tag[1] == MPY_TAG_CONT);
    assign short_ok = (a_tag[0] == MPY_TAG_SHORT_STR) && (a_pay[0][7:0] <= 8'd15) &&
                      (a_tag[1] == MPY_TAG_CONT) && (a_tag[2] == MPY_TAG_CONT) &&
                      (a_tag[3] == MPY_TAG_CONT);

    logic [63:0] int_y;
    logic        int_zero, int_ovf, int_valerr;
    logic [4:0]  int_op;
    assign int_op = mpy_combo_int_op(op_i) ? op_i : PY_ALU_ADD;

    pycore_int_alu u_int (
        .op_a_i(a_int),
        .op_b_i(b_int),
        .op_i(int_op),
        .result_o(int_y),
        .zero_flag_o(int_zero),
        .overflow_flag_o(int_ovf),
        .value_error_o(int_valerr)
    );

    logic [63:0] fp_a, fp_b;
    logic        fp_sub;
    logic        fp_start, fp_done, fp_busy;
    logic [63:0] fp_y;

    state_e      state_q;
    logic [35:0] res_q [4];
    logic [2:0]  nreg_q;
    logic [4:0]  trap_q;
    logic [31:0] creal_q;

    always_comb begin
        if (state_q == S_CADD_I) begin
            fp_a = mpy_f32_to_f64(a_pay[1]);
            fp_b = mpy_f32_to_f64(b_pay[1]);
        end else begin
            fp_a = mpy_f32_to_f64(a_pay[0]);
            fp_b = mpy_f32_to_f64(b_pay[0]);
        end
    end
    assign fp_sub   = (op_i == PY_ALU_SUB);
    assign fp_start = start_i &&
                      ((state_q == S_FADD) || (state_q == S_CADD_R) || (state_q == S_CADD_I));

    pycore_fp_add u_fp_add (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .start_i(fp_start),
        .sub_i(fp_sub),
        .op_a_i(fp_a),
        .op_b_i(fp_b),
        .result_o(fp_y),
        .done_o(fp_done),
        .busy_o(fp_busy)
    );

    acc_e       acc;
    logic [4:0] acc_code;
    always_comb begin
        acc      = ACC_TRAP;
        acc_code = PY_TRAP_TYPE;
        if (op_i == MPY_OP_HASH) begin
            if (a_ok)
                acc = ACC_HASH;
        end else if ((op_i == MPY_OP_UPPER) || (op_i == MPY_OP_LOWER)) begin
            // QSTR is an id. STR (and the other pointer tags) is an address.
            // Neither has inline bytes, so the ASCII map does not touch it.
            if ((a_tag[0] == MPY_TAG_QSTR) || mpy_is_ptr(a_tag[0]))
                acc = ACC_TRAP;
            else if (short_ok)
                acc = ACC_STR;
        end else if (mpy_combo_int_op(op_i) && a_ok && (mpy_unary_int_op(op_i) || b_ok)) begin
            if (int_valerr) begin
                acc      = ACC_TRAP;
                acc_code = PY_TRAP_VALUE;
            end else if (int_ovf && !mpy_cmp_op(op_i)) begin
                acc      = ACC_TRAP;
                acc_code = PY_TRAP_OVERFLOW;
            end else begin
                acc = ACC_INT;
            end
        end else if (((op_i == PY_ALU_ADD) || (op_i == PY_ALU_SUB)) && float_pair) begin
            acc = ACC_FADD;
        end else if (((op_i == PY_ALU_ADD) || (op_i == PY_ALU_SUB)) && complex_pair) begin
            acc = ACC_CADD;
        end
    end

    logic [7:0] cased_b [15];
    logic [35:0] str_r [4];
    always_comb begin
        integer bi;
        logic [7:0] raw;
        for (bi = 0; bi < MPY_SHORT_BYTES; bi++) begin
            raw = mpy_short_byte(a_pay[0], a_pay[1], a_pay[2], a_pay[3], bi[3:0]);
            if (bi < int'(a_pay[0][7:0])) begin
                if (op_i == MPY_OP_LOWER)
                    cased_b[bi] = mpy_ascii_lower(raw);
                else
                    cased_b[bi] = mpy_ascii_upper(raw);
            end else begin
                cased_b[bi] = 8'h00;
            end
        end
        str_r[0] = mpy_reg(MPY_TAG_SHORT_STR,
                           mpy_pack4(a_pay[0][7:0], cased_b[0], cased_b[1], cased_b[2]));
        str_r[1] = mpy_reg(MPY_TAG_CONT,
                           mpy_pack4(cased_b[3], cased_b[4], cased_b[5], cased_b[6]));
        str_r[2] = mpy_reg(MPY_TAG_CONT,
                           mpy_pack4(cased_b[7], cased_b[8], cased_b[9], cased_b[10]));
        str_r[3] = mpy_reg(MPY_TAG_CONT,
                           mpy_pack4(cased_b[11], cased_b[12], cased_b[13], cased_b[14]));
    end

    logic [35:0] int_pack_r0, int_pack_r1;
    logic [2:0]  int_pack_n;
    always_comb begin
        if (mpy_fits_i32(int_y)) begin
            int_pack_r0 = mpy_reg(MPY_TAG_INT, int_y[31:0]);
            int_pack_r1 = '0;
            int_pack_n  = 3'd1;
        end else begin
            int_pack_r0 = mpy_reg(MPY_TAG_INT64, int_y[31:0]);
            int_pack_r1 = mpy_reg(MPY_TAG_CONT, int_y[63:32]);
            int_pack_n  = 3'd2;
        end
    end

    logic [35:0] hash_pack_r0, hash_pack_r1;
    logic [2:0]  hash_pack_n;
    always_comb begin
        if (mpy_fits_i32(a_int)) begin
            hash_pack_r0 = mpy_reg(MPY_TAG_INT, a_int[31:0]);
            hash_pack_r1 = '0;
            hash_pack_n  = 3'd1;
        end else begin
            hash_pack_r0 = mpy_reg(MPY_TAG_INT64, a_int[31:0]);
            hash_pack_r1 = mpy_reg(MPY_TAG_CONT, a_int[63:32]);
            hash_pack_n  = 3'd2;
        end
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_q  <= S_IDLE;
            nreg_q   <= 3'd0;
            trap_q   <= 5'd0;
            creal_q  <= 32'd0;
            res_q[0] <= '0;
            res_q[1] <= '0;
            res_q[2] <= '0;
            res_q[3] <= '0;
        end else if (!start_i) begin
            state_q <= S_IDLE;
        end else begin
            unique case (state_q)
                S_IDLE: begin
                    unique case (acc)
                        ACC_INT: begin
                            if (mpy_cmp_op(op_i)) begin
                                res_q[0] <= mpy_reg(MPY_TAG_CONTROL,
                                                    {28'b0, int_y[0] ? MPY_CTL_TRUE : MPY_CTL_FALSE});
                                res_q[1] <= '0;
                                nreg_q   <= 3'd1;
                            end else begin
                                res_q[0] <= int_pack_r0;
                                res_q[1] <= int_pack_r1;
                                nreg_q   <= int_pack_n;
                            end
                            res_q[2] <= '0;
                            res_q[3] <= '0;
                            state_q  <= S_DONE;
                        end
                        ACC_HASH: begin
                            res_q[0] <= hash_pack_r0;
                            res_q[1] <= hash_pack_r1;
                            res_q[2] <= '0;
                            res_q[3] <= '0;
                            nreg_q   <= hash_pack_n;
                            state_q  <= S_DONE;
                        end
                        ACC_STR: begin
                            res_q[0] <= str_r[0];
                            res_q[1] <= str_r[1];
                            res_q[2] <= str_r[2];
                            res_q[3] <= str_r[3];
                            nreg_q   <= 3'd4;
                            state_q  <= S_DONE;
                        end
                        ACC_FADD: state_q <= S_FADD;
                        ACC_CADD: state_q <= S_CADD_R;
                        default: begin
                            res_q[0] <= '0;
                            res_q[1] <= '0;
                            res_q[2] <= '0;
                            res_q[3] <= '0;
                            nreg_q   <= 3'd0;
                            trap_q   <= acc_code;
                            state_q  <= S_TRAP;
                        end
                    endcase
                end
                S_FADD: begin
                    if (fp_done) begin
                        res_q[0] <= mpy_reg(MPY_TAG_FLOAT, mpy_f64_to_f32(fp_y));
                        res_q[1] <= '0;
                        res_q[2] <= '0;
                        res_q[3] <= '0;
                        nreg_q   <= 3'd1;
                        state_q  <= S_DONE;
                    end
                end
                S_CADD_R: begin
                    if (fp_done) begin
                        creal_q <= mpy_f64_to_f32(fp_y);
                        state_q <= S_CADD_I;
                    end
                end
                S_CADD_I: begin
                    if (fp_done) begin
                        res_q[0] <= mpy_reg(MPY_TAG_COMPLEX, creal_q);
                        res_q[1] <= mpy_reg(MPY_TAG_CONT, mpy_f64_to_f32(fp_y));
                        res_q[2] <= '0;
                        res_q[3] <= '0;
                        nreg_q   <= 3'd2;
                        state_q  <= S_DONE;
                    end
                end
                S_DONE: state_q <= S_IDLE;
                S_TRAP: state_q <= S_IDLE;
                default: state_q <= S_IDLE;
            endcase
        end
    end

    assign res_nreg_o  = nreg_q;
    assign done_o      = (state_q == S_DONE);
    assign trap_o      = (state_q == S_TRAP);
    assign trap_code_o = trap_q;
    assign stall_o     = start_i && !done_o && !trap_o;
    assign busy_o      = (state_q == S_FADD) || (state_q == S_CADD_R) ||
                         (state_q == S_CADD_I) || fp_busy;

    // The integer ALU's zero flag is not an architectural output. Comparisons
    // publish CONTROL True/False from the result bit.
    // verilator lint_off UNUSEDSIGNAL
    wire unused_int_zero = int_zero;
    // verilator lint_on UNUSEDSIGNAL

    generate
        for (gi = 0; gi < 4; gi++) begin : g_res
            assign res_reg_o[gi] = res_q[gi];
        end
    endgenerate
endmodule
