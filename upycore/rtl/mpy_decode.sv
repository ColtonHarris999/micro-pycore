// MicroPython v1.29.0 bytecode decoder (py/bc0.h, py/bc.h).
//
// Instructions are variable-length byte strings. The high nibble selects the
// operand format (byte, qstr index, varuint, or a 1-byte or 2-byte branch
// offset). Five opcode ranges fold a small immediate into the opcode byte.
// There is no CACHE opcode and no EXTENDED_ARG prefix: each instruction is
// complete on its own, and a reserved encoding is not skipped.
//
// entry_o is the execution path for this opcode. It is not a new opcode
// number. Opcode bytes stay the v1.29.0 encodings.
//
// The prelude's n_state is the number of Python values (locals and the
// value stack). Call setup expands a wide value into two or four physical
// registers. This decoder does not.

// The package shares this file with the decoder modules.
// verilator lint_off DECLFILENAME
package mpy_dec;

    typedef enum logic [6:0] {
        ILLEGAL = 7'd0,
        LOAD_FAST,
        STORE_FAST,
        DELETE_FAST,
        LOAD_SMALL_INT,
        LOAD_CONST,
        PUSH_NULL,
        BINARY_OP,
        COMPARE_OP,
        CONTAINS_OP,
        IS_OP,
        CHECK_EXC_MATCH,
        UNARY_POSITIVE,
        UNARY_NEGATIVE,
        UNARY_INVERT,
        UNARY_NOT,
        LOAD_ATTR,
        LOAD_SUPER_METHOD,
        LOAD_BUILD_CLASS,
        LOAD_NAME,
        LOAD_GLOBAL,
        STORE_NAME,
        STORE_GLOBAL,
        STORE_ATTR,
        DELETE_NAME,
        DELETE_GLOBAL,
        LOAD_SUBSCR,
        STORE_SUBSCR,
        COPY,
        SWAP,
        POP_TOP,
        JUMP,
        POP_JUMP_IF_TRUE,
        POP_JUMP_IF_FALSE,
        JUMP_IF_TRUE_OR_POP,
        JUMP_IF_FALSE_OR_POP,
        SETUP_WITH,
        SETUP_EXCEPT,
        SETUP_FINALLY,
        POP_EXCEPT_JUMP,
        UNWIND_JUMP,
        WITH_CLEANUP,
        END_FINALLY,
        RAISE_LAST,
        RAISE_OBJ,
        RAISE_FROM,
        GET_ITER,
        GET_ITER_STACK,
        FOR_ITER,
        LIST_APPEND,
        MAP_ADD,
        SET_ADD,
        BUILD_TUPLE,
        BUILD_LIST,
        BUILD_MAP,
        STORE_MAP,
        BUILD_SET,
        BUILD_SLICE,
        UNPACK_SEQUENCE,
        UNPACK_EX,
        MAKE_FUNCTION,
        MAKE_FUNCTION_DEFARGS,
        MAKE_CLOSURE,
        MAKE_CLOSURE_DEFARGS,
        LOAD_DEREF,
        STORE_DEREF,
        DELETE_DEREF,
        CALL,
        CALL_KW,
        CALL_FUNCTION_EX,
        RETURN_VALUE,
        IMPORT_NAME,
        IMPORT_FROM,
        IMPORT_STAR,
        YIELD_VALUE,
        YIELD_FROM
    } entry_e;

endpackage
// verilator lint_on DECLFILENAME

module mpy_decode
    import mpy_dec::*;
(
    input  logic               instr_valid_i,
    // bytes_i[8*i +: 8] is the byte at ip+i. Eight bytes is the fetch window.
    input  logic [63:0]        bytes_i,
    input  logic [3:0]         nbytes_i,
    output logic               decoded_valid_o,
    output logic               illegal_o,
    output logic               truncated_o,
    output logic               arg_overflow_o,
    output logic [3:0]         len_o,
    output logic [7:0]         opcode_o,
    output logic [1:0]         format_o,
    output entry_e             entry_o,
    output logic               arg_valid_o,
    output logic signed [31:0] arg_o,
    output logic               extra_valid_o,
    output logic [7:0]         extra_o
);

    // py/bc0.h: MP_BC_FORMAT(op) = (0x000003a4 >> (2 * (op >> 4))) & 3.
    localparam logic [1:0] FMT_BYTE    = 2'd0;
    localparam logic [1:0] FMT_QSTR    = 2'd1;
    localparam logic [1:0] FMT_VARUINT = 2'd2;
    localparam logic [1:0] FMT_OFFSET  = 2'd3;
    // (opcode & MP_BC_MASK_EXTRA_BYTE) == 0 means one trailing byte.
    localparam logic [7:0] EXTRA_MASK = 8'h9e;

    localparam logic [7:0] BC_LOAD_CONST_SMALL_INT = 8'h22;
    localparam logic [7:0] BC_SMALL_INT_BASE       = 8'h70;
    localparam logic [7:0] BC_LOAD_FAST_BASE       = 8'hb0;
    localparam logic [7:0] BC_STORE_FAST_BASE      = 8'hc0;
    localparam logic [7:0] BC_UNARY_BASE           = 8'hd0;
    localparam logic [7:0] BC_BINARY_BASE          = 8'hd7;
    localparam logic [7:0] SMALL_INT_NUM           = 8'd64;
    localparam logic [7:0] SMALL_INT_EXCESS        = 8'd16;
    localparam logic [7:0] FAST_NUM                = 8'd16;
    localparam logic [7:0] UNARY_NUM               = 8'd4;
    localparam logic [7:0] BINARY_NUM              = 8'd35;

    function automatic logic [1:0] bc_format(input logic [3:0] hi);
        bc_format = 2'((32'h000003a4 >> {27'b0, hi, 1'b0}) & 32'h3);
    endfunction

    // Signed bias applies only to these four. Other offset opcodes, including
    // unused encodings in the same nibble, are unsigned (mpy-tool ALL_OFFSET_SIGNED).
    function automatic logic offset_is_signed(input logic [7:0] op);
        offset_is_signed = (op == 8'h40) || (op == 8'h42) ||
                           (op == 8'h43) || (op == 8'h44);
    endfunction

    // verilator lint_off UNUSEDSIGNAL
    function automatic entry_e map_entry(
        input logic [7:0] op,
        input logic signed [31:0] arg,
        output logic known
    );
        logic [7:0] imm;
        begin
            known = 1'b1;
            imm = 8'h00;
            map_entry = ILLEGAL;
            if (op >= BC_SMALL_INT_BASE &&
                op < BC_SMALL_INT_BASE + SMALL_INT_NUM) begin
                map_entry = LOAD_SMALL_INT;
            end else if (op >= BC_LOAD_FAST_BASE &&
                         op < BC_LOAD_FAST_BASE + FAST_NUM) begin
                map_entry = LOAD_FAST;
            end else if (op >= BC_STORE_FAST_BASE &&
                         op < BC_STORE_FAST_BASE + FAST_NUM) begin
                map_entry = STORE_FAST;
            end else if (op >= BC_UNARY_BASE &&
                         op < BC_UNARY_BASE + UNARY_NUM) begin
                imm = op - BC_UNARY_BASE;
                if (imm == 8'd0) map_entry = UNARY_POSITIVE;
                else if (imm == 8'd1) map_entry = UNARY_NEGATIVE;
                else if (imm == 8'd2) map_entry = UNARY_INVERT;
                else map_entry = UNARY_NOT;
            end else if (op >= BC_BINARY_BASE &&
                         op < BC_BINARY_BASE + BINARY_NUM) begin
                // Compares, in, is, and exception match share the binary range.
                imm = op - BC_BINARY_BASE;
                if (imm <= 8'd5) map_entry = COMPARE_OP;
                else if (imm == 8'd6) map_entry = CONTAINS_OP;
                else if (imm == 8'd7) map_entry = IS_OP;
                else if (imm == 8'd8) map_entry = CHECK_EXC_MATCH;
                else map_entry = BINARY_OP;
            end else begin
                case (op)
                    8'h10, 8'h23, 8'h50, 8'h51, 8'h52: map_entry = LOAD_CONST;
                    8'h11: map_entry = LOAD_NAME;
                    8'h12: map_entry = LOAD_GLOBAL;
                    8'h13, 8'h14: map_entry = LOAD_ATTR;
                    8'h15: map_entry = LOAD_SUPER_METHOD;
                    8'h16: map_entry = STORE_NAME;
                    8'h17: map_entry = STORE_GLOBAL;
                    8'h18: map_entry = STORE_ATTR;
                    8'h19: map_entry = DELETE_NAME;
                    8'h1a: map_entry = DELETE_GLOBAL;
                    8'h1b: map_entry = IMPORT_NAME;
                    8'h1c: map_entry = IMPORT_FROM;
                    8'h20: map_entry = MAKE_CLOSURE;
                    8'h21: map_entry = MAKE_CLOSURE_DEFARGS;
                    8'h22: map_entry = LOAD_SMALL_INT;
                    8'h24: map_entry = LOAD_FAST;
                    8'h25: map_entry = LOAD_DEREF;
                    8'h26: map_entry = STORE_FAST;
                    8'h27: map_entry = STORE_DEREF;
                    8'h28: map_entry = DELETE_FAST;
                    8'h29: map_entry = DELETE_DEREF;
                    8'h2a: map_entry = BUILD_TUPLE;
                    8'h2b: map_entry = BUILD_LIST;
                    8'h2c: map_entry = BUILD_MAP;
                    8'h2d: map_entry = BUILD_SET;
                    8'h2e: map_entry = BUILD_SLICE;
                    // Kind is the low two bits: 0 list, 1 dict, otherwise set.
                    8'h2f: begin
                        if (arg[1:0] == 2'd0) map_entry = LIST_APPEND;
                        else if (arg[1:0] == 2'd1) map_entry = MAP_ADD;
                        else map_entry = SET_ADD;
                    end
                    8'h30: map_entry = UNPACK_SEQUENCE;
                    8'h31: map_entry = UNPACK_EX;
                    8'h32: map_entry = MAKE_FUNCTION;
                    8'h33: map_entry = MAKE_FUNCTION_DEFARGS;
                    // n_pos is arg[7:0], n_kw is arg[15:8]. The packed varuint
                    // is the operand; nothing here widens a value to two or
                    // four registers.
                    8'h34, 8'h36: begin
                        if (arg[15:8] != 8'h00) map_entry = CALL_KW;
                        else map_entry = CALL;
                    end
                    8'h35, 8'h37: map_entry = CALL_FUNCTION_EX;
                    8'h40: map_entry = UNWIND_JUMP;
                    8'h42: map_entry = JUMP;
                    8'h43: map_entry = POP_JUMP_IF_TRUE;
                    8'h44: map_entry = POP_JUMP_IF_FALSE;
                    8'h45: map_entry = JUMP_IF_TRUE_OR_POP;
                    8'h46: map_entry = JUMP_IF_FALSE_OR_POP;
                    8'h47: map_entry = SETUP_WITH;
                    8'h48: map_entry = SETUP_EXCEPT;
                    8'h49: map_entry = SETUP_FINALLY;
                    8'h4a: map_entry = POP_EXCEPT_JUMP;
                    8'h4b: map_entry = FOR_ITER;
                    8'h53: map_entry = PUSH_NULL;
                    8'h54: map_entry = LOAD_BUILD_CLASS;
                    8'h55: map_entry = LOAD_SUBSCR;
                    8'h56: map_entry = STORE_SUBSCR;
                    8'h57, 8'h58: map_entry = COPY;
                    8'h59: map_entry = POP_TOP;
                    8'h5a, 8'h5b: map_entry = SWAP;
                    8'h5c: map_entry = WITH_CLEANUP;
                    8'h5d: map_entry = END_FINALLY;
                    8'h5e: map_entry = GET_ITER;
                    8'h5f: map_entry = GET_ITER_STACK;
                    8'h62: map_entry = STORE_MAP;
                    8'h63: map_entry = RETURN_VALUE;
                    8'h64: map_entry = RAISE_LAST;
                    8'h65: map_entry = RAISE_OBJ;
                    8'h66: map_entry = RAISE_FROM;
                    8'h67: map_entry = YIELD_VALUE;
                    8'h68: map_entry = YIELD_FROM;
                    8'h69: map_entry = IMPORT_STAR;
                    default: begin
                        known = 1'b0;
                        map_entry = ILLEGAL;
                    end
                endcase
            end
        end
    endfunction
    // verilator lint_on UNUSEDSIGNAL

    logic [3:0] nwin;
    logic [7:0] op;
    logic [1:0] fmt;
    logic [3:0] len_b;
    logic signed [31:0] arg;
    logic arg_ok;
    logic extra_ok;
    logic [7:0] extra_b;
    logic trunc;
    logic overflow;
    logic known;
    entry_e mapped;
    logic signed [63:0] acc;
    logic cont;
    logic [7:0] bv;
    logic [14:0] raw15;

    always_comb begin
        nwin = (nbytes_i > 4'd8) ? 4'd8 : nbytes_i;
        op = bytes_i[7:0];
        fmt = bc_format(op[7:4]);
        len_b = 4'd1;
        arg = 32'sd0;
        arg_ok = 1'b0;
        extra_ok = 1'b0;
        extra_b = 8'h00;
        trunc = 1'b0;
        overflow = 1'b0;
        known = 1'b0;
        mapped = ILLEGAL;
        acc = 64'sd0;
        cont = 1'b0;
        bv = 8'h00;
        raw15 = 15'h0;

        decoded_valid_o = 1'b0;
        illegal_o = 1'b0;
        truncated_o = 1'b0;
        arg_overflow_o = 1'b0;
        len_o = 4'd0;
        opcode_o = 8'h00;
        format_o = FMT_BYTE;
        entry_o = ILLEGAL;
        arg_valid_o = 1'b0;
        arg_o = 32'sd0;
        extra_valid_o = 1'b0;
        extra_o = 8'h00;

        if (instr_valid_i) begin
            opcode_o = op;
            format_o = fmt;
            if (nwin == 4'd0) begin
                trunc = 1'b1;
            end else if (fmt == FMT_QSTR || fmt == FMT_VARUINT) begin
                if (nwin < 4'd2) begin
                    trunc = 1'b1;
                end else begin
                    cont = 1'b1;
                    for (int unsigned k = 0; k < 7; k++) begin
                        if (cont && !trunc) begin
                            if ((k + 1) >= {28'b0, nwin}) begin
                                trunc = 1'b1;
                                cont = 1'b0;
                            end else begin
                                bv = bytes_i[8 * (k + 1) +: 8];
                                if (k == 0) begin
                                    acc = 64'(bv[6:0]);
                                    // Sign lives in bit 6 of the first group,
                                    // before later groups are shifted in.
                                    if ((op == BC_LOAD_CONST_SMALL_INT) && bv[6]) begin
                                        acc[63:7] = {57{1'b1}};
                                    end
                                end else begin
                                    acc = (acc << 7) | 64'(bv[6:0]);
                                end
                                cont = bv[7];
                                len_b = 4'(k + 2);
                            end
                        end
                    end
                    if (cont) trunc = 1'b1;
                end
                if (!trunc) begin
                    arg_ok = 1'b1;
                    arg = acc[31:0];
                    if (op == BC_LOAD_CONST_SMALL_INT) begin
                        overflow = (acc[63:31] != {33{acc[31]}});
                    end else begin
                        overflow = (acc[63:32] != 32'h0);
                    end
                end
            end else if (fmt == FMT_OFFSET) begin
                if (nwin < 4'd2) begin
                    trunc = 1'b1;
                end else begin
                    bv = bytes_i[15:8];
                    if (!bv[7]) begin
                        len_b = 4'd2;
                        arg_ok = 1'b1;
                        if (offset_is_signed(op)) begin
                            arg = $signed({25'b0, bv[6:0]}) - 32'sd64;
                        end else begin
                            arg = $signed({25'b0, bv[6:0]});
                        end
                    end else if (nwin < 4'd3) begin
                        trunc = 1'b1;
                    end else begin
                        raw15 = {bytes_i[23:16], bv[6:0]};
                        len_b = 4'd3;
                        arg_ok = 1'b1;
                        if (offset_is_signed(op)) begin
                            arg = $signed({17'b0, raw15}) - 32'sd16384;
                        end else begin
                            arg = $signed({17'b0, raw15});
                        end
                    end
                end
            end

            if (!trunc && ((op & EXTRA_MASK) == 8'h00)) begin
                if (len_b >= nwin) begin
                    trunc = 1'b1;
                end else begin
                    extra_b = bytes_i[8 * len_b +: 8];
                    extra_ok = 1'b1;
                    len_b = len_b + 4'd1;
                end
            end

            if (!trunc && fmt == FMT_BYTE) begin
                if (op >= BC_SMALL_INT_BASE &&
                    op < BC_SMALL_INT_BASE + SMALL_INT_NUM) begin
                    arg_ok = 1'b1;
                    arg = $signed({24'b0, op}) - 32'sd112 - 32'(SMALL_INT_EXCESS);
                end else if (op >= BC_LOAD_FAST_BASE &&
                             op < BC_LOAD_FAST_BASE + FAST_NUM) begin
                    arg_ok = 1'b1;
                    arg = $signed({24'b0, op - BC_LOAD_FAST_BASE});
                end else if (op >= BC_STORE_FAST_BASE &&
                             op < BC_STORE_FAST_BASE + FAST_NUM) begin
                    arg_ok = 1'b1;
                    arg = $signed({24'b0, op - BC_STORE_FAST_BASE});
                end else if (op >= BC_UNARY_BASE &&
                             op < BC_UNARY_BASE + UNARY_NUM) begin
                    arg_ok = 1'b1;
                    arg = $signed({24'b0, op - BC_UNARY_BASE});
                end else if (op >= BC_BINARY_BASE &&
                             op < BC_BINARY_BASE + BINARY_NUM) begin
                    arg_ok = 1'b1;
                    arg = $signed({24'b0, op - BC_BINARY_BASE});
                end
            end

            if (trunc) begin
                truncated_o = 1'b1;
            end else begin
                mapped = map_entry(op, arg, known);
                decoded_valid_o = 1'b1;
                illegal_o = !known;
                arg_overflow_o = overflow;
                len_o = len_b;
                entry_o = known ? mapped : ILLEGAL;
                arg_valid_o = arg_ok;
                arg_o = arg_ok ? arg : 32'sd0;
                extra_valid_o = extra_ok;
                extra_o = extra_ok ? extra_b : 8'h00;
            end
        end
    end

endmodule

// Bit-interleaved prelude (py/bc.h). One byte per cycle. opcode_off_o is the
// index of the first opcode. The line-info span is [line_info_off_o,
// line_info_end_o): source info after the name qstrs, and not the cells.
module mpy_prelude_decode (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        start_i,
    input  logic        byte_valid_i,
    input  logic [7:0]  byte_i,
    output logic        ready_o,
    output logic        done_o,
    output logic        error_o,
    // Python values. Not a physical-register count.
    output logic [15:0] n_state_o,
    output logic [15:0] n_exc_stack_o,
    output logic [15:0] scope_flags_o,
    output logic [15:0] n_pos_args_o,
    output logic [15:0] n_kwonly_args_o,
    output logic [15:0] n_def_pos_args_o,
    output logic [15:0] n_info_o,
    output logic [15:0] n_cell_o,
    output logic [15:0] opcode_off_o,
    output logic [15:0] line_info_off_o,
    output logic [15:0] line_info_end_o
);

    typedef enum logic [2:0] {
        ST_IDLE = 3'd0,
        ST_SIG  = 3'd1,
        ST_SIZE = 3'd2,
        ST_NAME = 3'd3,
        ST_TAIL = 3'd4,
        ST_DONE = 3'd5,
        ST_ERR  = 3'd6
    } st_e;

    st_e state_q;
    logic [31:0] idx_q;
    logic [31:0] s_q, e_q, f_q, a_q, k_q, d_q;
    logic [31:0] i_q, c_q;
    logic        sig_more_q;
    logic [3:0]  sig_n_q;
    logic [3:0]  size_n_q;
    logic [31:0] names_left_q;
    logic [31:0] source_end_q;
    logic [31:0] op_at_q;
    logic [31:0] line_off_q;
    logic [31:0] line_end_q;
    logic        fields_ok_q;

    st_e         st;
    logic [31:0] idx;
    logic [31:0] s, e, f, a, k, d;
    logic [31:0] info, cells;
    logic        sig_more;
    logic [3:0]  sig_n;
    logic [3:0]  size_n;
    logic [31:0] names_left;
    logic [31:0] source_end;
    logic [31:0] op_at;
    logic [31:0] line_off;
    logic [31:0] line_end;
    logic        fields_ok;
    logic        dn;
    logic        err;
    logic        take;
    logic        active;
    logic [31:0] z32;

    assign ready_o = (state_q != ST_DONE) && (state_q != ST_ERR);
    assign done_o = (state_q == ST_DONE);
    assign error_o = (state_q == ST_ERR);
    assign n_state_o = fields_ok_q ? s_q[15:0] : 16'h0;
    assign n_exc_stack_o = fields_ok_q ? e_q[15:0] : 16'h0;
    assign scope_flags_o = fields_ok_q ? f_q[15:0] : 16'h0;
    assign n_pos_args_o = fields_ok_q ? a_q[15:0] : 16'h0;
    assign n_kwonly_args_o = fields_ok_q ? k_q[15:0] : 16'h0;
    assign n_def_pos_args_o = fields_ok_q ? d_q[15:0] : 16'h0;
    assign n_info_o = fields_ok_q ? i_q[15:0] : 16'h0;
    assign n_cell_o = fields_ok_q ? c_q[15:0] : 16'h0;
    assign opcode_off_o = fields_ok_q ? op_at_q[15:0] : 16'h0;
    assign line_info_off_o = fields_ok_q ? line_off_q[15:0] : 16'h0;
    assign line_info_end_o = fields_ok_q ? line_end_q[15:0] : 16'h0;

    always_comb begin
        st = state_q;
        idx = idx_q;
        s = s_q;
        e = e_q;
        f = f_q;
        a = a_q;
        k = k_q;
        d = d_q;
        info = i_q;
        cells = c_q;
        sig_more = sig_more_q;
        sig_n = sig_n_q;
        size_n = size_n_q;
        names_left = names_left_q;
        source_end = source_end_q;
        op_at = op_at_q;
        line_off = line_off_q;
        line_end = line_end_q;
        fields_ok = fields_ok_q;
        dn = (state_q == ST_DONE);
        err = (state_q == ST_ERR);
        z32 = {24'b0, byte_i};
        active = (state_q == ST_SIG) || (state_q == ST_SIZE) ||
                 (state_q == ST_NAME) || (state_q == ST_TAIL);

        if (start_i) begin
            st = ST_SIG;
            idx = 32'h0;
            s = 32'h0;
            e = 32'h0;
            f = 32'h0;
            a = 32'h0;
            k = 32'h0;
            d = 32'h0;
            info = 32'h0;
            cells = 32'h0;
            sig_more = 1'b0;
            sig_n = 4'h0;
            size_n = 4'h0;
            names_left = 32'h0;
            source_end = 32'h0;
            op_at = 32'h0;
            line_off = 32'h0;
            line_end = 32'h0;
            fields_ok = 1'b0;
            dn = 1'b0;
            err = 1'b0;
        end

        take = byte_valid_i && !dn && !err && (start_i || active);

        if (take) begin
            if (idx == 32'h0000ffff) begin
                err = 1'b1;
            end else begin
                idx = idx + 32'h1;
                case (st)
                    ST_SIG: begin
                        if (!sig_more) begin
                            // xSSSSEAA
                            s = (z32 >> 3) & 32'hf;
                            e = (z32 >> 2) & 32'h1;
                            f = 32'h0;
                            a = z32 & 32'h3;
                            k = 32'h0;
                            d = 32'h0;
                            if (byte_i[7]) begin
                                sig_more = 1'b1;
                                sig_n = 4'h0;
                            end else begin
                                s = s + 32'h1;
                                st = ST_SIZE;
                                info = 32'h0;
                                cells = 32'h0;
                                size_n = 4'h0;
                            end
                        end else begin
                            // xFSSKAED, extension number sig_n. Shift amounts
                            // are widened so a 4-bit counter cannot truncate them.
                            s = s | ((z32 & 32'h30) << (32'(sig_n) * 32'd2));
                            e = e | ((z32 & 32'h02) << 32'(sig_n));
                            f = f | (((z32 & 32'h40) >> 6) << 32'(sig_n));
                            a = a | ((z32 & 32'h04) << 32'(sig_n));
                            k = k | (((z32 & 32'h08) >> 3) << 32'(sig_n));
                            d = d | ((z32 & 32'h01) << 32'(sig_n));
                            if (byte_i[7]) begin
                                if (sig_n == 4'hf) err = 1'b1;
                                else sig_n = sig_n + 4'h1;
                            end else begin
                                s = s + 32'h1;
                                st = ST_SIZE;
                                info = 32'h0;
                                cells = 32'h0;
                                size_n = 4'h0;
                            end
                        end
                        if (!err && (st == ST_SIZE) && (s > 32'h0000ffff)) begin
                            err = 1'b1;
                        end
                    end
                    ST_SIZE: begin
                        // xIIIIIIC. Six info bits and one cell bit per byte.
                        cells = cells | ((z32 & 32'h1) << 32'(size_n));
                        info = info | (((z32 & 32'h7e) >> 1) << (32'(size_n) * 32'd6));
                        if (byte_i[7]) begin
                            if (size_n >= 4'd5) err = 1'b1;
                            else size_n = size_n + 4'h1;
                        end else if ((info > 32'h0000ffff) || (cells > 32'h0000ffff)) begin
                            err = 1'b1;
                        end else begin
                            // idx is the count of bytes consumed, so it is the
                            // index of the first source-info byte.
                            source_end = idx + info;
                            op_at = source_end + cells;
                            names_left = 32'h1 + a + k;
                            if (info == 32'h0) err = 1'b1;
                            else st = ST_NAME;
                        end
                    end
                    ST_NAME: begin
                        // Name qstrs are unsigned varuints inside n_info bytes.
                        // The value is not needed to find the line-info span.
                        if (idx > source_end) begin
                            err = 1'b1;
                        end else if (!byte_i[7]) begin
                            names_left = names_left - 32'h1;
                            if (names_left == 32'h0) begin
                                line_off = idx;
                                line_end = source_end;
                                if (line_off > line_end) err = 1'b1;
                                else if (idx == op_at) begin
                                    fields_ok = 1'b1;
                                    dn = 1'b1;
                                    st = ST_DONE;
                                end else if (idx > op_at) begin
                                    err = 1'b1;
                                end else begin
                                    fields_ok = 1'b1;
                                    st = ST_TAIL;
                                end
                            end
                        end
                    end
                    ST_TAIL: begin
                        if (idx == op_at) begin
                            fields_ok = 1'b1;
                            dn = 1'b1;
                            st = ST_DONE;
                        end else if (idx > op_at) begin
                            err = 1'b1;
                        end
                    end
                    default: err = 1'b1;
                endcase
            end
            if (err) begin
                st = ST_ERR;
                dn = 1'b0;
                fields_ok = 1'b0;
            end else if (dn) begin
                st = ST_DONE;
                if ((s > 32'h0000ffff) || (e > 32'h0000ffff) ||
                    (f > 32'h0000ffff) || (a > 32'h0000ffff) ||
                    (k > 32'h0000ffff) || (d > 32'h0000ffff) ||
                    (info > 32'h0000ffff) || (cells > 32'h0000ffff) ||
                    (op_at > 32'h0000ffff) || (line_off > 32'h0000ffff) ||
                    (line_end > 32'h0000ffff)) begin
                    st = ST_ERR;
                    dn = 1'b0;
                    fields_ok = 1'b0;
                end
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            state_q <= ST_IDLE;
            idx_q <= 32'h0;
            s_q <= 32'h0;
            e_q <= 32'h0;
            f_q <= 32'h0;
            a_q <= 32'h0;
            k_q <= 32'h0;
            d_q <= 32'h0;
            i_q <= 32'h0;
            c_q <= 32'h0;
            sig_more_q <= 1'b0;
            sig_n_q <= 4'h0;
            size_n_q <= 4'h0;
            names_left_q <= 32'h0;
            source_end_q <= 32'h0;
            op_at_q <= 32'h0;
            line_off_q <= 32'h0;
            line_end_q <= 32'h0;
            fields_ok_q <= 1'b0;
        end else begin
            state_q <= st;
            idx_q <= idx;
            s_q <= s;
            e_q <= e;
            f_q <= f;
            a_q <= a;
            k_q <= k;
            d_q <= d;
            i_q <= info;
            c_q <= cells;
            sig_more_q <= sig_more;
            sig_n_q <= sig_n;
            size_n_q <= size_n;
            names_left_q <= names_left;
            source_end_q <= source_end;
            op_at_q <= op_at;
            line_off_q <= line_off;
            line_end_q <= line_end;
            fields_ok_q <= fields_ok;
        end
    end

endmodule
