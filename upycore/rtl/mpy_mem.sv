`include "mpy_defs.svh"

// Byte-addressed flash and SRAM with a 4-bit tag beside every 32-bit word.
// Tags live in side arrays, eight per word. One request at a time: a
// one-cycle req_i pulse starts it and ack_o pulses when it completes,
// SRAM_LATENCY cycles later (plus FLASH_WAIT_STATES for flash). be_i picks
// the bytes a store writes; tag_we_i also writes the tag. A flash store, an
// unaligned word, or an address outside both regions answers with fault_o.
//
// +IMAGE=<hex> loads flash words and +TAGS=<hex> the packed flash tags
// (upycore/tools/mpy_link.py writes both).
module mpy_mem #(
    parameter int FLASH_WAIT_STATES = MPY_FLASH_WAIT_STATES,
    parameter int SRAM_LATENCY = MPY_SRAM_LATENCY
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    input  logic        req_i,
    input  logic        we_i,
    input  logic        tag_we_i,
    input  logic [3:0]  be_i,
    input  logic [31:0] addr_i,
    input  logic [31:0] wdata_i,
    input  logic [3:0]  wtag_i,
    output logic        ack_o,
    output logic [31:0] rdata_o,
    output logic [3:0]  rtag_o,
    output logic        fault_o,
    output logic [3:0]  fault_reason_o
);

    logic [31:0] sram      [0:MPY_SRAM_WORDS-1];
    logic [31:0] sram_tags [0:MPY_SRAM_TAG_WORDS-1];
    logic [31:0] flash     [0:MPY_FLASH_WORDS-1];
    logic [31:0] flash_tags[0:MPY_FLASH_TAG_WORDS-1];

    logic [7:0]  phase_r;
    logic        we_r;
    logic        tag_we_r;
    logic [3:0]  be_r;
    logic [31:0] addr_r;
    logic [31:0] wdata_r;
    logic [3:0]  wtag_r;

    logic        aligned;
    logic [2:0]  region;
    logic [16:0] fidx;
    logic [15:0] sidx;
    logic [31:0] sword;
    logic [31:0] merged;

    assign aligned = (addr_r[1:0] == 2'b00);
    assign region  = mpy_region_of(addr_r);
    assign fidx    = 17'((addr_r - MPY_FLASH_BASE) >> 2);
    assign sidx    = 16'((addr_r - MPY_SRAM_BASE) >> 2);
    assign sword   = sram[sidx];
    always_comb begin
        for (int b = 0; b < 4; b++)
            merged[8*b +: 8] = be_r[b] ? wdata_r[8*b +: 8] : sword[8*b +: 8];
    end

    initial begin
        string path;
        for (int i = 0; i < MPY_FLASH_WORDS; i++) flash[i] = '0;
        for (int i = 0; i < MPY_FLASH_TAG_WORDS; i++) flash_tags[i] = '0;
        for (int i = 0; i < MPY_SRAM_WORDS; i++) sram[i] = '0;
        for (int i = 0; i < MPY_SRAM_TAG_WORDS; i++) sram_tags[i] = '0;
        if ($value$plusargs("IMAGE=%s", path)) $readmemh(path, flash);
        if ($value$plusargs("TAGS=%s", path)) $readmemh(path, flash_tags);
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            phase_r        <= '0;
            we_r           <= 1'b0;
            tag_we_r       <= 1'b0;
            be_r           <= '0;
            addr_r         <= '0;
            wdata_r        <= '0;
            wtag_r         <= '0;
            ack_o          <= 1'b0;
            rdata_o        <= '0;
            rtag_o         <= '0;
            fault_o        <= 1'b0;
            fault_reason_o <= MPY_FAULT_NONE;
        end else begin
            ack_o          <= 1'b0;
            fault_o        <= 1'b0;
            fault_reason_o <= MPY_FAULT_NONE;
            if (phase_r == 8'd1) begin
                phase_r <= '0;
                ack_o   <= 1'b1;
                rdata_o <= '0;
                rtag_o  <= '0;
                if (!aligned) begin
                    fault_o        <= 1'b1;
                    fault_reason_o <= MPY_FAULT_UNALIGNED;
                end else if (region == MPY_REGION_FLASH) begin
                    if (we_r) begin
                        fault_o        <= 1'b1;
                        fault_reason_o <= MPY_FAULT_FLASH_STORE;
                    end else begin
                        rdata_o <= flash[fidx];
                        rtag_o  <= mpy_nibble_read(flash_tags[fidx[16:3]], fidx[2:0]);
                    end
                end else if (region == MPY_REGION_SRAM) begin
                    rdata_o <= sword;
                    rtag_o  <= mpy_nibble_read(sram_tags[sidx[15:3]], sidx[2:0]);
                    if (we_r) begin
                        sram[sidx] <= merged;
                        if (tag_we_r)
                            sram_tags[sidx[15:3]] <= mpy_nibble_write(
                                sram_tags[sidx[15:3]], sidx[2:0], wtag_r);
                    end
                end else begin
                    fault_o        <= 1'b1;
                    fault_reason_o <= MPY_FAULT_BUS;
                end
            end else if (phase_r != 8'd0) begin
                phase_r <= phase_r - 8'd1;
            end else if (req_i) begin
                we_r     <= we_i;
                tag_we_r <= tag_we_i;
                be_r     <= be_i;
                addr_r   <= addr_i;
                wdata_r  <= wdata_i;
                wtag_r   <= wtag_i;
                if (mpy_region_of(addr_i) == MPY_REGION_FLASH)
                    phase_r <= 8'(SRAM_LATENCY + FLASH_WAIT_STATES);
                else
                    phase_r <= 8'(SRAM_LATENCY);
            end
        end
    end

endmodule
