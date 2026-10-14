`include "mpy_defs.svh"

// Mark-sweep collector and allocator for the uPyCore GC pool
// (pycore/docs/mpy_gc.md).
//
// The pool is split into 16-byte blocks. An internal allocation table holds
// two bits per block: FREE, HEAD (first block of an object), TAIL (a later
// block of the same object), or MARK (a HEAD reached in this collection).
//
// Allocation is next-fit: the search starts where the last one ended and
// takes the first run of free blocks that is long enough. The blocks are
// zeroed (data and tag) before alloc_done_o, so a new object reads as NULL
// slots. A search that wraps without finding room reports alloc_ok_o = 0;
// the core then collects and retries.
//
// A collection marks from two root ranges of tagged words, then sweeps.
// Only a word whose tag is a pointer tag and whose address lands on a HEAD
// block marks anything, so a stale or interior pointer can keep an object
// alive but can never corrupt the table. Marked objects are scanned from an
// explicit stack. When the stack is full a newly marked block is left
// marked but unscanned and an overflow flag is set; after the stack drains,
// every marked block is scanned again, until a pass ends without overflow.
//
// Requests are one-cycle pulses. The memory port uses the same pulse/ack
// protocol as mpy_mem.
module mpy_gc #(
    parameter logic [31:0] POOL_BASE   = MPY_GC_POOL_BASE,
    parameter int          POOL_BYTES  = MPY_GC_POOL_BYTES,
    parameter int          STACK_DEPTH = 64
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    input  logic        alloc_req_i,
    input  logic [31:0] alloc_nbytes_i,
    output logic        alloc_done_o,
    output logic        alloc_ok_o,
    output logic [31:0] alloc_addr_o,

    input  logic        collect_req_i,
    input  logic [31:0] root0_lo_i,
    input  logic [31:0] root0_hi_i,
    input  logic [31:0] root1_lo_i,
    input  logic [31:0] root1_hi_i,
    output logic        collect_done_o,

    output logic        busy_o,
    output logic [31:0] free_blocks_o,
    output logic [31:0] total_blocks_o,
    output logic [31:0] collections_o,
    output logic [31:0] overflows_o,

    output logic        mem_req_o,
    output logic        mem_we_o,
    output logic        mem_tag_we_o,
    output logic [31:0] mem_addr_o,
    output logic [31:0] mem_wdata_o,
    output logic [3:0]  mem_wtag_o,
    input  logic        mem_ack_i,
    input  logic [31:0] mem_rdata_i,
    input  logic [3:0]  mem_rtag_i
);

    localparam int NB = POOL_BYTES / 16;
    localparam int BW = $clog2(NB + 1);
    localparam int SW = $clog2(STACK_DEPTH + 1);

    localparam logic [1:0] A_FREE = 2'd0;
    localparam logic [1:0] A_HEAD = 2'd1;
    localparam logic [1:0] A_TAIL = 2'd2;
    localparam logic [1:0] A_MARK = 2'd3;

    typedef enum logic [4:0] {
        G_IDLE,
        G_SCAN,       // alloc: look for a free run
        G_CLAIM,      // alloc: write HEAD/TAIL
        G_ZERO,       // alloc: zero the words
        G_ZERO_W,
        G_ROOT,       // collect: read the next root word
        G_ROOT_W,
        G_POP,        // drain the mark stack
        G_OBJ,        // read the next word of the object being scanned
        G_OBJ_W,
        G_RESCAN,     // overflow recovery: find the next MARK block
        G_SWEEP,
        G_DONE
    } gstate_e;

    gstate_e st;
    logic [1:0]  atb [0:NB-1];
    logic [BW-1:0] stk [0:STACK_DEPTH-1];
    logic [SW-1:0] ssp;
    logic        ovf;

    logic [BW-1:0] rover, idx, run_start, run_len, need, scanned;
    logic [31:0]   zaddr, zend;
    logic [31:0]   raddr, rhi;
    logic          rsel;          // 0: root range 0, 1: root range 1
    logic [BW-1:0] oblk;          // object scan: current block
    logic [1:0]    oword;
    logic          rescanning;
    logic          freeing;
    logic [31:0]   free_cnt, ncoll, novf;

    // Candidate pointer from the word just read.
    logic          cand_ptr;
    logic [31:0]   cand_addr;
    logic [31:0]   cand_off;
    logic [BW-1:0] cand_blk;
    always_comb begin
        unique case (mem_rtag_i)
            MPY_TAG_INT64, MPY_TAG_COMPLEX, MPY_TAG_STR, MPY_TAG_TUPLE,
            MPY_TAG_MUT_COLLEC, MPY_TAG_RANGE, MPY_TAG_ITER, MPY_TAG_BYTES,
            MPY_TAG_OBJECT, MPY_TAG_CONT: cand_ptr = 1'b1;
            default: cand_ptr = 1'b0;
        endcase
        cand_addr = {mem_rdata_i[31:2], 2'b00};
        cand_off  = cand_addr - POOL_BASE;
        cand_blk  = BW'(cand_off >> 4);
        if (cand_addr < POOL_BASE || cand_off >= 32'(POOL_BYTES))
            cand_ptr = 1'b0;
    end

    logic [BW-1:0] run_first;
    assign run_first = (run_len == '0) ? idx : run_start;

    assign busy_o         = (st != G_IDLE);
    assign free_blocks_o  = free_cnt;
    assign total_blocks_o = 32'(NB);
    assign collections_o  = ncoll;
    assign overflows_o    = novf;

    initial begin
        for (int i = 0; i < NB; i++) atb[i] = A_FREE;
    end

    // Marks a candidate (registered by the caller state) and pushes it.
    task automatic try_mark(input logic [BW-1:0] b);
        if (atb[b] == A_HEAD) begin
            atb[b] <= A_MARK;
            if (ssp < SW'(STACK_DEPTH)) begin
                stk[ssp] <= b;
                ssp <= ssp + 1'b1;
            end else begin
                ovf <= 1'b1;
                novf <= novf + 32'd1;
            end
        end
    endtask

    task automatic mem_read(input logic [31:0] a);
        mem_req_o    <= 1'b1;
        mem_we_o     <= 1'b0;
        mem_tag_we_o <= 1'b0;
        mem_addr_o   <= a;
    endtask

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            st             <= G_IDLE;
            ssp            <= '0;
            ovf            <= 1'b0;
            rover          <= '0;
            idx            <= '0;
            run_start      <= '0;
            run_len        <= '0;
            need           <= '0;
            scanned        <= '0;
            zaddr          <= '0;
            zend           <= '0;
            raddr          <= '0;
            rhi            <= '0;
            rsel           <= 1'b0;
            oblk           <= '0;
            oword          <= '0;
            rescanning     <= 1'b0;
            freeing        <= 1'b0;
            free_cnt       <= 32'(NB);
            ncoll          <= '0;
            novf           <= '0;
            alloc_done_o   <= 1'b0;
            alloc_ok_o     <= 1'b0;
            alloc_addr_o   <= '0;
            collect_done_o <= 1'b0;
            mem_req_o      <= 1'b0;
            mem_we_o       <= 1'b0;
            mem_tag_we_o   <= 1'b0;
            mem_addr_o     <= '0;
            mem_wdata_o    <= '0;
            mem_wtag_o     <= '0;
        end else begin
            alloc_done_o   <= 1'b0;
            collect_done_o <= 1'b0;
            mem_req_o      <= 1'b0;
            unique case (st)
                G_IDLE: begin
                    if (alloc_req_i) begin
                        need    <= (alloc_nbytes_i == 32'd0) ? BW'(1)
                                 : BW'((alloc_nbytes_i + 32'd15) >> 4);
                        idx     <= rover;
                        run_len <= '0;
                        scanned <= '0;
                        st      <= G_SCAN;
                    end else if (collect_req_i) begin
                        raddr <= root0_lo_i;
                        rhi   <= root0_hi_i;
                        rsel  <= 1'b0;
                        ssp   <= '0;
                        ovf   <= 1'b0;
                        st    <= G_ROOT;
                    end
                end

                G_SCAN: begin
                    if (need > BW'(NB) || scanned == BW'(NB)) begin
                        alloc_done_o <= 1'b1;
                        alloc_ok_o   <= 1'b0;
                        st           <= G_IDLE;
                    end else begin
                        scanned <= scanned + 1'b1;
                        if (atb[idx] == A_FREE && run_len + 1'b1 == need) begin
                            run_start <= run_first;
                            st        <= G_CLAIM;
                        end else begin
                            if (atb[idx] == A_FREE) begin
                                run_start <= run_first;
                                run_len   <= run_len + 1'b1;
                            end else begin
                                run_len <= '0;
                            end
                            // Blocks NB-1 and 0 are not adjacent.
                            if (idx == BW'(NB - 1)) begin
                                idx     <= '0;
                                run_len <= '0;
                            end else begin
                                idx <= idx + 1'b1;
                            end
                        end
                    end
                end

                G_CLAIM: begin
                    // run_start .. run_start + need - 1, one block per cycle;
                    // idx walks back from the last block found.
                    if (idx == run_start) begin
                        atb[idx] <= A_HEAD;
                        zaddr    <= POOL_BASE + {run_start, 4'b0000};
                        zend     <= POOL_BASE + {run_start, 4'b0000} + {need, 4'b0000};
                        free_cnt <= free_cnt - 32'(need);
                        rover    <= (run_start + need >= BW'(NB)) ? '0 : run_start + need;
                        st       <= G_ZERO;
                    end else begin
                        atb[idx] <= A_TAIL;
                        idx      <= idx - 1'b1;
                    end
                end

                G_ZERO: begin
                    if (zaddr == zend) begin
                        alloc_done_o <= 1'b1;
                        alloc_ok_o   <= 1'b1;
                        alloc_addr_o <= POOL_BASE + {run_start, 4'b0000};
                        st           <= G_IDLE;
                    end else begin
                        mem_req_o    <= 1'b1;
                        mem_we_o     <= 1'b1;
                        mem_tag_we_o <= 1'b1;
                        mem_addr_o   <= zaddr;
                        mem_wdata_o  <= '0;
                        mem_wtag_o   <= '0;
                        st           <= G_ZERO_W;
                    end
                end
                G_ZERO_W: begin
                    if (mem_ack_i) begin
                        zaddr <= zaddr + 32'd4;
                        st    <= G_ZERO;
                    end
                end

                G_ROOT: begin
                    if (raddr >= rhi) begin
                        if (!rsel) begin
                            raddr <= root1_lo_i;
                            rhi   <= root1_hi_i;
                            rsel  <= 1'b1;
                        end else begin
                            rescanning <= 1'b0;
                            st         <= G_POP;
                        end
                    end else begin
                        mem_read(raddr);
                        st <= G_ROOT_W;
                    end
                end
                G_ROOT_W: begin
                    if (mem_ack_i) begin
                        if (cand_ptr) try_mark(cand_blk);
                        raddr <= raddr + 32'd4;
                        st    <= G_ROOT;
                    end
                end

                G_POP: begin
                    if (ssp != '0) begin
                        oblk  <= stk[ssp - 1'b1];
                        oword <= '0;
                        ssp   <= ssp - 1'b1;
                        st    <= G_OBJ;
                    end else if (rescanning) begin
                        idx <= idx + 1'b1;
                        st  <= G_RESCAN;
                    end else if (ovf) begin
                        ovf        <= 1'b0;
                        rescanning <= 1'b1;
                        idx        <= '0;
                        st         <= G_RESCAN;
                    end else begin
                        idx     <= '0;
                        freeing <= 1'b0;
                        st      <= G_SWEEP;
                    end
                end
                G_OBJ: begin
                    mem_read(POOL_BASE + {oblk, 4'b0000} + {28'b0, oword, 2'b00});
                    st <= G_OBJ_W;
                end
                G_OBJ_W: begin
                    if (mem_ack_i) begin
                        if (cand_ptr) try_mark(cand_blk);
                        if (oword != 2'd3) begin
                            oword <= oword + 1'b1;
                            st    <= G_OBJ;
                        end else if (oblk + 1'b1 < BW'(NB) && atb[oblk + 1'b1] == A_TAIL) begin
                            oblk  <= oblk + 1'b1;
                            oword <= '0;
                            st    <= G_OBJ;
                        end else begin
                            st <= G_POP;
                        end
                    end
                end

                G_RESCAN: begin
                    if (idx == BW'(NB)) begin
                        if (ovf) begin
                            ovf <= 1'b0;
                            idx <= '0;
                        end else begin
                            rescanning <= 1'b0;
                            idx        <= '0;
                            freeing    <= 1'b0;
                            st         <= G_SWEEP;
                        end
                    end else if (atb[idx] == A_MARK) begin
                        oblk  <= idx;
                        oword <= '0;
                        st    <= G_OBJ;
                    end else begin
                        idx <= idx + 1'b1;
                    end
                end

                G_SWEEP: begin
                    if (idx == BW'(NB)) begin
                        st <= G_DONE;
                    end else begin
                        unique case (atb[idx])
                            A_HEAD: begin
                                atb[idx] <= A_FREE;
                                freeing  <= 1'b1;
                                free_cnt <= free_cnt + 32'd1;
                            end
                            A_TAIL: begin
                                if (freeing) begin
                                    atb[idx] <= A_FREE;
                                    free_cnt <= free_cnt + 32'd1;
                                end
                            end
                            A_MARK: begin
                                atb[idx] <= A_HEAD;
                                freeing  <= 1'b0;
                            end
                            default: freeing <= 1'b0;
                        endcase
                        idx <= idx + 1'b1;
                    end
                end

                G_DONE: begin
                    collect_done_o <= 1'b1;
                    ncoll          <= ncoll + 32'd1;
                    rover          <= '0;
                    st             <= G_IDLE;
                end

                default: st <= G_IDLE;
            endcase
        end
    end

endmodule
