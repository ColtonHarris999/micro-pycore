// MicroPython container growth (pivot plan §0.6 and §0.7).
//
// One command at a time. The core is frozen, so this port is the only
// data master. A slot is one 32-bit payload plus its tag nibble. The
// memory system packs eight nibbles to a word; this port does not.
//
// MUT_COLLEC kind is the pointer's low 2 bits: 0 list, 1 dict, 2 set,
// 3 bytearray. The object address clears those bits. The object itself
// never moves. Growth allocates a new item array, entry table, or byte
// buffer at heap_ptr and publishes the header only after that block is
// complete. A short heap writes nothing.
//
// List object (two words, §0.6):
//   +0 length
//   +4 pointer to item 0
// The item array is a separate block: one word per item. Its capacity
// word sits immediately in front of item 0, at pointer-4, so the list
// object stays two words. Empty lists use a null item pointer and
// capacity 0. A full list doubles (minimum 4), matching py/objlist.c.
//
// Dict and set objects (four words):
//   +0 used in [30:0], object indicator in bit 31
//   +4 allocated slots
//   +8 entry-table pointer
//   +12 types-table pointer (left alone; 0 until the indicator is set)
// Dict entries are a key word then a value word. Set entries are one
// word. Empty is CONTROL/empty. A deleted slot is CONTROL/tombstone
// and is not copied.
//
// Resize uses the py/map.c size table and linear probing,
// pos = hash % alloc, walking old slots from index 0. Bit 31 clear:
// this unit hashes every key. Bit 31 set and a computed-hash dict is
// supplied: that dict's keys and values are ints, the key is the old
// slot number, and the value is the hash. Slots present there keep
// that hash. Every other key is hashed here.
//
// Hashes this unit computes: None, True, False (as ints 0 and 1),
// ints (the value), binary32 floats (truncating cast, the ESP32
// non-high-quality hash), qstrs (a pool word), strings (stored hash,
// or djb2 masked to 16 bits), bytes (djb2), and tuples of those
// (empty-tuple seed plus the element hashes). An OBJECT whose type
// header tp_hash is empty CONTROL is hashed by address. tp_hash is
// type word 5 (byte offset 20): tp_dict, tp_base, tp_name, then
// tp_hash. It is not an entry in tp_dict. None there is unhashable.
// A function there is a Python __hash__, which is not called; the
// core must have put that slot in the computed-hash dict.
//
// Header machine words are stored with an empty CONTROL tag. The
// collector follows them by the §0.6 layout. Item slots keep the
// value's own tag.

`timescale 1ns/1ps

module mpy_container #(
    parameter logic [31:0] TUPLE_HASH_SEED = 32'd0
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    input  logic        cmd_valid_i,
    output logic        cmd_ready_o,
    input  logic [6:0]  cmd_op_i,
    input  logic [31:0] cmd_obj_i,
    input  logic [31:0] cmd_b_i,
    input  logic [3:0]  cmd_b_tag_i,
    input  logic [31:0] cmd_heap_ptr_i,
    input  logic [31:0] cmd_heap_limit_i,
    // Word qstr_hash_base + 4*id is that qstr's hash. 0 means "no pool".
    input  logic [31:0] qstr_hash_base_i,

    output logic        dr_valid_o,
    input  logic        dr_ready_i,
    output logic        dr_ok_o,
    output logic        dr_short_o,
    output logic        dr_fault_o,
    output logic [31:0] dr_heap_o,
    output logic [31:0] dr_need_o,
    output logic        cr_valid_o,
    output logic        idle_o,

    output logic        req_o,
    output logic        we_o,
    output logic [31:0] addr_o,
    output logic [31:0] wdata_o,
    output logic [3:0]  wtag_o,
    input  logic        ack_i,
    input  logic        fault_i,
    input  logic [31:0] rdata_i,
    input  logic [3:0]  rtag_i
);
    localparam logic [3:0] MPY_TAG_CONTROL = 4'b0000;
    localparam logic [3:0] MPY_TAG_INT     = 4'b0001;
    localparam logic [3:0] MPY_TAG_FLOAT   = 4'b0011;
    localparam logic [3:0] MPY_TAG_QSTR    = 4'b0110;
    localparam logic [3:0] MPY_TAG_STR     = 4'b1000;
    localparam logic [3:0] MPY_TAG_TUPLE   = 4'b1001;
    localparam logic [3:0] MPY_TAG_BYTES   = 4'b1101;
    localparam logic [3:0] MPY_TAG_OBJECT  = 4'b1110;

    localparam logic [3:0] MPY_CTL_EMPTY = 4'd0;
    localparam logic [3:0] MPY_CTL_NONE  = 4'd1;
    localparam logic [3:0] MPY_CTL_TOMB  = 4'd3;
    localparam logic [3:0] MPY_CTL_FALSE = 4'd4;
    localparam logic [3:0] MPY_CTL_TRUE  = 4'd5;

    localparam logic [1:0] MPY_KIND_LIST = 2'd0;
    localparam logic [1:0] MPY_KIND_DICT = 2'd1;
    localparam logic [1:0] MPY_KIND_SET  = 2'd2;
    localparam logic [1:0] MPY_KIND_BA   = 2'd3;

    localparam logic [6:0] MPY_OP_L_APPEND = 7'd1;
    localparam logic [6:0] MPY_OP_D_RESIZE = 7'd2;
    localparam logic [6:0] MPY_OP_S_RESIZE = 7'd3;
    localparam logic [6:0] MPY_OP_B_GROW   = 7'd4;

    localparam logic [31:0] MPY_HASH_NONE = 32'd6;
    localparam int MPY_TU_DEPTH = 4;

    typedef enum logic [7:0] {
        ST_IDLE,
        ST_L_LEN, ST_L_PTR, ST_L_CAP, ST_L_PLAN,
        ST_L_WCAP, ST_L_RD, ST_L_WR, ST_L_APP, ST_L_Z, ST_L_WLEN, ST_L_WPTR,
        ST_B_LEN, ST_B_CAP, ST_B_PTR, ST_B_PLAN,
        ST_B_RD, ST_B_WR, ST_B_Z, ST_B_WLEN, ST_B_WCAP, ST_B_WPTR,
        ST_D_W0, ST_D_W1, ST_D_W2, ST_D_W3,
        ST_CH_W0, ST_CH_W1, ST_CH_W2,
        ST_D_PLAN, ST_D_Z, ST_D_KEY, ST_D_VAL, ST_D_HASH,
        ST_CH_PR, ST_CH_VAL,
        ST_H_START, ST_H_DISP,
        ST_H_SL, ST_H_SH, ST_H_SP, ST_H_BD, ST_H_ST,
        ST_H_BL, ST_H_BP,
        ST_H_TL, ST_H_TE, ST_H_TA,
        ST_H_OT, ST_H_OH, ST_H_QS,
        ST_D_PRB, ST_D_PK, ST_D_WK, ST_D_WV,
        ST_D_P0, ST_D_P1, ST_D_P2, ST_D_P3
    } phase_e;

    phase_e phase_r;
    phase_e err_phase_r;

    logic        req_r, we_r;
    logic [31:0] addr_r, wdata_r;
    logic [3:0]  wtag_r;

    logic        dr_valid_r, dr_ok_r, dr_short_r, dr_fault_r;
    logic [31:0] dr_heap_r, dr_need_r;

    logic [31:0] obj_r, heap_r, heap_end_r, limit_r;
    logic        is_set_r, inplace_r, ind_r, ch_on_r, in_tuple_r, h_store_r;
    logic [31:0] len_r, cap_r, new_cap_r, nlen_r;
    logic [31:0] old_ptr_r, new_ptr_r;
    logic [31:0] idx_r, words_r, copy_n_r;
    logic [3:0]  elem_tag_r, hold_tag_r, key_tag_r, val_tag_r, h_tag_r;
    logic [31:0] elem_val_r, hold_val_r, key_val_r, val_val_r, h_val_r;
    logic [31:0] slots_r, new_slots_r, table_r, types_r;
    logic [31:0] ch_raw_r, ch_obj_r, ch_alloc_r, ch_table_r, ch_pos_r, ch_seen_r;
    logic [31:0] slot_i_r, placed_r, hash_r, probe_r, probe_n_r;
    logic [31:0] h_len_r, h_ptr_r, h_acc_r, h_idx_r, h_obj_r;
    logic [1:0]  tu_sp_r;
    logic [31:0] tu_base_r [0:MPY_TU_DEPTH-1];
    logic [31:0] tu_len_r  [0:MPY_TU_DEPTH-1];
    logic [31:0] tu_idx_r  [0:MPY_TU_DEPTH-1];
    logic [31:0] tu_acc_r  [0:MPY_TU_DEPTH-1];

    assign cmd_ready_o = (phase_r == ST_IDLE) && !req_r && !dr_valid_r;
    assign dr_valid_o  = dr_valid_r;
    assign dr_ok_o     = dr_ok_r;
    assign dr_short_o  = dr_short_r;
    assign dr_fault_o  = dr_fault_r;
    assign dr_heap_o   = dr_heap_r;
    assign dr_need_o   = dr_need_r;
    assign cr_valid_o  = dr_valid_r && dr_ok_r;
    assign idle_o      = cmd_ready_o;
    assign req_o       = req_r;
    assign we_o        = we_r;
    assign addr_o      = addr_r;
    assign wdata_o     = wdata_r;
    assign wtag_o      = wtag_r;

    function automatic logic mpy_skip(input logic [3:0] tag, input logic [31:0] val);
        mpy_skip = (tag == MPY_TAG_CONTROL) &&
                   ((val[3:0] == MPY_CTL_EMPTY) || (val[3:0] == MPY_CTL_TOMB));
    endfunction

    function automatic logic [31:0] mpy_umod(input logic [31:0] n, input logic [31:0] d);
        logic [31:0] r;
        integer i;
        begin
            r = 32'd0;
            if (d != 32'd0) begin
                for (i = 31; i >= 0; i = i - 1) begin
                    r = {r[30:0], n[i]};
                    if (r >= d)
                        r = r - d;
                end
            end
            mpy_umod = r;
        end
    endfunction

    // py/map.c hash_allocation_sizes. x is the smallest acceptable size
    // (old allocation + 1). 0 means the table cannot grow.
    function automatic logic [31:0] mpy_next_alloc(input logic [31:0] x);
        if (x <= 32'd2)         mpy_next_alloc = 32'd2;
        else if (x <= 32'd4)    mpy_next_alloc = 32'd4;
        else if (x <= 32'd6)    mpy_next_alloc = 32'd6;
        else if (x <= 32'd8)    mpy_next_alloc = 32'd8;
        else if (x <= 32'd10)   mpy_next_alloc = 32'd10;
        else if (x <= 32'd12)   mpy_next_alloc = 32'd12;
        else if (x <= 32'd17)   mpy_next_alloc = 32'd17;
        else if (x <= 32'd23)   mpy_next_alloc = 32'd23;
        else if (x <= 32'd29)   mpy_next_alloc = 32'd29;
        else if (x <= 32'd37)   mpy_next_alloc = 32'd37;
        else if (x <= 32'd47)   mpy_next_alloc = 32'd47;
        else if (x <= 32'd59)   mpy_next_alloc = 32'd59;
        else if (x <= 32'd73)   mpy_next_alloc = 32'd73;
        else if (x <= 32'd97)   mpy_next_alloc = 32'd97;
        else if (x <= 32'd127)  mpy_next_alloc = 32'd127;
        else if (x <= 32'd167)  mpy_next_alloc = 32'd167;
        else if (x <= 32'd223)  mpy_next_alloc = 32'd223;
        else if (x <= 32'd293)  mpy_next_alloc = 32'd293;
        else if (x <= 32'd389)  mpy_next_alloc = 32'd389;
        else if (x <= 32'd521)  mpy_next_alloc = 32'd521;
        else if (x <= 32'd691)  mpy_next_alloc = 32'd691;
        else if (x <= 32'd919)  mpy_next_alloc = 32'd919;
        else if (x <= 32'd1223) mpy_next_alloc = 32'd1223;
        else if (x <= 32'd1627) mpy_next_alloc = 32'd1627;
        else if (x <= 32'd2161) mpy_next_alloc = 32'd2161;
        else if (x <= 32'd3229) mpy_next_alloc = 32'd3229;
        else if (x <= 32'd4831) mpy_next_alloc = 32'd4831;
        else if (x <= 32'd7243) mpy_next_alloc = 32'd7243;
        else if (x <= 32'd10861) mpy_next_alloc = 32'd10861;
        else if (x <= 32'd16273) mpy_next_alloc = 32'd16273;
        else if (x <= 32'd24407) mpy_next_alloc = 32'd24407;
        else if (x <= 32'd36607) mpy_next_alloc = 32'd36607;
        else if (x <= 32'd54907) mpy_next_alloc = 32'd54907;
        else if (x > 32'hAAAA_AAA9)
            mpy_next_alloc = 32'd0;
        else
            mpy_next_alloc = (x + (x >> 1)) | 32'd1;
    endfunction

    function automatic logic [31:0] mpy_f32_trunc(input logic [31:0] bits);
        logic        sign;
        logic [7:0]  exp;
        logic [22:0] frac;
        logic [31:0] sig, mag;
        integer      ue;
        begin
            sign = bits[31];
            exp  = bits[30:23];
            frac = bits[22:0];
            if (exp == 8'hFF) begin
                if (frac != 23'd0)
                    mpy_f32_trunc = 32'd0;
                else
                    mpy_f32_trunc = sign ? 32'h8000_0000 : 32'h7FFF_FFFF;
            end else if (exp < 8'd127) begin
                mpy_f32_trunc = 32'd0;
            end else begin
                ue = integer'(exp) - 127;
                if (ue >= 31) begin
                    mpy_f32_trunc = sign ? 32'h8000_0000 : 32'h7FFF_FFFF;
                end else begin
                    sig = {8'b0, 1'b1, frac};
                    if (ue >= 23)
                        mag = sig << (ue - 23);
                    else
                        mag = sig >> (23 - ue);
                    if (sign)
                        mpy_f32_trunc = (~mag) + 32'd1;
                    else
                        mpy_f32_trunc = mag;
                end
            end
        end
    endfunction

    // [32] set when the tag has an immediate hash. None matches the
    // 32-bit REPR_A immediate (value 6). False is 0 and True is 1.
    function automatic logic [32:0] mpy_imm_hash(input logic [3:0] tag,
                                                 input logic [31:0] val);
        if (tag == MPY_TAG_CONTROL && val[3:0] == MPY_CTL_NONE)
            mpy_imm_hash = {1'b1, MPY_HASH_NONE};
        else if (tag == MPY_TAG_CONTROL && val[3:0] == MPY_CTL_FALSE)
            mpy_imm_hash = {1'b1, 32'd0};
        else if (tag == MPY_TAG_CONTROL && val[3:0] == MPY_CTL_TRUE)
            mpy_imm_hash = {1'b1, 32'd1};
        else if (tag == MPY_TAG_INT)
            mpy_imm_hash = {1'b1, val};
        else if (tag == MPY_TAG_FLOAT)
            mpy_imm_hash = {1'b1, mpy_f32_trunc(val)};
        else
            mpy_imm_hash = 33'd0;
    endfunction

    function automatic logic [31:0] mpy_djb2_word(input logic [31:0] hash,
                                                  input logic [31:0] word,
                                                  input logic [2:0] nbytes);
        logic [31:0] h;
        integer i;
        begin
            h = hash;
            for (i = 0; i < 4; i = i + 1) begin
                if (i < integer'(nbytes))
                    h = ((h << 5) + h) ^ {24'b0, word[8*i +: 8]};
            end
            mpy_djb2_word = h;
        end
    endfunction

    function automatic logic [31:0] mpy_djb2_mask(input logic [31:0] hash);
        logic [31:0] m;
        begin
            m = {16'd0, hash[15:0]};
            if (m == 32'd0)
                m = 32'd1;
            mpy_djb2_mask = m;
        end
    endfunction

    function automatic logic [31:0] mpy_ent(input logic [31:0] base,
                                            input logic [31:0] i,
                                            input logic        as_set);
        if (as_set)
            mpy_ent = base + (i << 2);
        else
            mpy_ent = base + (i << 3);
    endfunction

`define MPY_RD(A) \
    we_r <= 1'b0; addr_r <= (A); wdata_r <= 32'd0; wtag_r <= 4'd0; req_r <= 1'b1;
`define MPY_WR(A, D, T) \
    we_r <= 1'b1; addr_r <= (A); wdata_r <= (D); wtag_r <= (T); req_r <= 1'b1;
`define MPY_OK(H) \
    dr_valid_r <= 1'b1; dr_ok_r <= 1'b1; dr_short_r <= 1'b0; dr_fault_r <= 1'b0; \
    dr_heap_r <= (H); dr_need_r <= 32'd0; phase_r <= ST_IDLE;
`define MPY_SHORT(N) \
    dr_valid_r <= 1'b1; dr_ok_r <= 1'b0; dr_short_r <= 1'b1; dr_fault_r <= 1'b0; \
    dr_heap_r <= heap_r; dr_need_r <= (N); phase_r <= ST_IDLE;
`define MPY_FAULT \
    err_phase_r <= phase_r; \
    dr_valid_r <= 1'b1; dr_ok_r <= 1'b0; dr_short_r <= 1'b0; dr_fault_r <= 1'b1; \
    dr_heap_r <= heap_r; dr_need_r <= 32'd0; phase_r <= ST_IDLE;
`define MPY_HASHED(H) \
    hash_r <= (H); \
    phase_r <= (in_tuple_r ? ST_H_TA : ST_D_PRB);

    integer ri;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        logic [31:0] na, nw, nbytes, hend, ncap, sum, nleft;
        logic [32:0] ih;
        logic [2:0]  nb;
        logic [1:0]  nsp;
        if (!rst_n_i) begin
            phase_r     <= ST_IDLE;
            err_phase_r <= ST_IDLE;
            req_r       <= 1'b0;
            we_r        <= 1'b0;
            addr_r      <= 32'd0;
            wdata_r     <= 32'd0;
            wtag_r      <= 4'd0;
            dr_valid_r  <= 1'b0;
            dr_ok_r     <= 1'b0;
            dr_short_r  <= 1'b0;
            dr_fault_r  <= 1'b0;
            dr_heap_r   <= 32'd0;
            dr_need_r   <= 32'd0;
            obj_r       <= 32'd0;
            heap_r      <= 32'd0;
            heap_end_r  <= 32'd0;
            limit_r     <= 32'd0;
            is_set_r    <= 1'b0;
            inplace_r   <= 1'b0;
            ind_r       <= 1'b0;
            ch_on_r     <= 1'b0;
            in_tuple_r  <= 1'b0;
            h_store_r   <= 1'b0;
            len_r       <= 32'd0;
            cap_r       <= 32'd0;
            new_cap_r   <= 32'd0;
            nlen_r      <= 32'd0;
            old_ptr_r   <= 32'd0;
            new_ptr_r   <= 32'd0;
            idx_r       <= 32'd0;
            words_r     <= 32'd0;
            copy_n_r    <= 32'd0;
            elem_tag_r  <= 4'd0;
            hold_tag_r  <= 4'd0;
            key_tag_r   <= 4'd0;
            val_tag_r   <= 4'd0;
            h_tag_r     <= 4'd0;
            elem_val_r  <= 32'd0;
            hold_val_r  <= 32'd0;
            key_val_r   <= 32'd0;
            val_val_r   <= 32'd0;
            h_val_r     <= 32'd0;
            slots_r     <= 32'd0;
            new_slots_r <= 32'd0;
            table_r     <= 32'd0;
            types_r     <= 32'd0;
            ch_raw_r    <= 32'd0;
            ch_obj_r    <= 32'd0;
            ch_alloc_r  <= 32'd0;
            ch_table_r  <= 32'd0;
            ch_pos_r    <= 32'd0;
            ch_seen_r   <= 32'd0;
            slot_i_r    <= 32'd0;
            placed_r    <= 32'd0;
            hash_r      <= 32'd0;
            probe_r     <= 32'd0;
            probe_n_r   <= 32'd0;
            h_len_r     <= 32'd0;
            h_ptr_r     <= 32'd0;
            h_acc_r     <= 32'd0;
            h_idx_r     <= 32'd0;
            h_obj_r     <= 32'd0;
            tu_sp_r     <= 2'd0;
            for (ri = 0; ri < MPY_TU_DEPTH; ri = ri + 1) begin
                tu_base_r[ri] <= 32'd0;
                tu_len_r[ri]  <= 32'd0;
                tu_idx_r[ri]  <= 32'd0;
                tu_acc_r[ri]  <= 32'd0;
            end
        end else begin
            if (dr_valid_r && dr_ready_i)
                dr_valid_r <= 1'b0;

            if (req_r && ack_i) begin
                req_r <= 1'b0;
                if (fault_i) begin
                    `MPY_FAULT
                end else begin
                    case (phase_r)
                        ST_L_LEN: begin
                            len_r   <= rdata_i;
                            phase_r <= ST_L_PTR;
                        end
                        ST_L_PTR: begin
                            old_ptr_r <= rdata_i;
                            if (rdata_i == 32'd0) begin
                                cap_r   <= 32'd0;
                                phase_r <= ST_L_PLAN;
                            end else if (rdata_i < 32'd4) begin
                                `MPY_FAULT
                            end else begin
                                phase_r <= ST_L_CAP;
                            end
                        end
                        ST_L_CAP: begin
                            cap_r   <= rdata_i;
                            phase_r <= ST_L_PLAN;
                        end
                        ST_L_WCAP: begin
                            idx_r   <= 32'd0;
                            phase_r <= (len_r == 32'd0) ? ST_L_APP : ST_L_RD;
                        end
                        ST_L_RD: begin
                            hold_tag_r <= rtag_i;
                            hold_val_r <= rdata_i;
                            phase_r    <= ST_L_WR;
                        end
                        ST_L_WR: begin
                            if (idx_r + 32'd1 == len_r) begin
                                phase_r <= ST_L_APP;
                            end else begin
                                idx_r   <= idx_r + 32'd1;
                                phase_r <= ST_L_RD;
                            end
                        end
                        ST_L_APP: begin
                            if (inplace_r || (nlen_r == new_cap_r))
                                phase_r <= ST_L_WLEN;
                            else begin
                                idx_r   <= nlen_r;
                                phase_r <= ST_L_Z;
                            end
                        end
                        ST_L_Z: begin
                            if (idx_r + 32'd1 == new_cap_r)
                                phase_r <= ST_L_WLEN;
                            else begin
                                idx_r   <= idx_r + 32'd1;
                                phase_r <= ST_L_Z;
                            end
                        end
                        ST_L_WLEN: begin
                            if (inplace_r) begin
                                `MPY_OK(heap_r)
                            end else begin
                                phase_r <= ST_L_WPTR;
                            end
                        end
                        ST_L_WPTR: begin
                            `MPY_OK(heap_end_r)
                        end

                        ST_B_LEN: begin
                            len_r   <= rdata_i;
                            phase_r <= ST_B_CAP;
                        end
                        ST_B_CAP: begin
                            cap_r   <= rdata_i;
                            phase_r <= ST_B_PTR;
                        end
                        ST_B_PTR: begin
                            old_ptr_r <= rdata_i;
                            phase_r   <= ST_B_PLAN;
                        end
                        ST_B_RD: begin
                            hold_val_r <= rdata_i;
                            phase_r    <= ST_B_WR;
                        end
                        ST_B_WR: begin
                            if (idx_r + 32'd1 == copy_n_r) begin
                                if (copy_n_r == words_r)
                                    phase_r <= ST_B_WLEN;
                                else begin
                                    idx_r   <= copy_n_r;
                                    phase_r <= ST_B_Z;
                                end
                            end else begin
                                idx_r   <= idx_r + 32'd1;
                                phase_r <= ST_B_RD;
                            end
                        end
                        ST_B_Z: begin
                            if (idx_r + 32'd1 == words_r)
                                phase_r <= ST_B_WLEN;
                            else begin
                                idx_r   <= idx_r + 32'd1;
                                phase_r <= ST_B_Z;
                            end
                        end
                        ST_B_WLEN: phase_r <= ST_B_WCAP;
                        ST_B_WCAP: phase_r <= ST_B_WPTR;
                        ST_B_WPTR: begin
                            `MPY_OK(heap_end_r)
                        end

                        ST_D_W0: begin
                            ind_r   <= rdata_i[31];
                            len_r   <= {1'b0, rdata_i[30:0]};
                            phase_r <= ST_D_W1;
                        end
                        ST_D_W1: begin
                            slots_r <= rdata_i;
                            phase_r <= ST_D_W2;
                        end
                        ST_D_W2: begin
                            table_r <= rdata_i;
                            phase_r <= ST_D_W3;
                        end
                        ST_D_W3: begin
                            types_r <= rdata_i;
                            // ind_r was captured from word 0. Bit 31 set
                            // selects the computed-hash dict in cmd_b.
                            if (ind_r && (ch_raw_r != 32'd0)) begin
                                if (ch_raw_r[1:0] != MPY_KIND_DICT) begin
                                    `MPY_FAULT
                                end else begin
                                    ch_on_r  <= 1'b1;
                                    ch_obj_r <= {ch_raw_r[31:2], 2'b00};
                                    phase_r  <= ST_CH_W0;
                                end
                            end else begin
                                ch_on_r <= 1'b0;
                                phase_r <= ST_D_PLAN;
                            end
                        end
                        ST_CH_W0: phase_r <= ST_CH_W1;
                        ST_CH_W1: begin
                            ch_alloc_r <= rdata_i;
                            phase_r    <= ST_CH_W2;
                        end
                        ST_CH_W2: begin
                            ch_table_r <= rdata_i;
                            phase_r    <= ST_D_PLAN;
                        end
                        ST_D_Z: begin
                            if (idx_r + 32'd1 == words_r) begin
                                slot_i_r <= 32'd0;
                                placed_r <= 32'd0;
                                phase_r  <= (slots_r == 32'd0) ? ST_D_P0 : ST_D_KEY;
                            end else begin
                                idx_r   <= idx_r + 32'd1;
                                phase_r <= ST_D_Z;
                            end
                        end
                        ST_D_KEY: begin
                            if (mpy_skip(rtag_i, rdata_i)) begin
                                if (slot_i_r + 32'd1 == slots_r)
                                    phase_r <= ST_D_P0;
                                else begin
                                    slot_i_r <= slot_i_r + 32'd1;
                                    phase_r  <= ST_D_KEY;
                                end
                            end else begin
                                key_tag_r <= rtag_i;
                                key_val_r <= rdata_i;
                                phase_r   <= is_set_r ? ST_D_HASH : ST_D_VAL;
                            end
                        end
                        ST_D_VAL: begin
                            val_tag_r <= rtag_i;
                            val_val_r <= rdata_i;
                            phase_r   <= ST_D_HASH;
                        end
                        ST_CH_PR: begin
                            if (mpy_skip(rtag_i, rdata_i)) begin
                                phase_r <= ST_H_START;
                            end else if ((rtag_i == MPY_TAG_INT) && (rdata_i == slot_i_r)) begin
                                phase_r <= ST_CH_VAL;
                            end else if (ch_seen_r + 32'd1 == ch_alloc_r) begin
                                phase_r <= ST_H_START;
                            end else begin
                                ch_seen_r <= ch_seen_r + 32'd1;
                                if (ch_pos_r + 32'd1 == ch_alloc_r)
                                    ch_pos_r <= 32'd0;
                                else
                                    ch_pos_r <= ch_pos_r + 32'd1;
                                phase_r <= ST_CH_PR;
                            end
                        end
                        ST_CH_VAL: begin
                            if (rtag_i != MPY_TAG_INT) begin
                                `MPY_FAULT
                            end else begin
                                `MPY_HASHED(rdata_i)
                            end
                        end

                        ST_H_SL: begin
                            h_len_r <= rdata_i;
                            phase_r <= ST_H_SH;
                        end
                        ST_H_SH: begin
                            if (rdata_i != 32'd0) begin
                                `MPY_HASHED(rdata_i)
                            end else begin
                                phase_r <= ST_H_SP;
                            end
                        end
                        ST_H_SP: begin
                            h_ptr_r <= rdata_i;
                            h_acc_r <= 32'd5381;
                            h_idx_r <= 32'd0;
                            if (h_len_r == 32'd0) begin
                                hash_r <= mpy_djb2_mask(32'd5381);
                                if (h_store_r)
                                    phase_r <= ST_H_ST;
                                else begin
                                    `MPY_HASHED(mpy_djb2_mask(32'd5381))
                                end
                            end else begin
                                phase_r <= ST_H_BD;
                            end
                        end
                        ST_H_BL: begin
                            h_len_r <= rdata_i;
                            phase_r <= ST_H_BP;
                        end
                        ST_H_BP: begin
                            h_ptr_r   <= rdata_i;
                            h_acc_r   <= 32'd5381;
                            h_idx_r   <= 32'd0;
                            h_store_r <= 1'b0;
                            if (h_len_r == 32'd0) begin
                                `MPY_HASHED(mpy_djb2_mask(32'd5381))
                            end else begin
                                phase_r <= ST_H_BD;
                            end
                        end
                        ST_H_BD: begin
                            nleft = h_len_r - h_idx_r;
                            nb    = (nleft > 32'd4) ? 3'd4 : nleft[2:0];
                            sum   = mpy_djb2_word(h_acc_r, rdata_i, nb);
                            h_acc_r <= sum;
                            h_idx_r <= h_idx_r + {29'd0, nb};
                            if (h_idx_r + {29'd0, nb} >= h_len_r) begin
                                hash_r <= mpy_djb2_mask(sum);
                                if (h_store_r)
                                    phase_r <= ST_H_ST;
                                else begin
                                    `MPY_HASHED(mpy_djb2_mask(sum))
                                end
                            end else begin
                                phase_r <= ST_H_BD;
                            end
                        end
                        ST_H_ST: begin
                            `MPY_HASHED(hash_r)
                        end
                        ST_H_TL: begin
                            tu_len_r[tu_sp_r] <= rdata_i;
                            tu_idx_r[tu_sp_r] <= 32'd0;
                            tu_acc_r[tu_sp_r] <= TUPLE_HASH_SEED;
                            if (rdata_i == 32'd0) begin
                                hash_r <= TUPLE_HASH_SEED;
                                if (tu_sp_r == 2'd0) begin
                                    in_tuple_r <= 1'b0;
                                    phase_r    <= ST_D_PRB;
                                end else begin
                                    tu_sp_r <= tu_sp_r - 2'd1;
                                    phase_r <= ST_H_TA;
                                end
                            end else begin
                                phase_r <= ST_H_TE;
                            end
                        end
                        ST_H_TE: begin
                            if (rtag_i == MPY_TAG_TUPLE) begin
                                if (tu_sp_r == 2'(MPY_TU_DEPTH - 1)) begin
                                    `MPY_FAULT
                                end else begin
                                    nsp = tu_sp_r + 2'd1;
                                    tu_sp_r          <= nsp;
                                    tu_base_r[nsp]   <= rdata_i;
                                    phase_r          <= ST_H_TL;
                                end
                            end else begin
                                h_tag_r <= rtag_i;
                                h_val_r <= rdata_i;
                                phase_r <= ST_H_DISP;
                            end
                        end
                        ST_H_OT: begin
                            if (rdata_i == 32'd0) begin
                                `MPY_FAULT
                            end else begin
                                h_ptr_r <= rdata_i;
                                phase_r <= ST_H_OH;
                            end
                        end
                        ST_H_OH: begin
                            // Type word 5. Empty CONTROL is the default
                            // address hash. None is unhashable. Any other
                            // tag is a function; do not fetch it.
                            if ((rtag_i == MPY_TAG_CONTROL) &&
                                (rdata_i[3:0] == MPY_CTL_EMPTY)) begin
                                `MPY_HASHED(h_obj_r)
                            end else begin
                                `MPY_FAULT
                            end
                        end
                        ST_H_QS: begin
                            `MPY_HASHED(rdata_i)
                        end

                        ST_D_PK: begin
                            if (mpy_skip(rtag_i, rdata_i)) begin
                                phase_r <= ST_D_WK;
                            end else if (probe_n_r + 32'd1 == new_slots_r) begin
                                `MPY_FAULT
                            end else begin
                                probe_n_r <= probe_n_r + 32'd1;
                                if (probe_r + 32'd1 == new_slots_r)
                                    probe_r <= 32'd0;
                                else
                                    probe_r <= probe_r + 32'd1;
                                phase_r <= ST_D_PK;
                            end
                        end
                        ST_D_WK: begin
                            if (is_set_r) begin
                                placed_r <= placed_r + 32'd1;
                                if (slot_i_r + 32'd1 == slots_r)
                                    phase_r <= ST_D_P0;
                                else begin
                                    slot_i_r <= slot_i_r + 32'd1;
                                    phase_r  <= ST_D_KEY;
                                end
                            end else begin
                                phase_r <= ST_D_WV;
                            end
                        end
                        ST_D_WV: begin
                            placed_r <= placed_r + 32'd1;
                            if (slot_i_r + 32'd1 == slots_r)
                                phase_r <= ST_D_P0;
                            else begin
                                slot_i_r <= slot_i_r + 32'd1;
                                phase_r  <= ST_D_KEY;
                            end
                        end
                        ST_D_P0: phase_r <= ST_D_P1;
                        ST_D_P1: phase_r <= ST_D_P2;
                        ST_D_P2: phase_r <= ST_D_P3;
                        ST_D_P3: begin
                            `MPY_OK(heap_end_r)
                        end
                        default: begin
                            `MPY_FAULT
                        end
                    endcase
                end
            end else if (!req_r) begin
                case (phase_r)
                    ST_IDLE: begin
                        if (cmd_valid_i && !dr_valid_r) begin
                            obj_r      <= {cmd_obj_i[31:2], 2'b00};
                            heap_r     <= cmd_heap_ptr_i;
                            heap_end_r <= cmd_heap_ptr_i;
                            limit_r    <= cmd_heap_limit_i;
                            elem_tag_r <= cmd_b_tag_i;
                            elem_val_r <= cmd_b_i;
                            ch_raw_r   <= cmd_b_i;
                            ch_on_r    <= 1'b0;
                            in_tuple_r <= 1'b0;
                            is_set_r   <= (cmd_op_i == MPY_OP_S_RESIZE);
                            inplace_r  <= 1'b0;
                            if ((cmd_obj_i[31:2] == 30'd0) ||
                                (cmd_heap_ptr_i[1:0] != 2'b00)) begin
                                `MPY_FAULT
                            end else if (cmd_op_i == MPY_OP_L_APPEND) begin
                                if (cmd_obj_i[1:0] != MPY_KIND_LIST) begin
                                    `MPY_FAULT
                                end else begin
                                    phase_r <= ST_L_LEN;
                                end
                            end else if (cmd_op_i == MPY_OP_D_RESIZE) begin
                                if (cmd_obj_i[1:0] != MPY_KIND_DICT) begin
                                    `MPY_FAULT
                                end else begin
                                    phase_r <= ST_D_W0;
                                end
                            end else if (cmd_op_i == MPY_OP_S_RESIZE) begin
                                if (cmd_obj_i[1:0] != MPY_KIND_SET) begin
                                    `MPY_FAULT
                                end else begin
                                    phase_r <= ST_D_W0;
                                end
                            end else if (cmd_op_i == MPY_OP_B_GROW) begin
                                if (cmd_obj_i[1:0] != MPY_KIND_BA) begin
                                    `MPY_FAULT
                                end else begin
                                    phase_r <= ST_B_LEN;
                                end
                            end else begin
                                `MPY_FAULT
                            end
                        end
                    end

                    ST_L_LEN: begin
                        `MPY_RD(obj_r)
                    end
                    ST_L_PTR: begin
                        `MPY_RD(obj_r + 32'd4)
                    end
                    ST_L_CAP: begin
                        `MPY_RD(old_ptr_r - 32'd4)
                    end
                    ST_L_PLAN: begin
                        if (len_r == 32'hFFFF_FFFF) begin
                            `MPY_FAULT
                        end else if (cap_r > len_r) begin
                            inplace_r <= 1'b1;
                            nlen_r    <= len_r + 32'd1;
                            phase_r   <= ST_L_APP;
                        end else begin
                            ncap = (cap_r == 32'd0) ? 32'd4 : (cap_r << 1);
                            if ((cap_r != 32'd0) && (cap_r[31] || (ncap <= cap_r))) begin
                                `MPY_FAULT
                            end else if (ncap < (len_r + 32'd1)) begin
                                `MPY_FAULT
                            end else begin
                                nbytes = (ncap + 32'd1) << 2;
                                hend   = heap_r + nbytes;
                                if (hend < heap_r) begin
                                    `MPY_FAULT
                                end else if (hend > limit_r) begin
                                    `MPY_SHORT(nbytes)
                                end else begin
                                    inplace_r  <= 1'b0;
                                    new_cap_r  <= ncap;
                                    nlen_r     <= len_r + 32'd1;
                                    new_ptr_r  <= heap_r + 32'd4;
                                    heap_end_r <= hend;
                                    phase_r    <= ST_L_WCAP;
                                end
                            end
                        end
                    end
                    ST_L_WCAP: begin
                        `MPY_WR(heap_r, new_cap_r, MPY_TAG_CONTROL)
                    end
                    ST_L_RD: begin
                        `MPY_RD(old_ptr_r + (idx_r << 2))
                    end
                    ST_L_WR: begin
                        `MPY_WR(new_ptr_r + (idx_r << 2), hold_val_r, hold_tag_r)
                    end
                    ST_L_APP: begin
                        if (inplace_r) begin
                            `MPY_WR(old_ptr_r + (len_r << 2), elem_val_r, elem_tag_r)
                        end else begin
                            `MPY_WR(new_ptr_r + (len_r << 2), elem_val_r, elem_tag_r)
                        end
                    end
                    ST_L_Z: begin
                        `MPY_WR(new_ptr_r + (idx_r << 2), 32'd0, MPY_TAG_CONTROL)
                    end
                    ST_L_WLEN: begin
                        `MPY_WR(obj_r, nlen_r, MPY_TAG_CONTROL)
                    end
                    ST_L_WPTR: begin
                        `MPY_WR(obj_r + 32'd4, new_ptr_r, MPY_TAG_CONTROL)
                    end

                    ST_B_LEN: begin
                        `MPY_RD(obj_r)
                    end
                    ST_B_CAP: begin
                        `MPY_RD(obj_r + 32'd4)
                    end
                    ST_B_PTR: begin
                        `MPY_RD(obj_r + 32'd8)
                    end
                    ST_B_PLAN: begin
                        if (cap_r > len_r) begin
                            `MPY_OK(heap_r)
                        end else if (len_r > 32'hFFFF_FFF7) begin
                            `MPY_FAULT
                        end else if ((len_r != 32'd0) && (old_ptr_r[1:0] != 2'b00)) begin
                            `MPY_FAULT
                        end else begin
                            ncap   = len_r + 32'd8;
                            nw     = (ncap + 32'd3) >> 2;
                            nbytes = nw << 2;
                            hend   = heap_r + nbytes;
                            if ((nw == 32'd0) || (hend < heap_r)) begin
                                `MPY_FAULT
                            end else if (hend > limit_r) begin
                                `MPY_SHORT(nbytes)
                            end else begin
                                new_cap_r  <= ncap;
                                new_ptr_r  <= heap_r;
                                heap_end_r <= hend;
                                words_r    <= nw;
                                copy_n_r   <= (len_r + 32'd3) >> 2;
                                idx_r      <= 32'd0;
                                if ((len_r + 32'd3) >> 2 == 32'd0)
                                    phase_r <= ST_B_Z;
                                else
                                    phase_r <= ST_B_RD;
                            end
                        end
                    end
                    ST_B_RD: begin
                        `MPY_RD(old_ptr_r + (idx_r << 2))
                    end
                    ST_B_WR: begin
                        `MPY_WR(new_ptr_r + (idx_r << 2), hold_val_r, MPY_TAG_CONTROL)
                    end
                    ST_B_Z: begin
                        `MPY_WR(new_ptr_r + (idx_r << 2), 32'd0, MPY_TAG_CONTROL)
                    end
                    ST_B_WLEN: begin
                        `MPY_WR(obj_r, len_r, MPY_TAG_CONTROL)
                    end
                    ST_B_WCAP: begin
                        `MPY_WR(obj_r + 32'd4, new_cap_r, MPY_TAG_CONTROL)
                    end
                    ST_B_WPTR: begin
                        `MPY_WR(obj_r + 32'd8, new_ptr_r, MPY_TAG_CONTROL)
                    end

                    ST_D_W0: begin
                        `MPY_RD(obj_r)
                    end
                    ST_D_W1: begin
                        `MPY_RD(obj_r + 32'd4)
                    end
                    ST_D_W2: begin
                        `MPY_RD(obj_r + 32'd8)
                    end
                    ST_D_W3: begin
                        `MPY_RD(obj_r + 32'd12)
                    end
                    ST_CH_W0: begin
                        `MPY_RD(ch_obj_r)
                    end
                    ST_CH_W1: begin
                        `MPY_RD(ch_obj_r + 32'd4)
                    end
                    ST_CH_W2: begin
                        `MPY_RD(ch_obj_r + 32'd8)
                    end
                    ST_D_PLAN: begin
                        if (slots_r == 32'hFFFF_FFFF) begin
                            `MPY_FAULT
                        end else begin
                            na = mpy_next_alloc(slots_r + 32'd1);
                            nw = is_set_r ? na : (na << 1);
                            nbytes = nw << 2;
                            hend = heap_r + nbytes;
                            if ((na == 32'd0) || (na < (slots_r + 32'd1)) ||
                                (hend < heap_r)) begin
                                `MPY_FAULT
                            end else if (hend > limit_r) begin
                                `MPY_SHORT(nbytes)
                            end else begin
                                new_slots_r <= na;
                                new_ptr_r   <= heap_r;
                                heap_end_r  <= hend;
                                words_r     <= nw;
                                idx_r       <= 32'd0;
                                phase_r     <= ST_D_Z;
                            end
                        end
                    end
                    ST_D_Z: begin
                        `MPY_WR(new_ptr_r + (idx_r << 2), 32'd0, MPY_TAG_CONTROL)
                    end
                    ST_D_KEY: begin
                        `MPY_RD(mpy_ent(table_r, slot_i_r, is_set_r))
                    end
                    ST_D_VAL: begin
                        `MPY_RD(mpy_ent(table_r, slot_i_r, 1'b0) + 32'd4)
                    end
                    ST_D_HASH: begin
                        in_tuple_r <= 1'b0;
                        h_tag_r    <= key_tag_r;
                        h_val_r    <= key_val_r;
                        h_obj_r    <= key_val_r;
                        if (ch_on_r && (ch_alloc_r != 32'd0)) begin
                            ch_pos_r  <= mpy_umod(slot_i_r, ch_alloc_r);
                            ch_seen_r <= 32'd0;
                            phase_r   <= ST_CH_PR;
                        end else begin
                            phase_r <= ST_H_START;
                        end
                    end
                    ST_CH_PR: begin
                        // Computed-hash dict entries are key, value. Always
                        // a dict stride, including while a set is resizing.
                        `MPY_RD(ch_table_r + (ch_pos_r << 3))
                    end
                    ST_CH_VAL: begin
                        `MPY_RD(ch_table_r + (ch_pos_r << 3) + 32'd4)
                    end

                    ST_H_START: begin
                        if (h_tag_r == MPY_TAG_TUPLE) begin
                            in_tuple_r    <= 1'b1;
                            tu_sp_r       <= 2'd0;
                            tu_base_r[0]  <= h_val_r;
                            phase_r       <= ST_H_TL;
                        end else begin
                            phase_r <= ST_H_DISP;
                        end
                    end
                    ST_H_DISP: begin
                        ih = mpy_imm_hash(h_tag_r, h_val_r);
                        if (ih[32]) begin
                            `MPY_HASHED(ih[31:0])
                        end else if (h_tag_r == MPY_TAG_STR) begin
                            h_obj_r   <= h_val_r;
                            h_store_r <= 1'b1;
                            phase_r   <= ST_H_SL;
                        end else if (h_tag_r == MPY_TAG_BYTES) begin
                            h_obj_r   <= h_val_r;
                            h_store_r <= 1'b0;
                            phase_r   <= ST_H_BL;
                        end else if (h_tag_r == MPY_TAG_OBJECT) begin
                            h_obj_r <= h_val_r;
                            phase_r <= ST_H_OT;
                        end else if (h_tag_r == MPY_TAG_QSTR) begin
                            if (qstr_hash_base_i == 32'd0) begin
                                `MPY_FAULT
                            end else begin
                                phase_r <= ST_H_QS;
                            end
                        end else begin
                            `MPY_FAULT
                        end
                    end
                    ST_H_SL: begin
                        `MPY_RD(h_obj_r)
                    end
                    ST_H_SH: begin
                        `MPY_RD(h_obj_r + 32'd4)
                    end
                    ST_H_SP: begin
                        `MPY_RD(h_obj_r + 32'd8)
                    end
                    ST_H_BL: begin
                        `MPY_RD(h_obj_r)
                    end
                    ST_H_BP: begin
                        `MPY_RD(h_obj_r + 32'd4)
                    end
                    ST_H_BD: begin
                        `MPY_RD(h_ptr_r + (h_idx_r & 32'hFFFF_FFFC))
                    end
                    ST_H_ST: begin
                        `MPY_WR(h_obj_r + 32'd4, hash_r, MPY_TAG_CONTROL)
                    end
                    ST_H_TL: begin
                        `MPY_RD(tu_base_r[tu_sp_r])
                    end
                    ST_H_TE: begin
                        `MPY_RD(tu_base_r[tu_sp_r] + 32'd4 + (tu_idx_r[tu_sp_r] << 2))
                    end
                    ST_H_TA: begin
                        sum = tu_acc_r[tu_sp_r] + hash_r;
                        tu_acc_r[tu_sp_r] <= sum;
                        if (tu_idx_r[tu_sp_r] + 32'd1 < tu_len_r[tu_sp_r]) begin
                            tu_idx_r[tu_sp_r] <= tu_idx_r[tu_sp_r] + 32'd1;
                            phase_r <= ST_H_TE;
                        end else if (tu_sp_r == 2'd0) begin
                            hash_r     <= sum;
                            in_tuple_r <= 1'b0;
                            phase_r    <= ST_D_PRB;
                        end else begin
                            hash_r  <= sum;
                            tu_sp_r <= tu_sp_r - 2'd1;
                            phase_r <= ST_H_TA;
                        end
                    end
                    ST_H_OT: begin
                        `MPY_RD(h_obj_r + 32'd4)
                    end
                    ST_H_OH: begin
                        // tp_hash, not tp_dict at +8.
                        `MPY_RD(h_ptr_r + 32'd20)
                    end
                    ST_H_QS: begin
                        `MPY_RD(qstr_hash_base_i + (h_val_r << 2))
                    end

                    ST_D_PRB: begin
                        if (new_slots_r == 32'd0) begin
                            `MPY_FAULT
                        end else begin
                            probe_r   <= mpy_umod(hash_r, new_slots_r);
                            probe_n_r <= 32'd0;
                            phase_r   <= ST_D_PK;
                        end
                    end
                    ST_D_PK: begin
                        `MPY_RD(mpy_ent(new_ptr_r, probe_r, is_set_r))
                    end
                    ST_D_WK: begin
                        `MPY_WR(mpy_ent(new_ptr_r, probe_r, is_set_r),
                                key_val_r, key_tag_r)
                    end
                    ST_D_WV: begin
                        `MPY_WR(mpy_ent(new_ptr_r, probe_r, 1'b0) + 32'd4,
                                val_val_r, val_tag_r)
                    end
                    ST_D_P0: begin
                        if (placed_r[31]) begin
                            `MPY_FAULT
                        end else begin
                            sum = {ind_r, placed_r[30:0]};
                            `MPY_WR(obj_r, sum, MPY_TAG_CONTROL)
                        end
                    end
                    ST_D_P1: begin
                        `MPY_WR(obj_r + 32'd4, new_slots_r, MPY_TAG_CONTROL)
                    end
                    ST_D_P2: begin
                        `MPY_WR(obj_r + 32'd12, types_r, MPY_TAG_CONTROL)
                    end
                    ST_D_P3: begin
                        `MPY_WR(obj_r + 32'd8, new_ptr_r, MPY_TAG_CONTROL)
                    end
                    default: begin
                        `MPY_FAULT
                    end
                endcase
            end
        end
    end

`undef MPY_RD
`undef MPY_WR
`undef MPY_OK
`undef MPY_SHORT
`undef MPY_FAULT
`undef MPY_HASHED

endmodule
