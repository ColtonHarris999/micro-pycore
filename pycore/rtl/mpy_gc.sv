// mpy_gc: precise mark-and-sweep for the MicroPython value encoding.
// planning/micropython_pivot_plan.md §0.5, §0.6, and the MemoryError row
// of §1.1. pycore/docs/mpy_gc.md is the companion note.
//
// This module is not the imported collector. pycore/rtl/pycore_gc.sv still
// serves the 128-bit CPython encoding and is left unchanged.
//
// A slot is a 32-bit payload plus a tag nibble. The tracer reads the nibble
// and only then decides whether the payload is an address. CONTROL (empty,
// None, null, tombstone, False, True), INT, INT64, FLOAT, COMPLEX, the
// reserved code, QSTR, SHORT_STR, and CONT are not pointers. A MUT_COLLEC
// address is the payload with the low 2 bits cleared; those bits are the
// kind (list, dict, set, bytearray).
//
// An allocation that does not fit does not change the heap. The engine
// pulses alloc_aborted_o, collects, and searches again. A second miss
// returns emergency_addr_i with alloc_memerr_o set. That object is
// preallocated by the image; this module never builds it.

`include "mpy_defs.svh"

module mpy_gc #(
    parameter int POOL_BYTES = 64,
    parameter logic [31:0] POOL_BASE = 32'h2000_1000,
    parameter int STACK_DEPTH = 32
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    // Tagged slots the core presents as roots. Every live frame slot belongs
    // here, not only the value-stack slice below the stack pointer.
    input  logic [31:0] root_base_i,
    input  logic [15:0] root_count_i,
    // Preallocated MemoryError object. Rooted on every collection.
    input  logic [31:0] emergency_addr_i,

    input  logic        alloc_req_i,
    input  logic [31:0] alloc_nbytes_i,
    output logic        alloc_busy_o,
    output logic        alloc_done_o,
    output logic        alloc_ok_o,
    output logic        alloc_memerr_o,
    output logic        alloc_aborted_o,
    output logic [31:0] alloc_addr_o,

    input  logic        collect_req_i,
    output logic        collect_done_o,
    output logic        busy_o,

    output logic        stack_overflow_o,
    output logic [31:0] free_bytes_o,
    output logic [31:0] commit_count_o,
    // One-cycle pulses. follow means the tag was a pointer tag and the
    // adjusted payload was queued. refuse means the tag was not a pointer,
    // so the payload was not used as an address.
    output logic        trace_follow_o,
    output logic        trace_refuse_o,
    output logic [3:0]  trace_tag_o,
    output logic [31:0] trace_addr_o,
    output logic [4:0]  state_o,

    output logic        mem_req_o,
    output logic        mem_we_o,
    output logic [31:0] mem_addr_o,
    output logic [31:0] mem_wdata_o,
    output logic        mem_tag_we_o,
    output logic [3:0]  mem_wtag_o,
    input  logic        mem_ack_i,
    input  logic [31:0] mem_rdata_i,
    input  logic [3:0]  mem_rtag_i
);
    localparam int G  = POOL_BYTES / 4;
    localparam int GW = (G <= 1) ? 1 : $clog2(G);
    localparam int IW = (G <= 1) ? 1 : $clog2(G + 1);
    localparam int SPW = (STACK_DEPTH <= 1) ? 1 : $clog2(STACK_DEPTH);

    localparam logic [1:0] SK_OBJECT = 2'd0;
    localparam logic [1:0] SK_VALUES = 2'd1;
    localparam logic [1:0] SK_BYTES  = 2'd2;

    localparam logic [3:0] RD_ROOT      = 4'd0;
    localparam logic [3:0] RD_ZERO      = 4'd1;
    localparam logic [3:0] RD_TUPLE_LEN = 4'd2;
    localparam logic [3:0] RD_STR0      = 4'd3;
    localparam logic [3:0] RD_STR1      = 4'd4;
    localparam logic [3:0] RD_STR2      = 4'd5;
    localparam logic [3:0] RD_BYTES0    = 4'd6;
    localparam logic [3:0] RD_BYTES1    = 4'd7;
    localparam logic [3:0] RD_MUT0      = 4'd8;
    localparam logic [3:0] RD_MUT1      = 4'd9;
    localparam logic [3:0] RD_MUT2      = 4'd10;
    localparam logic [3:0] RD_MUT3      = 4'd11;
    localparam logic [3:0] RD_BA2       = 4'd12;
    localparam logic [3:0] RD_OBJ_KIND  = 4'd13;
    localparam logic [3:0] RD_OBJ_TYPE  = 4'd14;
    localparam logic [3:0] RD_VALUE     = 4'd15;

    typedef enum logic [4:0] {
        S_IDLE, S_FIND, S_COMMIT, S_ZERO, S_FAIL, S_MEMERR,
        S_CLEAR, S_EM, S_ROOT, S_POP, S_VISIT, S_PARSE,
        S_WAIT, S_VAL, S_SWEEP, S_TALLY, S_CDONE, S_ADONE
    } state_e;

    typedef struct packed {
        logic [31:0] addr;
        logic [31:0] aux;
        logic [3:0]  tag;
        logic [1:0]  sk;
    } ent_t;

    function automatic logic mpy_tag_is_ptr(input logic [3:0] tag);
        // The nibble is the whole decision. False and True are CONTROL
        // kinds 4 and 5, so they fall in the first arm and are not pointers.
        case (tag)
            MPY_TAG_CONTROL,
            MPY_TAG_INT,
            MPY_TAG_INT64,
            MPY_TAG_FLOAT,
            MPY_TAG_COMPLEX,
            MPY_TAG_RESERVED,
            MPY_TAG_QSTR,
            MPY_TAG_SHORT_STR,
            MPY_TAG_CONT: mpy_tag_is_ptr = 1'b0;
            MPY_TAG_STR,
            MPY_TAG_TUPLE,
            MPY_TAG_MUT_COLLEC,
            MPY_TAG_RANGE,
            MPY_TAG_ITER,
            MPY_TAG_BYTES,
            MPY_TAG_OBJECT: mpy_tag_is_ptr = 1'b1;
            default: mpy_tag_is_ptr = 1'b0;
        endcase
    endfunction

    // Call only after mpy_tag_is_ptr. MUT_COLLEC clears the kind bits.
    function automatic logic [31:0] mpy_ptr_addr(
        input logic [3:0] tag,
        input logic [31:0] payload
    );
        if (tag == MPY_TAG_MUT_COLLEC)
            mpy_ptr_addr = {payload[31:2], 2'b00};
        else
            mpy_ptr_addr = payload;
    endfunction

    // §0.6 field counts. Word 0 is the kind, word 1 is the type pointer,
    // and these fields start at word 2.
    function automatic logic [3:0] mpy_obk_fields(input logic [31:0] kind);
        case (kind)
            MPY_OB_INSTANCE:     mpy_obk_fields = 4'd1;
            MPY_OB_TYPE:         mpy_obk_fields = 4'd4;
            MPY_OB_BOUND_METHOD: mpy_obk_fields = 4'd2;
            MPY_OB_BUILTIN:      mpy_obk_fields = 4'd2;
            MPY_OB_EXCEPTION:    mpy_obk_fields = 4'd2;
            MPY_OB_CELL:         mpy_obk_fields = 4'd1;
            MPY_OB_FUNCTION:     mpy_obk_fields = 4'd2;
            MPY_OB_MODULE:       mpy_obk_fields = 4'd1;
            default:              mpy_obk_fields = 4'd0;
        endcase
    endfunction

    function automatic logic addr_in_pool(input logic [31:0] a);
        addr_in_pool = (a >= POOL_BASE) && ((a - POOL_BASE) < POOL_BYTES[31:0]);
    endfunction

    function automatic logic [GW-1:0] addr_idx(input logic [31:0] a);
        addr_idx = GW'((a - POOL_BASE) >> 2);
    endfunction

    function automatic logic [31:0] cap_words(
        input logic [31:0] n,
        input logic [31:0] lim
    );
        if (n > lim)
            cap_words = lim;
        else
            cap_words = n;
    endfunction

    function automatic logic [SPW-1:0] top_idx(input logic [SPW:0] sp);
        // A full stack has only the carry bit set. That entry is the last one.
        if (sp[SPW])
            top_idx = {SPW{1'b1}};
        else
            top_idx = sp[SPW-1:0] - {{(SPW - 1){1'b0}}, 1'b1};
    endfunction

    state_e state;
    logic [G-1:0] used_r, head_r, mark_r;
    logic [15:0] span_r [0:G-1];

    ent_t stack [0:STACK_DEPTH-1];
    logic [SPW:0] sp_r;

    logic [31:0] need_r;
    logic [31:0] run_len_r;
    logic [31:0] run_start_r;
    logic [IW-1:0] scan_i;
    logic [IW-1:0] sweep_i;
    logic [31:0] z_i;
    logic [31:0] grant_addr_r;
    logic did_collect_r;
    logic return_alloc_r;
    logic alloc_active_r;
    logic tally_alloc_r;

    logic [31:0] cur_addr_r;
    logic [31:0] cur_aux_r;
    logic [31:0] cur_span_r;
    logic [3:0]  cur_tag_r;
    logic [1:0]  cur_sk_r;
    logic [3:0]  rd_sel_r;
    logic [15:0] root_i;
    logic        em_mark_r;
    logic [31:0] mut_len_r;
    logic [31:0] mut_alloc_r;
    logic        mut_ind_r;
    logic [31:0] obj_kind_r;
    logic [31:0] val_base_r;
    logic [31:0] val_n_r;
    logic [31:0] val_i_r;
    // Blocking flags the tracer sets while it classifies one word. The
    // outputs are assigned from these after the state case, so a refuse
    // is not cleared by the default pulse reset in the same cycle.
    logic        trace_follow_b;
    logic        trace_refuse_b;
    logic [3:0]  trace_tag_b;
    logic [31:0] trace_addr_b;

    assign busy_o = (state != S_IDLE);
    assign alloc_busy_o = alloc_active_r;
    assign state_o = state;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state <= S_IDLE;
            used_r <= '0;
            head_r <= '0;
            mark_r <= '0;
            for (int k = 0; k < G; k++)
                span_r[k] <= '0;
            sp_r <= '0;
            need_r <= '0;
            run_len_r <= '0;
            run_start_r <= '0;
            scan_i <= '0;
            sweep_i <= '0;
            z_i <= '0;
            grant_addr_r <= '0;
            did_collect_r <= 1'b0;
            return_alloc_r <= 1'b0;
            alloc_active_r <= 1'b0;
            tally_alloc_r <= 1'b0;
            cur_addr_r <= '0;
            cur_aux_r <= '0;
            cur_span_r <= '0;
            cur_tag_r <= '0;
            cur_sk_r <= '0;
            rd_sel_r <= '0;
            root_i <= '0;
            em_mark_r <= 1'b0;
            mut_len_r <= '0;
            mut_alloc_r <= '0;
            mut_ind_r <= 1'b0;
            obj_kind_r <= '0;
            val_base_r <= '0;
            val_n_r <= '0;
            val_i_r <= '0;
            alloc_done_o <= 1'b0;
            alloc_ok_o <= 1'b0;
            alloc_memerr_o <= 1'b0;
            alloc_aborted_o <= 1'b0;
            alloc_addr_o <= '0;
            collect_done_o <= 1'b0;
            stack_overflow_o <= 1'b0;
            free_bytes_o <= POOL_BYTES[31:0];
            commit_count_o <= '0;
            trace_follow_o <= 1'b0;
            trace_refuse_o <= 1'b0;
            trace_tag_o <= '0;
            trace_addr_o <= '0;
            mem_req_o <= 1'b0;
            mem_we_o <= 1'b0;
            mem_addr_o <= '0;
            mem_wdata_o <= '0;
            mem_tag_we_o <= 1'b0;
            mem_wtag_o <= '0;
        end else begin
            alloc_done_o <= 1'b0;
            alloc_aborted_o <= 1'b0;
            collect_done_o <= 1'b0;
            // verilator lint_off BLKSEQ
            trace_follow_b = 1'b0;
            trace_refuse_b = 1'b0;
            trace_tag_b = 4'h0;
            trace_addr_b = 32'h0;
            // verilator lint_on BLKSEQ

            case (state)
                S_IDLE: begin
                    mem_req_o <= 1'b0;
                    mem_we_o <= 1'b0;
                    if (alloc_req_i) begin
                        need_r <= (alloc_nbytes_i + 32'd3) >> 2;
                        did_collect_r <= 1'b0;
                        return_alloc_r <= 1'b0;
                        alloc_active_r <= 1'b1;
                        scan_i <= '0;
                        run_len_r <= '0;
                        run_start_r <= '0;
                        state <= S_FIND;
                    end else if (collect_req_i) begin
                        return_alloc_r <= 1'b0;
                        state <= S_CLEAR;
                    end
                end

                S_FIND: begin
                    if ((need_r == 32'd0) || (need_r > 32'(G))) begin
                        state <= S_FAIL;
                    end else if (scan_i >= IW'(G)) begin
                        state <= S_FAIL;
                    end else if (used_r[scan_i[GW-1:0]]) begin
                        run_len_r <= 32'd0;
                        run_start_r <= 32'(scan_i) + 32'd1;
                        scan_i <= scan_i + IW'(1);
                    end else if (run_len_r + 32'd1 == need_r) begin
                        if (run_len_r == 32'd0)
                            run_start_r <= 32'(scan_i);
                        state <= S_COMMIT;
                    end else begin
                        if (run_len_r == 32'd0)
                            run_start_r <= 32'(scan_i);
                        run_len_r <= run_len_r + 32'd1;
                        scan_i <= scan_i + IW'(1);
                    end
                end

                S_COMMIT: begin
                    // First architectural commit of this attempt. The miss
                    // path never reaches here.
                    if (run_start_r < 32'(G)) begin
                        head_r[run_start_r[GW-1:0]] <= 1'b1;
                        span_r[run_start_r[GW-1:0]] <= need_r[15:0];
                        for (int k = 0; k < G; k++) begin
                            if ((k >= int'(run_start_r)) &&
                                (k < int'(run_start_r) + int'(need_r)))
                                used_r[k] <= 1'b1;
                        end
                        grant_addr_r <= POOL_BASE + (run_start_r << 2);
                        commit_count_o <= commit_count_o + 32'd1;
                        z_i <= 32'd0;
                        state <= S_ZERO;
                    end else begin
                        state <= S_FAIL;
                    end
                end

                S_ZERO: begin
                    mem_req_o <= 1'b1;
                    mem_we_o <= 1'b1;
                    mem_tag_we_o <= 1'b1;
                    mem_wdata_o <= 32'h0;
                    mem_wtag_o <= MPY_TAG_CONTROL;
                    mem_addr_o <= grant_addr_r + (z_i << 2);
                    rd_sel_r <= RD_ZERO;
                    state <= S_WAIT;
                end

                S_FAIL: begin
                    // No heap bits change on this path. Collect once, then
                    // search again; the second miss is the emergency object.
                    if (!did_collect_r) begin
                        alloc_aborted_o <= 1'b1;
                        did_collect_r <= 1'b1;
                        return_alloc_r <= 1'b1;
                        state <= S_CLEAR;
                    end else begin
                        state <= S_MEMERR;
                    end
                end

                S_MEMERR: begin
                    alloc_done_o <= 1'b1;
                    alloc_ok_o <= 1'b0;
                    alloc_memerr_o <= 1'b1;
                    alloc_addr_o <= emergency_addr_i;
                    alloc_active_r <= 1'b0;
                    mem_req_o <= 1'b0;
                    mem_we_o <= 1'b0;
                    state <= S_IDLE;
                end

                S_CLEAR: begin
                    mark_r <= '0;
                    sp_r <= '0;
                    root_i <= '0;
                    em_mark_r <= 1'b0;
                    sweep_i <= '0;
                    stack_overflow_o <= 1'b0;
                    mem_req_o <= 1'b0;
                    mem_we_o <= 1'b0;
                    state <= S_EM;
                end

                S_EM: begin
                    if (emergency_addr_i != 32'h0) begin
                        if (sp_r >= (SPW + 1)'(STACK_DEPTH)) begin
                            stack_overflow_o <= 1'b1;
                        end else begin
                            stack[sp_r[SPW-1:0]] <= '{
                                addr: emergency_addr_i,
                                aux: 32'h0,
                                tag: MPY_TAG_OBJECT,
                                sk: SK_OBJECT
                            };
                            sp_r <= sp_r + (SPW + 1)'(1);
                        end
                    end
                    state <= S_ROOT;
                end

                S_ROOT: begin
                    if (root_i >= root_count_i) begin
                        state <= S_POP;
                    end else begin
                        mem_req_o <= 1'b1;
                        mem_we_o <= 1'b0;
                        mem_tag_we_o <= 1'b0;
                        mem_addr_o <= root_base_i + (32'(root_i) << 2);
                        rd_sel_r <= RD_ROOT;
                        state <= S_WAIT;
                    end
                end

                S_POP: begin
                    if (sp_r == '0) begin
                        sweep_i <= '0;
                        state <= S_SWEEP;
                    end else begin
                        cur_addr_r <= stack[top_idx(sp_r)].addr;
                        cur_aux_r  <= stack[top_idx(sp_r)].aux;
                        cur_tag_r  <= stack[top_idx(sp_r)].tag;
                        cur_sk_r   <= stack[top_idx(sp_r)].sk;
                        sp_r <= sp_r - (SPW + 1)'(1);
                        state <= S_VISIT;
                    end
                end

                S_VISIT: begin
                    logic [GW-1:0] ix;
                    ix = addr_idx(cur_addr_r);
                    if (addr_in_pool(cur_addr_r) && (cur_addr_r[1:0] == 2'b00) &&
                        head_r[ix] && used_r[ix]) begin
                        if (mark_r[ix]) begin
                            state <= S_POP;
                        end else begin
                            mark_r[ix] <= 1'b1;
                            cur_span_r <= {16'd0, span_r[ix]};
                            state <= S_PARSE;
                        end
                    end else if ((cur_addr_r != 32'h0) &&
                                 (cur_addr_r == emergency_addr_i)) begin
                        if (em_mark_r) begin
                            state <= S_POP;
                        end else begin
                            em_mark_r <= 1'b1;
                            // Static object: field counts are tiny. The cap
                            // only bounds a corrupt length word.
                            cur_span_r <= 32'd32;
                            state <= S_PARSE;
                        end
                    end else begin
                        // Flash, a null, or a pointer that is not an
                        // allocation head. ROM bytes are not a heap root.
                        state <= S_POP;
                    end
                end

                S_PARSE: begin
                    case (cur_sk_r)
                        SK_BYTES: state <= S_POP;
                        SK_VALUES: begin
                            val_base_r <= cur_addr_r;
                            val_n_r <= cap_words(cur_aux_r, cur_span_r);
                            val_i_r <= 32'd0;
                            state <= S_VAL;
                        end
                        SK_OBJECT: begin
                            case (cur_tag_r)
                                MPY_TAG_TUPLE: begin
                                    mem_req_o <= 1'b1;
                                    mem_we_o <= 1'b0;
                                    mem_tag_we_o <= 1'b0;
                                    mem_addr_o <= cur_addr_r;
                                    rd_sel_r <= RD_TUPLE_LEN;
                                    state <= S_WAIT;
                                end
                                MPY_TAG_STR: begin
                                    mem_req_o <= 1'b1;
                                    mem_we_o <= 1'b0;
                                    mem_tag_we_o <= 1'b0;
                                    mem_addr_o <= cur_addr_r;
                                    rd_sel_r <= RD_STR0;
                                    state <= S_WAIT;
                                end
                                MPY_TAG_BYTES: begin
                                    mem_req_o <= 1'b1;
                                    mem_we_o <= 1'b0;
                                    mem_tag_we_o <= 1'b0;
                                    mem_addr_o <= cur_addr_r;
                                    rd_sel_r <= RD_BYTES0;
                                    state <= S_WAIT;
                                end
                                MPY_TAG_RANGE: begin
                                    val_base_r <= cur_addr_r;
                                    val_n_r <= cap_words(32'd3, cur_span_r);
                                    val_i_r <= 32'd0;
                                    state <= S_VAL;
                                end
                                MPY_TAG_ITER: begin
                                    val_base_r <= cur_addr_r;
                                    val_n_r <= cap_words(32'd2, cur_span_r);
                                    val_i_r <= 32'd0;
                                    state <= S_VAL;
                                end
                                MPY_TAG_MUT_COLLEC: begin
                                    mem_req_o <= 1'b1;
                                    mem_we_o <= 1'b0;
                                    mem_tag_we_o <= 1'b0;
                                    mem_addr_o <= cur_addr_r;
                                    rd_sel_r <= RD_MUT0;
                                    state <= S_WAIT;
                                end
                                MPY_TAG_OBJECT: begin
                                    mem_req_o <= 1'b1;
                                    mem_we_o <= 1'b0;
                                    mem_tag_we_o <= 1'b0;
                                    mem_addr_o <= cur_addr_r;
                                    rd_sel_r <= RD_OBJ_KIND;
                                    state <= S_WAIT;
                                end
                                default: state <= S_POP;
                            endcase
                        end
                        default: state <= S_POP;
                    endcase
                end

                S_VAL: begin
                    if (val_i_r >= val_n_r) begin
                        state <= S_POP;
                    end else begin
                        mem_req_o <= 1'b1;
                        mem_we_o <= 1'b0;
                        mem_tag_we_o <= 1'b0;
                        mem_addr_o <= val_base_r + (val_i_r << 2);
                        rd_sel_r <= RD_VALUE;
                        state <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (mem_ack_i) begin
                        mem_req_o <= 1'b0;
                        mem_we_o <= 1'b0;
                        mem_tag_we_o <= 1'b0;
                        case (rd_sel_r)
                            RD_ZERO: begin
                                if (z_i + 32'd1 >= need_r) begin
                                    tally_alloc_r <= 1'b1;
                                    state <= S_TALLY;
                                end else begin
                                    z_i <= z_i + 32'd1;
                                    state <= S_ZERO;
                                end
                            end
                            RD_ROOT: begin
                                follow_word(mem_rtag_i, mem_rdata_i, SK_OBJECT, 32'd0);
                                root_i <= root_i + 16'd1;
                                state <= S_ROOT;
                            end
                            RD_TUPLE_LEN: begin
                                // Word 0 is a count, not a pointer.
                                val_base_r <= cur_addr_r + 32'd4;
                                if (cur_span_r == 32'd0)
                                    val_n_r <= 32'd0;
                                else
                                    val_n_r <= cap_words(mem_rdata_i, cur_span_r - 32'd1);
                                val_i_r <= 32'd0;
                                state <= S_VAL;
                            end
                            RD_STR0: begin
                                mem_req_o <= 1'b1;
                                mem_we_o <= 1'b0;
                                mem_addr_o <= cur_addr_r + 32'd4;
                                rd_sel_r <= RD_STR1;
                                state <= S_WAIT;
                            end
                            RD_STR1: begin
                                mem_req_o <= 1'b1;
                                mem_we_o <= 1'b0;
                                mem_addr_o <= cur_addr_r + 32'd8;
                                rd_sel_r <= RD_STR2;
                                state <= S_WAIT;
                            end
                            RD_STR2: begin
                                follow_word(mem_rtag_i, mem_rdata_i, SK_BYTES, 32'd1);
                                state <= S_POP;
                            end
                            RD_BYTES0: begin
                                mem_req_o <= 1'b1;
                                mem_we_o <= 1'b0;
                                mem_addr_o <= cur_addr_r + 32'd4;
                                rd_sel_r <= RD_BYTES1;
                                state <= S_WAIT;
                            end
                            RD_BYTES1: begin
                                follow_word(mem_rtag_i, mem_rdata_i, SK_BYTES, 32'd1);
                                state <= S_POP;
                            end
                            RD_MUT0: begin
                                mut_ind_r <= mem_rdata_i[31];
                                if (cur_aux_r[1:0] == MPY_MUT_LIST)
                                    mut_len_r <= mem_rdata_i;
                                else
                                    mut_len_r <= {1'b0, mem_rdata_i[30:0]};
                                mem_req_o <= 1'b1;
                                mem_we_o <= 1'b0;
                                mem_addr_o <= cur_addr_r + 32'd4;
                                rd_sel_r <= RD_MUT1;
                                state <= S_WAIT;
                            end
                            RD_MUT1: begin
                                if (cur_aux_r[1:0] == MPY_MUT_LIST) begin
                                    // List word 1 is the item-array pointer.
                                    follow_word(mem_rtag_i, mem_rdata_i, SK_VALUES, mut_len_r);
                                    state <= S_POP;
                                end else begin
                                    mut_alloc_r <= cap_words(mem_rdata_i, 32'(G));
                                    mem_req_o <= 1'b1;
                                    mem_we_o <= 1'b0;
                                    mem_addr_o <= cur_addr_r + 32'd8;
                                    if (cur_aux_r[1:0] == MPY_MUT_BYTEARRAY)
                                        rd_sel_r <= RD_BA2;
                                    else
                                        rd_sel_r <= RD_MUT2;
                                    state <= S_WAIT;
                                end
                            end
                            RD_MUT2: begin
                                // Dict/set word 2 is the entry table.
                                // Dict entries are key, value. Set entries
                                // are one word per slot.
                                if (cur_aux_r[1:0] == MPY_MUT_DICT)
                                    follow_word(mem_rtag_i, mem_rdata_i, SK_VALUES,
                                                mut_alloc_r << 1);
                                else if (cur_aux_r[1:0] == MPY_MUT_SET)
                                    follow_word(mem_rtag_i, mem_rdata_i, SK_VALUES,
                                                mut_alloc_r);
                                mem_req_o <= 1'b1;
                                mem_we_o <= 1'b0;
                                mem_addr_o <= cur_addr_r + 32'd12;
                                rd_sel_r <= RD_MUT3;
                                state <= S_WAIT;
                            end
                            RD_MUT3: begin
                                // Types table only after the object indicator
                                // is set. A zero pointer stays zero until then.
                                if (mut_ind_r)
                                    follow_word(mem_rtag_i, mem_rdata_i, SK_VALUES,
                                                mut_alloc_r);
                                state <= S_POP;
                            end
                            RD_BA2: begin
                                follow_word(mem_rtag_i, mem_rdata_i, SK_BYTES, 32'd1);
                                state <= S_POP;
                            end
                            RD_OBJ_KIND: begin
                                // Kind word. Not a pointer, whatever its nibble.
                                obj_kind_r <= mem_rdata_i;
                                mem_req_o <= 1'b1;
                                mem_we_o <= 1'b0;
                                mem_addr_o <= cur_addr_r + 32'd4;
                                rd_sel_r <= RD_OBJ_TYPE;
                                state <= S_WAIT;
                            end
                            RD_OBJ_TYPE: begin
                                follow_word(mem_rtag_i, mem_rdata_i, SK_OBJECT, 32'd0);
                                val_base_r <= cur_addr_r + 32'd8;
                                val_n_r <= {28'd0, mpy_obk_fields(obj_kind_r)};
                                val_i_r <= 32'd0;
                                state <= S_VAL;
                            end
                            RD_VALUE: begin
                                follow_word(mem_rtag_i, mem_rdata_i, SK_OBJECT, 32'd0);
                                val_i_r <= val_i_r + 32'd1;
                                state <= S_VAL;
                            end
                            default: state <= S_POP;
                        endcase
                    end
                end

                S_SWEEP: begin
                    if (sweep_i >= IW'(G)) begin
                        tally_alloc_r <= 1'b0;
                        state <= S_TALLY;
                    end else if (head_r[sweep_i[GW-1:0]] &&
                                 !mark_r[sweep_i[GW-1:0]]) begin
                        int unsigned s0;
                        int unsigned spn;
                        s0 = int'(sweep_i);
                        spn = int'(span_r[sweep_i[GW-1:0]]);
                        if (spn < 1)
                            spn = 1;
                        if (s0 + spn > G)
                            spn = G - s0;
                        for (int k = 0; k < G; k++) begin
                            if ((k >= s0) && (k < s0 + spn))
                                used_r[k] <= 1'b0;
                        end
                        head_r[sweep_i[GW-1:0]] <= 1'b0;
                        span_r[sweep_i[GW-1:0]] <= '0;
                        mark_r[sweep_i[GW-1:0]] <= 1'b0;
                        sweep_i <= sweep_i + IW'(spn);
                    end else begin
                        sweep_i <= sweep_i + IW'(1);
                    end
                end

                S_TALLY: begin
                    int unsigned c;
                    c = 0;
                    for (int k = 0; k < G; k++) begin
                        if (!used_r[k])
                            c = c + 1;
                    end
                    free_bytes_o <= 32'(c) << 2;
                    if (tally_alloc_r)
                        state <= S_ADONE;
                    else
                        state <= S_CDONE;
                end

                S_CDONE: begin
                    collect_done_o <= 1'b1;
                    if (return_alloc_r) begin
                        scan_i <= '0;
                        run_len_r <= '0;
                        run_start_r <= '0;
                        state <= S_FIND;
                    end else begin
                        state <= S_IDLE;
                    end
                end

                S_ADONE: begin
                    alloc_done_o <= 1'b1;
                    alloc_ok_o <= 1'b1;
                    alloc_memerr_o <= 1'b0;
                    alloc_addr_o <= grant_addr_r;
                    alloc_active_r <= 1'b0;
                    state <= S_IDLE;
                end

                default: begin
                    mem_req_o <= 1'b0;
                    state <= S_IDLE;
                end
            endcase
            trace_follow_o <= trace_follow_b;
            trace_refuse_o <= trace_refuse_b;
            trace_tag_o <= trace_tag_b;
            trace_addr_o <= trace_addr_b;
        end
    end

    // Tag first. A non-pointer payload is never turned into an address.
    // `shape` is how a structural child is scanned; value slots pass
    // SK_OBJECT and the child's own tag selects the layout. `words` is the
    // value-array length for SK_VALUES and is ignored for SK_OBJECT.
    task automatic follow_word(
        input logic [3:0]  tag,
        input logic [31:0] payload,
        input logic [1:0]  shape,
        input logic [31:0] words
    );
        logic [31:0] dest;
        logic [31:0] aux;
        logic [1:0]  sk;
        logic        queue;
        logic [GW-1:0] ix;
        begin
            // verilator lint_off BLKSEQ
            if (!mpy_tag_is_ptr(tag)) begin
                // CONTROL includes False and True. The payload is not an address.
                trace_refuse_b = 1'b1;
                trace_tag_b = tag;
                trace_addr_b = payload;
            end else begin
                // verilator lint_on BLKSEQ
                dest = mpy_ptr_addr(tag, payload);
                // verilator lint_off BLKSEQ
                trace_follow_b = 1'b1;
                trace_tag_b = tag;
                trace_addr_b = dest;
                // verilator lint_on BLKSEQ
                queue = (dest != 32'h0);
                if (shape == SK_OBJECT) begin
                    sk = SK_OBJECT;
                    aux = (tag == MPY_TAG_MUT_COLLEC) ? {30'd0, payload[1:0]} : 32'd0;
                end else if (shape == SK_BYTES) begin
                    sk = SK_BYTES;
                    aux = 32'd0;
                    queue = queue && (words != 32'd0);
                end else begin
                    sk = SK_VALUES;
                    aux = words;
                    queue = queue && (words != 32'd0);
                end
                if (queue && addr_in_pool(dest) && (dest[1:0] == 2'b00)) begin
                    ix = addr_idx(dest);
                    if (head_r[ix] && mark_r[ix])
                        queue = 1'b0;
                end
                if (queue) begin
                    if (sp_r >= (SPW + 1)'(STACK_DEPTH)) begin
                        stack_overflow_o <= 1'b1;
                    end else begin
                        stack[sp_r[SPW-1:0]] <= '{
                            addr: dest, aux: aux, tag: tag, sk: sk
                        };
                        sp_r <= sp_r + (SPW + 1)'(1);
                    end
                end
            end
        end
    endtask
endmodule
