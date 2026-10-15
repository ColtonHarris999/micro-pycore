`include "mpy_defs.svh"

// 64-entry register file. One 36-bit array: tag[35:32] beside payload[31:0].
// A read of an index returns both. INT64 and COMPLEX occupy two entries,
// SHORT_STR occupies four, and each extra entry is CONT.
module mpy_regfile (
    input  logic                          clk_i,
    input  logic                          rst_n_i,

    input  logic [MPY_RF_ADDR_W-1:0]      rs1_addr_i,
    input  logic [MPY_RF_ADDR_W-1:0]      rs2_addr_i,
    output logic [MPY_ENTRY_WIDTH-1:0]    rs1_o,
    output logic [MPY_TAG_WIDTH-1:0]      rs1_tag_o,
    output logic [MPY_VAL_WIDTH-1:0]      rs1_pay_o,
    output logic [MPY_ENTRY_WIDTH-1:0]    rs2_o,
    output logic [MPY_TAG_WIDTH-1:0]      rs2_tag_o,
    output logic [MPY_VAL_WIDTH-1:0]      rs2_pay_o,

    input  logic                          rd_we_i,
    input  logic [MPY_RF_ADDR_W-1:0]      rd_addr_i,
    input  logic [MPY_ENTRY_WIDTH-1:0]    rd_i,

    // wide_pay_i is {word3, word2, word1, word0}. word0 is the head payload.
    input  logic                          wide_we_i,
    input  logic [MPY_RF_ADDR_W-1:0]      wide_addr_i,
    input  logic [MPY_TAG_WIDTH-1:0]      wide_tag_i,
    input  logic [127:0]                  wide_pay_i,
    output logic                          wide_fault_o,

    input  logic [MPY_RF_ADDR_W-1:0]      idx_addr_i,
    output logic [MPY_ENTRY_WIDTH-1:0]    idx_entry_o,
    input  logic                          idx_we_i,
    input  logic [MPY_ENTRY_WIDTH-1:0]    idx_wdata_i
);

    logic [MPY_ENTRY_WIDTH-1:0] rf [0:MPY_RF_DEPTH-1];

    logic [2:0] span_c;
    logic [6:0] wide_base_c;
    // 6-bit slots so a wide write indexes the one array directly.
    // The fault check rejects a span that would pass entry 63.
    logic [MPY_RF_ADDR_W-1:0] wide_slot0;
    logic [MPY_RF_ADDR_W-1:0] wide_slot1;
    logic [MPY_RF_ADDR_W-1:0] wide_slot2;
    logic [MPY_RF_ADDR_W-1:0] wide_slot3;

    assign rs1_o     = rf[rs1_addr_i];
    assign rs1_tag_o = mpy_entry_tag(rs1_o);
    assign rs1_pay_o = mpy_entry_payload(rs1_o);
    assign rs2_o     = rf[rs2_addr_i];
    assign rs2_tag_o = mpy_entry_tag(rs2_o);
    assign rs2_pay_o = mpy_entry_payload(rs2_o);
    assign idx_entry_o = rf[idx_addr_i];

    assign span_c = mpy_tag_span(wide_tag_i);
    assign wide_base_c = {1'b0, wide_addr_i};
    assign wide_slot0 = wide_base_c[MPY_RF_ADDR_W-1:0];
    assign wide_slot1 = MPY_RF_ADDR_W'(wide_base_c + 7'd1);
    assign wide_slot2 = MPY_RF_ADDR_W'(wide_base_c + 7'd2);
    assign wide_slot3 = MPY_RF_ADDR_W'(wide_base_c + 7'd3);

    always_comb begin
        wide_fault_o = 1'b0;
        if (wide_we_i) begin
            if (span_c == 3'd0)
                wide_fault_o = 1'b1;
            else if ((wide_base_c + {4'b0, span_c}) > 7'(MPY_RF_DEPTH))
                wide_fault_o = 1'b1;
            else if ((wide_tag_i == MPY_TAG_SHORT_STR) &&
                     (wide_pay_i[7:0] > 8'(MPY_SHORT_STR_MAX_BYTES)))
                wide_fault_o = 1'b1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            for (int i = 0; i < MPY_RF_DEPTH; i++)
                rf[i] <= mpy_make_control(MPY_CTL_EMPTY);
        end else if (wide_we_i && !wide_fault_o) begin
            rf[wide_slot0] <= mpy_make_entry(wide_tag_i, wide_pay_i[31:0]);
            if (span_c >= 3'd2)
                rf[wide_slot1] <= mpy_make_entry(MPY_TAG_CONT, wide_pay_i[63:32]);
            if (span_c == 3'(MPY_SPAN_SHORT_STR)) begin
                rf[wide_slot2] <= mpy_make_entry(MPY_TAG_CONT, wide_pay_i[95:64]);
                rf[wide_slot3] <= mpy_make_entry(MPY_TAG_CONT, wide_pay_i[127:96]);
            end
        end else if (idx_we_i) begin
            rf[idx_addr_i] <= idx_wdata_i;
        end else if (rd_we_i) begin
            rf[rd_addr_i] <= rd_i;
        end
    end

endmodule
