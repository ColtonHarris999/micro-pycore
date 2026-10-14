`include "mpy_defs.svh"

// Byte-addressed flash and SRAM. Data words are 32 bits. The tag does not
// sit in that word. A spilled frame stores 64 payload words and eight packed
// tag words inside the 16 KB reserve. Every other SRAM slot keeps its nibble
// in a side array, eight tags per word. A store with tag_acc_i low leaves
// the nibble alone. There is no DRAM and no cache. A flash store faults.
// The first 8 bytes of flash stay reserved.
module mpy_mem #(
    parameter int FLASH_WAIT_STATES = MPY_FLASH_WAIT_STATES
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    input  logic        req_i,
    input  logic        we_i,
    input  logic        tag_acc_i,
    input  logic [31:0] addr_i,
    input  logic [31:0] wdata_i,
    input  logic [3:0]  wtag_i,
    output logic        ack_o,
    output logic [31:0] rdata_o,
    output logic [3:0]  rtag_o,
    output logic [31:0] tag_word_o,
    output logic        fault_o,
    output logic [3:0]  fault_reason_o,
    output logic [2:0]  region_o,

    input  logic        spill_i,
    input  logic [31:0] spill_pc_i,
    input  logic [15:0] spill_nstate_i,
    output logic [MPY_RF_ADDR_W-1:0] spill_idx_o,
    input  logic [MPY_ENTRY_WIDTH-1:0] spill_entry_i,
    output logic        spill_busy_o,
    output logic        spill_done_o,
    output logic        spill_fault_o,
    output logic [5:0]  frame_depth_o,
    output logic [4:0]  spill_frame_o
);

    logic [31:0] sram      [0:MPY_SRAM_WORDS-1];
    logic [31:0] sram_tags [0:MPY_SRAM_TAG_WORDS-1];
    logic [31:0] flash     [0:MPY_FLASH_WORDS-1];
    logic [31:0] flash_tags[0:MPY_FLASH_TAG_WORDS-1];
    logic [31:0] mmio      [0:MPY_MMIO_WORDS-1];
    logic [31:0] sim_page  [0:MPY_SIM_WORDS-1];

    logic [7:0]  phase_r;
    logic        req_we_r;
    logic        req_tag_acc_r;
    logic [31:0] req_addr_r;
    logic [31:0] req_wdata_r;
    logic [3:0]  req_wtag_r;

    logic        spill_active_r;
    logic [MPY_RF_ADDR_W-1:0] spill_idx_r;
    logic [4:0]  spill_frame_r;
    logic [31:0] spill_pc_r;
    logic [15:0] spill_nstate_r;
    logic [5:0]  frame_depth_r;

    logic        req_aligned;
    logic [2:0]  req_region;
    logic        req_flash;
    logic        req_sram;
    logic        req_mmio;
    logic        req_sim;
    logic [16:0] flash_index;
    logic [13:0] flash_tag_index;
    logic [15:0] sram_index;
    logic [12:0] sram_tag_index;
    logic [11:0] frame_hit;
    logic        frame_hit_valid;
    logic [4:0]  frame_hit_frame;
    logic [5:0]  frame_hit_slot;
    logic [15:0] frame_tag_index;
    logic [9:0]  mmio_index;
    logic [5:0]  sim_index;

    logic [15:0] spill_pay_index;
    logic [15:0] spill_tag_index;
    logic [15:0] spill_pc_index;
    logic [15:0] spill_nstate_index;
    logic [15:0] spill_frame_index;
    logic [15:0] spill_zero_index;
    logic [31:0] spill_tag_next;
    logic [31:0] frame_tag_next;
    logic [31:0] side_tag_next;

    assign spill_idx_o   = spill_idx_r;
    assign spill_busy_o  = spill_active_r;
    assign frame_depth_o = frame_depth_r;
    assign spill_frame_o = spill_frame_r;

    // Indices are module wires. A function-local index on an NBA into these
    // arrays is not reliable in this simulator.
    assign req_aligned = (req_addr_r[1:0] == 2'b00);
    assign req_region  = mpy_region_of(req_addr_r);
    assign req_flash   = req_aligned && (req_region == MPY_REGION_FLASH);
    assign req_sram    = req_aligned && (req_region == MPY_REGION_SRAM);
    assign req_mmio    = req_aligned && (req_region == MPY_REGION_MMIO);
    assign req_sim     = req_aligned && (req_region == MPY_REGION_SIM);

    assign flash_index     = req_flash ? mpy_flash_word_index(req_addr_r) : '0;
    assign flash_tag_index = flash_index[16:3];
    assign sram_index      = req_sram ? mpy_sram_word_index(req_addr_r) : '0;
    assign sram_tag_index  = sram_index[15:3];
    assign frame_hit       = req_sram ? mpy_frame_payload_hit(req_addr_r) : '0;
    assign frame_hit_valid = frame_hit[11];
    assign frame_hit_frame = frame_hit[10:6];
    assign frame_hit_slot  = frame_hit[5:0];
    assign frame_tag_index = mpy_sram_word_index(
        mpy_frame_tag_addr(frame_hit_frame, frame_hit_slot));
    assign mmio_index = req_mmio ? 10'((req_addr_r - MPY_MMIO_BASE) >> 2) : '0;
    assign sim_index  = req_sim  ? 6'((req_addr_r - MPY_SIM_BASE) >> 2) : '0;

    assign frame_tag_next = mpy_nibble_write(
        sram[frame_tag_index], frame_hit_slot[2:0], req_wtag_r);
    assign side_tag_next = mpy_nibble_write(
        sram_tags[sram_tag_index], sram_index[2:0], req_wtag_r);

    assign spill_pay_index = mpy_sram_word_index(
        mpy_frame_payload_addr(spill_frame_r, spill_idx_r));
    assign spill_tag_index = mpy_sram_word_index(
        mpy_frame_tag_addr(spill_frame_r, spill_idx_r));
    assign spill_pc_index = mpy_sram_word_index(
        mpy_frame_header_addr(spill_frame_r, 2'(MPY_FRAME_HDR_PC)));
    assign spill_nstate_index = mpy_sram_word_index(
        mpy_frame_header_addr(spill_frame_r, 2'(MPY_FRAME_HDR_NSTATE)));
    assign spill_frame_index = mpy_sram_word_index(
        mpy_frame_header_addr(spill_frame_r, 2'(MPY_FRAME_HDR_INDEX)));
    assign spill_zero_index = mpy_sram_word_index(
        mpy_frame_header_addr(spill_frame_r, 2'(MPY_FRAME_HDR_ZERO)));
    assign spill_tag_next = mpy_nibble_write(
        sram[spill_tag_index], spill_idx_r[2:0], mpy_entry_tag(spill_entry_i));

    initial begin
        for (int i = 0; i < MPY_FLASH_WORDS; i++)
            flash[i] = '0;
        for (int i = 0; i < MPY_FLASH_TAG_WORDS; i++)
            flash_tags[i] = '0;
        for (int i = 0; i < MPY_SRAM_WORDS; i++)
            sram[i] = '0;
        for (int i = 0; i < MPY_SRAM_TAG_WORDS; i++)
            sram_tags[i] = '0;
        for (int i = 0; i < MPY_MMIO_WORDS; i++)
            mmio[i] = '0;
        for (int i = 0; i < MPY_SIM_WORDS; i++)
            sim_page[i] = '0;
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            phase_r        <= '0;
            req_we_r       <= 1'b0;
            req_tag_acc_r  <= 1'b0;
            req_addr_r     <= '0;
            req_wdata_r    <= '0;
            req_wtag_r     <= '0;
            ack_o          <= 1'b0;
            rdata_o        <= '0;
            rtag_o         <= '0;
            tag_word_o     <= '0;
            fault_o        <= 1'b0;
            fault_reason_o <= MPY_FAULT_NONE;
            region_o       <= MPY_REGION_NONE;
            spill_active_r <= 1'b0;
            spill_idx_r    <= '0;
            spill_frame_r  <= '0;
            spill_pc_r     <= '0;
            spill_nstate_r <= '0;
            frame_depth_r  <= '0;
            spill_done_o   <= 1'b0;
            spill_fault_o  <= 1'b0;
        end else begin
            ack_o          <= 1'b0;
            fault_o        <= 1'b0;
            fault_reason_o <= MPY_FAULT_NONE;
            spill_done_o   <= 1'b0;
            spill_fault_o  <= 1'b0;

            if (spill_active_r) begin
                sram[spill_pay_index] <= mpy_entry_payload(spill_entry_i);
                sram[spill_tag_index] <= spill_tag_next;
                if (spill_idx_r == 6'(MPY_RF_DEPTH - 1)) begin
                    sram[spill_pc_index]      <= spill_pc_r;
                    sram[spill_nstate_index]  <= {16'b0, spill_nstate_r};
                    sram[spill_frame_index]   <= {27'b0, spill_frame_r};
                    sram[spill_zero_index]    <= 32'b0;
                    spill_active_r <= 1'b0;
                    spill_done_o   <= 1'b1;
                    frame_depth_r  <= frame_depth_r + 6'd1;
                end else begin
                    spill_idx_r <= spill_idx_r + 6'd1;
                end
            end else if (phase_r == 8'd1) begin
                phase_r  <= '0;
                ack_o    <= 1'b1;
                region_o <= req_region;
                rdata_o  <= '0;
                rtag_o   <= '0;
                tag_word_o <= '0;
                if (!req_aligned) begin
                    fault_o        <= 1'b1;
                    fault_reason_o <= MPY_FAULT_UNALIGNED;
                end else if (req_region == MPY_REGION_NONE) begin
                    fault_o        <= 1'b1;
                    fault_reason_o <= MPY_FAULT_BUS;
                end else if (req_flash) begin
                    if (req_we_r) begin
                        fault_o        <= 1'b1;
                        fault_reason_o <= MPY_FAULT_FLASH_STORE;
                    end else begin
                        rdata_o    <= flash[flash_index];
                        rtag_o     <= mpy_nibble_read(
                            flash_tags[flash_tag_index], flash_index[2:0]);
                        tag_word_o <= flash_tags[flash_tag_index];
                    end
                end else if (req_sram) begin
                    rdata_o <= sram[sram_index];
                    if (frame_hit_valid) begin
                        rtag_o     <= mpy_nibble_read(
                            sram[frame_tag_index], frame_hit_slot[2:0]);
                        tag_word_o <= sram[frame_tag_index];
                        if (req_we_r) begin
                            sram[sram_index] <= req_wdata_r;
                            if (req_tag_acc_r)
                                sram[frame_tag_index] <= frame_tag_next;
                        end
                    end else begin
                        rtag_o     <= mpy_nibble_read(
                            sram_tags[sram_tag_index], sram_index[2:0]);
                        tag_word_o <= sram_tags[sram_tag_index];
                        if (req_we_r) begin
                            sram[sram_index] <= req_wdata_r;
                            if (req_tag_acc_r)
                                sram_tags[sram_tag_index] <= side_tag_next;
                        end
                    end
                end else if (req_mmio) begin
                    rdata_o <= mmio[mmio_index];
                    if (req_we_r)
                        mmio[mmio_index] <= req_wdata_r;
                end else if (req_sim) begin
                    rdata_o <= sim_page[sim_index];
                    if (req_we_r)
                        sim_page[sim_index] <= req_wdata_r;
                end
            end else if (phase_r != 8'd0) begin
                phase_r <= phase_r - 8'd1;
            end else if (req_i) begin
                req_we_r      <= we_i;
                req_tag_acc_r <= tag_acc_i;
                req_addr_r    <= addr_i;
                req_wdata_r   <= wdata_i;
                req_wtag_r    <= wtag_i;
                if (mpy_region_of(addr_i) == MPY_REGION_FLASH)
                    phase_r <= 8'(MPY_SRAM_LATENCY + FLASH_WAIT_STATES);
                else
                    phase_r <= 8'(MPY_SRAM_LATENCY);
            end else if (spill_i) begin
                if (frame_depth_r == 6'(MPY_FRAME_DEPTH)) begin
                    spill_fault_o  <= 1'b1;
                    fault_reason_o <= MPY_FAULT_STACK;
                end else begin
                    spill_active_r <= 1'b1;
                    spill_idx_r    <= '0;
                    spill_frame_r  <= frame_depth_r[4:0];
                    spill_pc_r     <= spill_pc_i;
                    spill_nstate_r <= spill_nstate_i;
                end
            end
        end
    end

endmodule
