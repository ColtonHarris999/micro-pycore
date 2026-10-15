`include "upycore_defs.svh"

// Scalar number unit for mpy_core (upycore/docs/mpy_core.md, "ALU").
//
// One operation per start_i pulse; done_o pulses when res_o, rkind_o and
// err_o are valid. Operands are 64-bit: a signed integer (INT, INT64 and
// bool all reach here as int64) or a binary32 in [31:0] when the matching
// *_flt_i is set. Ops are the bytecode binary op numbers (py/runtime0.h,
// in-place forms already folded onto the plain ones) and ALU_NEG..ALU_F2I.
//
// Integer semantics follow the oracle's 32-bit longlong build:
//   + - * << overflowing int64          err OVERFLOW
//   // and % with both operands in the 31-bit small-int range round toward
//   minus infinity; otherwise they truncate, as C long long does
//   ** with a negative exponent, and /, are float operations
// Floats are binary32: each operand is widened to binary64, upycore_fpu
// runs the operation once, and the result is rounded back. That is exact
// for + - * /, fmod and the comparisons; ** may differ from powf in the
// last bit. A float ** that overflows gives inf, as powf does.
// A negative base with a fractional exponent reports err COMPLEX so the
// firmware can build the complex result.

// verilator lint_off DECLFILENAME
package mpy_alu_pkg;
    localparam logic [5:0] ALU_LT      = 6'd0;
    localparam logic [5:0] ALU_GT      = 6'd1;
    localparam logic [5:0] ALU_EQ      = 6'd2;
    localparam logic [5:0] ALU_LE      = 6'd3;
    localparam logic [5:0] ALU_GE      = 6'd4;
    localparam logic [5:0] ALU_NE      = 6'd5;
    localparam logic [5:0] ALU_OR      = 6'd22;
    localparam logic [5:0] ALU_XOR     = 6'd23;
    localparam logic [5:0] ALU_AND     = 6'd24;
    localparam logic [5:0] ALU_LSHIFT  = 6'd25;
    localparam logic [5:0] ALU_RSHIFT  = 6'd26;
    localparam logic [5:0] ALU_ADD     = 6'd27;
    localparam logic [5:0] ALU_SUB     = 6'd28;
    localparam logic [5:0] ALU_MUL     = 6'd29;
    localparam logic [5:0] ALU_MATMUL  = 6'd30;
    localparam logic [5:0] ALU_FLOOR   = 6'd31;
    localparam logic [5:0] ALU_TDIV    = 6'd32;
    localparam logic [5:0] ALU_MOD     = 6'd33;
    localparam logic [5:0] ALU_POW     = 6'd34;
    localparam logic [5:0] ALU_NEG     = 6'd40;
    localparam logic [5:0] ALU_POS     = 6'd41;
    localparam logic [5:0] ALU_INVERT  = 6'd42;
    localparam logic [5:0] ALU_ABS     = 6'd43;
    localparam logic [5:0] ALU_I2F     = 6'd44;
    localparam logic [5:0] ALU_F2I     = 6'd45;

    localparam logic [1:0] AK_INT   = 2'd0;
    localparam logic [1:0] AK_FLOAT = 2'd1;
    localparam logic [1:0] AK_BOOL  = 2'd3;

    localparam logic [2:0] AE_NONE        = 3'd0;
    localparam logic [2:0] AE_ZERO_DIV    = 3'd1;
    localparam logic [2:0] AE_OVERFLOW    = 3'd2;
    localparam logic [2:0] AE_NEG_SHIFT   = 3'd3;
    localparam logic [2:0] AE_UNSUPPORTED = 3'd4;
    localparam logic [2:0] AE_COMPLEX     = 3'd5;
    localparam logic [2:0] AE_FTOI        = 3'd6;

    // int64 -> binary32, round to nearest even (the C conversion).
    function automatic logic [31:0] mpy_i64_to_f32(input logic [63:0] v);
        logic        s;
        logic [63:0] m;
        logic [63:0] mant;
        logic [63:0] rem;
        logic [63:0] half;
        int          msb;
        int          sh;
        logic [8:0]  e;
        begin
            s = v[63];
            m = s ? (~v + 64'd1) : v;
            msb = 0;
            for (int i = 0; i < 64; i++)
                if (m[i]) msb = i;
            if (m == 64'd0) begin
                mpy_i64_to_f32 = 32'd0;
            end else if (msb <= 23) begin
                mant = m << (23 - msb);
                e = 9'(msb + 127);
                mpy_i64_to_f32 = {s, e[7:0], mant[22:0]};
            end else begin
                sh = msb - 23;
                mant = m >> sh;
                rem = m & ((64'd1 << sh) - 64'd1);
                half = 64'd1 << (sh - 1);
                e = 9'(msb + 127);
                if (rem > half || (rem == half && mant[0]))
                    mant = mant + 64'd1;
                if (mant[24]) begin
                    mant = mant >> 1;
                    e = e + 9'd1;
                end
                mpy_i64_to_f32 = {s, e[7:0], mant[22:0]};
            end
        end
    endfunction

    // binary32 -> int64 toward zero. ok = 0 for NaN, inf, and |f| >= 2**63.
    function automatic logic [63:0] mpy_f32_to_i64(input logic [31:0] f, output logic ok);
        logic [7:0]  e;
        logic [63:0] m;
        int          x;
        begin
            e = f[30:23];
            ok = 1'b1;
            mpy_f32_to_i64 = 64'd0;
            if (e == 8'hFF) begin
                ok = 1'b0;
            end else if (e >= 8'd127) begin
                x = int'(e) - 127;
                if (x >= 63) begin
                    ok = 1'b0;
                end else begin
                    m = {40'd0, 1'b1, f[22:0]};
                    if (x >= 23) m = m << (x - 23);
                    else m = m >> (23 - x);
                    mpy_f32_to_i64 = f[31] ? (~m + 64'd1) : m;
                end
            end
        end
    endfunction

    function automatic logic mpy_f32_nan(input logic [31:0] f);
        mpy_f32_nan = (f[30:23] == 8'hFF) && (f[22:0] != 23'd0);
    endfunction

    function automatic logic mpy_f32_zero(input logic [31:0] f);
        mpy_f32_zero = (f[30:0] == 31'd0);
    endfunction

    // a < b with IEEE semantics (NaN compares false, -0 == +0).
    function automatic logic mpy_f32_lt(input logic [31:0] a, input logic [31:0] b);
        if (mpy_f32_nan(a) || mpy_f32_nan(b) || (mpy_f32_zero(a) && mpy_f32_zero(b)))
            mpy_f32_lt = 1'b0;
        else if (a[31] != b[31])
            mpy_f32_lt = a[31];
        else if (!a[31])
            mpy_f32_lt = a[30:0] < b[30:0];
        else
            mpy_f32_lt = a[30:0] > b[30:0];
    endfunction

    function automatic logic mpy_f32_eq(input logic [31:0] a, input logic [31:0] b);
        mpy_f32_eq = !mpy_f32_nan(a) && !mpy_f32_nan(b) &&
                     ((a == b) || (mpy_f32_zero(a) && mpy_f32_zero(b)));
    endfunction

    // An integral binary32 (including the infinities' neighbours).
    function automatic logic mpy_f32_integral(input logic [31:0] f);
        logic [7:0]  e;
        logic [22:0] mask;
        begin
            e = f[30:23];
            if (e == 8'hFF) mpy_f32_integral = 1'b0;
            else if (e >= 8'd150) mpy_f32_integral = 1'b1;
            else if (e < 8'd127) mpy_f32_integral = (f[30:0] == 31'd0);
            else begin
                mask = 23'h7FFFFF >> (int'(e) - 127);
                mpy_f32_integral = (f[22:0] & mask) == 23'd0;
            end
        end
    endfunction

    // An odd integral binary32.
    function automatic logic mpy_f32_odd(input logic [31:0] f);
        logic [7:0] e;
        begin
            e = f[30:23];
            if (!mpy_f32_integral(f) || e < 8'd127 || e > 8'd150) mpy_f32_odd = 1'b0;
            else if (e == 8'd127) mpy_f32_odd = 1'b1;
            else mpy_f32_odd = f[5'(8'd150 - e)];
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
    input  logic [5:0]  op_i,
    input  logic        a_flt_i,
    input  logic        b_flt_i,
    input  logic [63:0] a_i,
    input  logic [63:0] b_i,
    // Both integer operands are in the oracle's 31-bit small-int range.
    input  logic        small_i,
    output logic        done_o,
    output logic [63:0] res_o,
    output logic [1:0]  rkind_o,
    output logic [2:0]  err_o
);
    import mpy_alu_pkg::*;

    typedef enum logic [2:0] { A_IDLE, A_MUL, A_DIV, A_POW, A_FPU, A_DONE } astate_e;
    astate_e st;

    logic [5:0]  op;
    logic        small_r;
    logic [63:0] a, b;
    logic [31:0] fa, fb;

    // Integer datapath (combinational ops).
    logic [4:0]  iop;
    logic [63:0] ires;
    logic        izero, iovf, iverr;
    always_comb begin
        case (op)
            ALU_ADD:    iop = UPY_ALU_ADD;
            ALU_SUB:    iop = UPY_ALU_SUB;
            ALU_AND:    iop = UPY_ALU_AND;
            ALU_OR:     iop = UPY_ALU_OR;
            ALU_XOR:    iop = UPY_ALU_XOR;
            ALU_LSHIFT: iop = UPY_ALU_LSHIFT;
            ALU_RSHIFT: iop = UPY_ALU_RSHIFT;
            ALU_LT:     iop = UPY_ALU_LT;
            ALU_GT:     iop = UPY_ALU_GT;
            ALU_EQ:     iop = UPY_ALU_EQ;
            ALU_LE:     iop = UPY_ALU_LE;
            ALU_GE:     iop = UPY_ALU_GE;
            ALU_NE:     iop = UPY_ALU_NE;
            ALU_NEG:    iop = UPY_ALU_NEG;
            ALU_INVERT: iop = UPY_ALU_INVERT;
            default:    iop = UPY_ALU_PASS;
        endcase
    end
    upycore_int_alu u_int (
        .op_a_i(a), .op_b_i(b), .op_i(iop),
        .result_o(ires), .zero_flag_o(izero), .overflow_flag_o(iovf), .value_error_o(iverr)
    );

    // Multiplier, shared by * and the power sequencer.
    logic        pow_mul_start;
    logic [63:0] mul_a, mul_b, pow_mul_a, pow_mul_b, mul_lo, mul_hi;
    logic        mul_done, mul_stall, mul_busy;
    assign mul_a = (st == A_POW) ? pow_mul_a : a;
    assign mul_b = (st == A_POW) ? pow_mul_b : b;
    upycore_mul u_mul (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .start_i((st == A_MUL) || ((st == A_POW) && pow_mul_start)),
        .op_a_i(mul_a), .op_b_i(mul_b),
        .result_o(mul_lo), .result_hi_o(mul_hi),
        .done_o(mul_done), .stall_o(mul_stall), .busy_o(mul_busy)
    );

    logic [63:0] pow_res;
    logic        pow_trap, pow_done, pow_stall, pow_busy;
    upycore_ipow u_pow (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .start_i(st == A_POW),
        .base_i(a), .exp_i(b),
        .mul_start_o(pow_mul_start), .mul_a_o(pow_mul_a), .mul_b_o(pow_mul_b),
        .mul_lo_i(mul_lo), .mul_hi_i(mul_hi), .mul_done_i(mul_done),
        .result_o(pow_res), .trap_o(pow_trap), .done_o(pow_done),
        .stall_o(pow_stall), .busy_o(pow_busy)
    );

    logic [63:0] quot, rem;
    logic        div_zero, div_done, div_stall, div_busy;
    upycore_div u_div (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .start_i(st == A_DIV),
        .op_a_i(a), .op_b_i(b),
        .quot_o(quot), .rem_o(rem), .div_zero_o(div_zero),
        .done_o(div_done), .stall_o(div_stall), .busy_o(div_busy)
    );

    // Float unit in binary64.
    logic [4:0]   fop;
    logic [127:0] fres;
    logic         fexc, fdone, fstall, fbusy;
    always_comb begin
        case (op)
            ALU_ADD:   fop = UPY_ALU_ADD;
            ALU_SUB:   fop = UPY_ALU_SUB;
            ALU_MUL:   fop = UPY_ALU_MUL;
            ALU_TDIV:  fop = UPY_ALU_TRUE_DIV;
            ALU_FLOOR: fop = UPY_ALU_FLOOR_DIV;
            ALU_MOD:   fop = UPY_ALU_MOD;
            ALU_POW:   fop = UPY_ALU_POWER;
            default:   fop = UPY_ALU_PASS;
        endcase
    end
    upycore_fpu u_fpu (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .start_i(st == A_FPU),
        .op_i(fop), .complex_i(1'b0),
        .op_a_i({64'd0, mpy_f32_to_f64(fa)}), .op_b_i({64'd0, mpy_f32_to_f64(fb)}),
        .result_o(fres), .exception_o(fexc), .done_o(fdone), .stall_o(fstall), .busy_o(fbusy)
    );
    // Narrow in its own continuous assignment. Inlining mpy_f64_to_f32 into
    // the result NBA makes Verilator schedule `sumf` after the read, so the
    // binary32 fraction comes back as zero.
    logic [31:0] fres32;
    assign fres32 = mpy_f64_to_f32(fres[63:0]);

    // Accept: everything that finishes in one cycle is answered here.
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            st <= A_IDLE;
            done_o <= 1'b0;
            res_o <= '0;
            rkind_o <= AK_INT;
            err_o <= AE_NONE;
            op <= '0;
            small_r <= 1'b0;
            a <= '0;
            b <= '0;
            fa <= '0;
            fb <= '0;
        end else begin
            done_o <= 1'b0;
            case (st)
                A_IDLE: if (start_i) begin
                    logic [31:0] xa, xb;
                    logic        isf, ok;
                    logic [63:0] v;
                    op <= op_i;
                    small_r <= small_i;
                    a <= a_i;
                    b <= b_i;
                    xa = a_flt_i ? a_i[31:0] : mpy_i64_to_f32(a_i);
                    xb = b_flt_i ? b_i[31:0] : mpy_i64_to_f32(b_i);
                    fa <= xa;
                    fb <= xb;
                    err_o <= AE_NONE;
                    res_o <= '0;
                    rkind_o <= AK_INT;
                    isf = a_flt_i || b_flt_i;
                    if (op_i == ALU_I2F) begin
                        res_o <= {32'd0, xa};
                        rkind_o <= AK_FLOAT;
                        st <= A_DONE;
                    end else if (op_i == ALU_F2I) begin
                        v = mpy_f32_to_i64(a_i[31:0], ok);
                        res_o <= v;
                        if (!ok) err_o <= AE_FTOI;
                        st <= A_DONE;
                    end else if (op_i >= ALU_NEG) begin
                        if (a_flt_i) begin
                            rkind_o <= AK_FLOAT;
                            case (op_i)
                                ALU_NEG: res_o <= {32'd0, ~a_i[31], a_i[30:0]};
                                ALU_POS: res_o <= {32'd0, a_i[31:0]};
                                ALU_ABS: res_o <= {32'd0, 1'b0, a_i[30:0]};
                                default: err_o <= AE_UNSUPPORTED;
                            endcase
                            st <= A_DONE;
                        end else begin
                            // The integer unit answers next cycle (A_DONE reads it).
                            if (op_i == ALU_ABS && !a_i[63]) op <= ALU_POS;
                            else if (op_i == ALU_ABS) op <= ALU_NEG;
                            st <= A_DONE;
                        end
                    end else if (op_i <= ALU_NE) begin
                        if (isf) begin
                            rkind_o <= AK_BOOL;
                            case (op_i)
                                ALU_LT: res_o <= {63'd0, mpy_f32_lt(xa, xb)};
                                ALU_GT: res_o <= {63'd0, mpy_f32_lt(xb, xa)};
                                ALU_LE: res_o <= {63'd0, mpy_f32_lt(xa, xb) || mpy_f32_eq(xa, xb)};
                                ALU_GE: res_o <= {63'd0, mpy_f32_lt(xb, xa) || mpy_f32_eq(xa, xb)};
                                ALU_EQ: res_o <= {63'd0, mpy_f32_eq(xa, xb)};
                                default: res_o <= {63'd0, !mpy_f32_eq(xa, xb)};
                            endcase
                        end
                        st <= A_DONE;
                    end else if (isf || op_i == ALU_TDIV || (op_i == ALU_POW && b_i[63])) begin
                        rkind_o <= AK_FLOAT;
                        case (op_i)
                            ALU_ADD, ALU_SUB, ALU_MUL: st <= A_FPU;
                            ALU_TDIV, ALU_FLOOR, ALU_MOD: begin
                                if (mpy_f32_zero(xb)) begin
                                    err_o <= AE_ZERO_DIV;
                                    st <= A_DONE;
                                end else begin
                                    st <= A_FPU;
                                end
                            end
                            ALU_POW: begin
                                if (mpy_f32_zero(xa) && xb[31] && !(xb[30:23] == 8'hFF && xb[22:0] == 23'd0)) begin
                                    err_o <= AE_ZERO_DIV;
                                    st <= A_DONE;
                                end else if (xa[31] && !mpy_f32_zero(xa) && !mpy_f32_nan(xa) &&
                                             !mpy_f32_integral(xb) && !mpy_f32_nan(xb) &&
                                             !(xb[30:23] == 8'hFF)) begin
                                    err_o <= AE_COMPLEX;
                                    st <= A_DONE;
                                end else begin
                                    st <= A_FPU;
                                end
                            end
                            default: begin
                                err_o <= AE_UNSUPPORTED;
                                st <= A_DONE;
                            end
                        endcase
                    end else begin
                        case (op_i)
                            ALU_MUL: st <= A_MUL;
                            ALU_FLOOR, ALU_MOD: begin
                                if (b_i == 64'd0) begin
                                    err_o <= AE_ZERO_DIV;
                                    st <= A_DONE;
                                end else begin
                                    st <= A_DIV;
                                end
                            end
                            ALU_POW: st <= A_POW;
                            ALU_MATMUL: begin
                                err_o <= AE_UNSUPPORTED;
                                st <= A_DONE;
                            end
                            default: st <= A_DONE;
                        endcase
                    end
                end
                A_MUL: if (mul_done) begin
                    res_o <= mul_lo;
                    if (mul_hi != {64{mul_lo[63]}}) err_o <= AE_OVERFLOW;
                    st <= A_IDLE;
                    done_o <= 1'b1;
                end
                A_DIV: if (div_done) begin
                    // upycore_div floors. Off the small-int range the oracle truncates.
                    if (!small_r && rem != 64'd0 && (a[63] != b[63])) begin
                        res_o <= (op == ALU_FLOOR) ? quot + 64'd1 : rem - b;
                    end else begin
                        res_o <= (op == ALU_FLOOR) ? quot : rem;
                    end
                    st <= A_IDLE;
                    done_o <= 1'b1;
                end
                A_POW: if (pow_done || pow_trap) begin
                    res_o <= pow_res;
                    if (pow_trap) err_o <= AE_OVERFLOW;
                    st <= A_IDLE;
                    done_o <= 1'b1;
                end
                A_FPU: if (fdone || fexc) begin
                    if (fexc) begin
                        // Only ** overflow is left; powf gives inf with the sign of the result.
                        res_o <= {32'd0, fa[31] && mpy_f32_odd(fb), 8'hFF, 23'd0};
                    end else begin
                        res_o <= {32'd0, fres32};
                    end
                    st <= A_IDLE;
                    done_o <= 1'b1;
                end
                A_DONE: begin
                    // Integer one-cycle ops: the unit sees the latched operands now.
                    if (rkind_o == AK_INT && err_o == AE_NONE && op != ALU_F2I) begin
                        res_o <= ires;
                        if (op <= ALU_NE) begin
                            rkind_o <= AK_BOOL;
                        end else if (iverr) begin
                            err_o <= AE_NEG_SHIFT;
                        end else if (iovf) begin
                            err_o <= AE_OVERFLOW;
                        end
                    end
                    st <= A_IDLE;
                    done_o <= 1'b1;
                end
                default: st <= A_IDLE;
            endcase
        end
    end

    // verilator lint_off UNUSEDSIGNAL
    logic unused;
    assign unused = ^{izero, mul_stall, mul_busy, pow_stall, pow_busy, div_zero, div_stall, div_busy,
                      fstall, fbusy, fres[127:64]};
    // verilator lint_on UNUSEDSIGNAL
endmodule
