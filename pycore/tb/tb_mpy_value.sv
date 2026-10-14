`include "mpy_defs.svh"

// Reads and writes every tag, spills one frame as 32-bit words plus packed
// nibbles, and checks a MUT_COLLEC address with the low bits cleared.
module tb_mpy_value;
    logic clk;
    logic rst_n;

    logic [MPY_RF_ADDR_W-1:0]   rs1_addr;
    logic [MPY_RF_ADDR_W-1:0]   rs2_addr;
    logic [MPY_ENTRY_WIDTH-1:0] rs1;
    logic [MPY_TAG_WIDTH-1:0]   rs1_tag;
    logic [MPY_VAL_WIDTH-1:0]   rs1_pay;
    logic [MPY_ENTRY_WIDTH-1:0] rs2;
    logic [MPY_TAG_WIDTH-1:0]   rs2_tag;
    logic [MPY_VAL_WIDTH-1:0]   rs2_pay;
    logic                       rd_we;
    logic [MPY_RF_ADDR_W-1:0]   rd_addr;
    logic [MPY_ENTRY_WIDTH-1:0] rd;
    logic                       wide_we;
    logic [MPY_RF_ADDR_W-1:0]   wide_addr;
    logic [MPY_TAG_WIDTH-1:0]   wide_tag;
    logic [127:0]               wide_pay;
    logic                       wide_fault;
    logic [MPY_RF_ADDR_W-1:0]   idx_addr;
    logic [MPY_ENTRY_WIDTH-1:0] idx_entry;
    logic                       idx_we;
    logic [MPY_ENTRY_WIDTH-1:0] idx_wdata;

    logic        req;
    logic        we;
    logic        tag_acc;
    logic [31:0] addr;
    logic [31:0] wdata;
    logic [3:0]  wtag;
    logic        ack;
    logic [31:0] rdata;
    logic [3:0]  rtag;
    logic [31:0] tag_word;
    logic        fault;
    logic [3:0]  fault_reason;
    logic [2:0]  region;

    logic        spill;
    logic [31:0] spill_pc;
    logic [15:0] spill_nstate;
    logic [MPY_RF_ADDR_W-1:0] spill_idx;
    logic [MPY_ENTRY_WIDTH-1:0] spill_entry;
    logic        spill_busy;
    logic        spill_done;
    logic        spill_fault;
    logic [5:0]  frame_depth;
    logic [4:0]  spill_frame;

    mpy_regfile dut_rf (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .rs1_addr_i(rs1_addr),
        .rs2_addr_i(rs2_addr),
        .rs1_o(rs1),
        .rs1_tag_o(rs1_tag),
        .rs1_pay_o(rs1_pay),
        .rs2_o(rs2),
        .rs2_tag_o(rs2_tag),
        .rs2_pay_o(rs2_pay),
        .rd_we_i(rd_we),
        .rd_addr_i(rd_addr),
        .rd_i(rd),
        .wide_we_i(wide_we),
        .wide_addr_i(wide_addr),
        .wide_tag_i(wide_tag),
        .wide_pay_i(wide_pay),
        .wide_fault_o(wide_fault),
        .idx_addr_i(idx_addr),
        .idx_entry_o(idx_entry),
        .idx_we_i(idx_we),
        .idx_wdata_i(idx_wdata)
    );

    mpy_mem dut_mem (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .req_i(req),
        .we_i(we),
        .tag_acc_i(tag_acc),
        .addr_i(addr),
        .wdata_i(wdata),
        .wtag_i(wtag),
        .ack_o(ack),
        .rdata_o(rdata),
        .rtag_o(rtag),
        .tag_word_o(tag_word),
        .fault_o(fault),
        .fault_reason_o(fault_reason),
        .region_o(region),
        .spill_i(spill),
        .spill_pc_i(spill_pc),
        .spill_nstate_i(spill_nstate),
        .spill_idx_o(spill_idx),
        .spill_entry_i(spill_entry),
        .spill_busy_o(spill_busy),
        .spill_done_o(spill_done),
        .spill_fault_o(spill_fault),
        .frame_depth_o(frame_depth),
        .spill_frame_o(spill_frame)
    );

    assign idx_addr   = spill_idx;
    assign spill_entry = idx_entry;

    function automatic string tag_name(input logic [3:0] tag);
        case (tag)
            MPY_TAG_CONTROL:    tag_name = "CONTROL";
            MPY_TAG_INT:        tag_name = "INT";
            MPY_TAG_INT64:      tag_name = "INT64";
            MPY_TAG_FLOAT:      tag_name = "FLOAT";
            MPY_TAG_COMPLEX:    tag_name = "COMPLEX";
            MPY_TAG_RESERVED:   tag_name = "reserved";
            MPY_TAG_QSTR:       tag_name = "QSTR";
            MPY_TAG_SHORT_STR:  tag_name = "SHORT_STR";
            MPY_TAG_STR:        tag_name = "STR";
            MPY_TAG_TUPLE:      tag_name = "TUPLE";
            MPY_TAG_MUT_COLLEC: tag_name = "MUT_COLLEC";
            MPY_TAG_RANGE:      tag_name = "RANGE";
            MPY_TAG_ITER:       tag_name = "ITER";
            MPY_TAG_BYTES:      tag_name = "BYTES";
            MPY_TAG_OBJECT:     tag_name = "OBJECT";
            MPY_TAG_CONT:       tag_name = "CONT";
            default:            tag_name = "?";
        endcase
    endfunction

    function automatic string mut_name(input logic [1:0] kind);
        case (kind)
            MPY_MUT_LIST:      mut_name = "list";
            MPY_MUT_DICT:      mut_name = "dict";
            MPY_MUT_SET:       mut_name = "set";
            MPY_MUT_BYTEARRAY: mut_name = "bytearray";
            default:           mut_name = "?";
        endcase
    endfunction

    function automatic logic tag_is_pointer_expected(input logic [3:0] tag);
        tag_is_pointer_expected = (tag == MPY_TAG_STR) || (tag == MPY_TAG_TUPLE) ||
            (tag == MPY_TAG_MUT_COLLEC) || (tag == MPY_TAG_RANGE) ||
            (tag == MPY_TAG_ITER) || (tag == MPY_TAG_BYTES) ||
            (tag == MPY_TAG_OBJECT);
    endfunction

    function automatic logic [MPY_ENTRY_WIDTH-1:0] spill_entry_at(input int slot);
        logic [3:0] tag;
        logic [31:0] payload;
        begin
            tag = 4'(slot);
            payload = 32'hA500_0000 | 32'(slot);
            if (slot == 0)
                payload = {28'b0, MPY_CTL_FALSE};
            else if (slot == 16)
                payload = {28'b0, MPY_CTL_TRUE};
            else if (slot == 32)
                payload = {28'b0, MPY_CTL_NONE};
            else if (slot == 48)
                payload = {28'b0, MPY_CTL_TOMBSTONE};
            else if (slot == 10)
                payload = mpy_mut_payload(MPY_MUT_LIST, MPY_GC_POOL_BASE);
            else if (slot == 26)
                payload = mpy_mut_payload(MPY_MUT_DICT, MPY_GC_POOL_BASE);
            else if (slot == 42)
                payload = mpy_mut_payload(MPY_MUT_SET, MPY_GC_POOL_BASE);
            else if (slot == 58)
                payload = mpy_mut_payload(MPY_MUT_BYTEARRAY, MPY_GC_POOL_BASE);
            spill_entry_at = mpy_make_entry(tag, payload);
        end
    endfunction

    task automatic check(input logic cond, input string msg);
        if (!cond) begin
            $error("%s", msg);
            $fatal(1, "mpy value encoding check failed");
        end
    endtask

    task automatic tick;
        #5 clk = 1'b1;
        #5 clk = 1'b0;
    endtask

    task automatic settle;
        #1;
    endtask

    task automatic write_rf(
        input logic [MPY_RF_ADDR_W-1:0] slot,
        input logic [MPY_ENTRY_WIDTH-1:0] entry
    );
        begin
            rd_we = 1'b1;
            rd_addr = slot;
            rd = entry;
            rs1_addr = slot;
            tick();
            rd_we = 1'b0;
        end
    endtask

    task automatic bus(
        input logic        do_we,
        input logic        do_tag,
        input logic [31:0] bus_addr,
        input logic [31:0] bus_wdata,
        input logic [3:0]  bus_wtag,
        output logic [31:0] bus_rdata,
        output logic [3:0]  bus_rtag,
        output logic [31:0] bus_tag_word,
        output logic        bus_fault,
        output logic [3:0]  bus_reason,
        output logic [2:0]  bus_region,
        output int          ticks
    );
        int guard;
        begin
            req = 1'b1;
            we = do_we;
            tag_acc = do_tag;
            addr = bus_addr;
            wdata = bus_wdata;
            wtag = bus_wtag;
            ticks = 0;
            guard = 0;
            while (!ack && (guard < 16)) begin
                tick();
                ticks = ticks + 1;
                guard = guard + 1;
            end
            check(ack, "bus request timed out");
            bus_rdata = rdata;
            bus_rtag = rtag;
            bus_tag_word = tag_word;
            bus_fault = fault;
            bus_reason = fault_reason;
            bus_region = region;
            req = 1'b0;
            tick();
        end
    endtask

    task automatic expect_ok(
        input logic        do_we,
        input logic        do_tag,
        input logic [31:0] bus_addr,
        input logic [31:0] bus_wdata,
        input logic [3:0]  bus_wtag,
        input logic [31:0] exp_data,
        input logic [3:0]  exp_tag,
        input logic [2:0]  exp_region,
        input int          exp_ticks
    );
        logic [31:0] got_data;
        logic [3:0]  got_tag;
        logic [31:0] got_word;
        logic        got_fault;
        logic [3:0]  got_reason;
        logic [2:0]  got_region;
        int          ticks;
        begin
            bus(do_we, do_tag, bus_addr, bus_wdata, bus_wtag,
                got_data, got_tag, got_word, got_fault, got_reason, got_region, ticks);
            check(!got_fault, "expected a successful access");
            check(got_region == exp_region, "region mismatch");
            check(got_data == exp_data, "data mismatch");
            check(got_tag == exp_tag, "tag mismatch");
            check(ticks == exp_ticks, "latency mismatch");
        end
    endtask

    task automatic expect_fault(
        input logic        do_we,
        input logic [31:0] bus_addr,
        input logic [3:0]  exp_reason,
        input logic [2:0]  exp_region
    );
        logic [31:0] got_data;
        logic [3:0]  got_tag;
        logic [31:0] got_word;
        logic        got_fault;
        logic [3:0]  got_reason;
        logic [2:0]  got_region;
        int          ticks;
        begin
            bus(do_we, 1'b0, bus_addr, 32'h0, 4'h0,
                got_data, got_tag, got_word, got_fault, got_reason, got_region, ticks);
            check(got_fault, "expected a fault");
            check(got_reason == exp_reason, "fault reason mismatch");
            check(got_region == exp_region, "fault region mismatch");
        end
    endtask

    task automatic do_spill(
        input logic [31:0] pc,
        input logic [15:0] nstate,
        input logic        reject
    );
        int guard;
        begin
            spill = 1'b1;
            spill_pc = pc;
            spill_nstate = nstate;
            tick();
            spill = 1'b0;
            if (reject) begin
                check(spill_fault, "expected a full frame stack");
                check(!spill_busy, "a rejected spill must stay idle");
                tick();
            end else begin
                check(spill_busy, "spill did not start");
                guard = 0;
                while (!spill_done && (guard < 200)) begin
                    tick();
                    guard = guard + 1;
                end
                check(spill_done, "spill did not finish");
                check(!spill_busy, "spill still busy after done");
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        rs1_addr = '0;
        rs2_addr = '0;
        rd_we = 1'b0;
        rd_addr = '0;
        rd = '0;
        wide_we = 1'b0;
        wide_addr = '0;
        wide_tag = '0;
        wide_pay = '0;
        idx_we = 1'b0;
        idx_wdata = '0;
        req = 1'b0;
        we = 1'b0;
        tag_acc = 1'b0;
        addr = '0;
        wdata = '0;
        wtag = '0;
        spill = 1'b0;
        spill_pc = '0;
        spill_nstate = '0;

        check(MPY_RF_DEPTH == 64, "register file is 64 entries");
        check(MPY_ENTRY_WIDTH == 36, "an entry is 36 bits");
        check(MPY_FRAME_DEPTH == 32, "frame stack is 32");
        check(32'(MPY_FRAME_DEPTH * MPY_FRAME_STRIDE) == MPY_FRAME_RESERVE_BYTES,
              "32 frames fill the 16 KB reserve");
        check(MPY_GC_POOL_BASE == 32'h2000_4080, "GC pool base");
        check(MPY_GC_POOL_BYTES == 32'h0003_BF80, "GC pool size");
        check((MPY_GC_POOL_BASE + MPY_GC_POOL_BYTES) ==
              (MPY_SRAM_BASE + MPY_SRAM_BYTES), "GC pool ends at SRAM");
        check(MPY_HANDLER_USED_BYTES == 48, "handler table uses 48 bytes");
        check(MPY_HANDLER_USED_BYTES <= MPY_HANDLER_BYTES, "handler window fits");
        check((MPY_SCHED_DEPTH * MPY_SCHED_ENTRY_WORDS * 4) == MPY_SCHED_BYTES,
              "schedule ring is depth 8");
        check(mpy_region_of(32'h00F4_0000) == MPY_REGION_NONE,
              "256 KB spill at 0xF40000 is not mapped");
        check(mpy_flash_addr_reserved(32'h0) && mpy_flash_addr_reserved(32'h4),
              "flash bytes 0 and 4 are reserved");
        check(!mpy_flash_addr_reserved(32'h8), "flash byte 8 is past the reservation");
        check(mpy_tag_span(MPY_TAG_INT64) == 3'(MPY_SPAN_INT64), "INT64 occupies two");
        check(mpy_tag_span(MPY_TAG_COMPLEX) == 3'(MPY_SPAN_COMPLEX), "COMPLEX occupies two");
        check(mpy_tag_span(MPY_TAG_SHORT_STR) == 3'(MPY_SPAN_SHORT_STR),
              "SHORT_STR occupies four");
        check(mpy_tag_span(MPY_TAG_CONT) == 3'd1, "CONT is one extra entry");
        check(mpy_tag_span(MPY_TAG_RESERVED) == 3'd0, "tag 0101 is reserved");

        tick();
        tick();
        rst_n = 1'b1;
        tick();

        rs1_addr = '0;
        settle();
        check(rs1 == mpy_make_control(MPY_CTL_EMPTY), "reset entry is empty CONTROL");
        check(frame_depth == 6'd0, "reset frame depth is 0");

        $display("REGFILE read/write every tag");
        for (int tag = 0; tag < MPY_TAG_SPACE; tag++) begin
            logic [3:0] code;
            logic [31:0] payload;
            logic [MPY_ENTRY_WIDTH-1:0] entry;
            code = 4'(tag);
            payload = 32'h1000_0000 | 32'(tag);
            entry = mpy_make_entry(code, payload);
            write_rf(MPY_RF_ADDR_W'(tag), entry);
            check(rs1 == entry, "packed read is tag beside payload");
            check(rs1_tag == code, "tag mismatch");
            check(rs1_pay == payload, "payload mismatch");
            check(mpy_tag_is_pointer(code) == tag_is_pointer_expected(code),
                  "pointer class mismatch");
            $display("  tag %04b %-10s payload=0x%08h pointer=%0d",
                     code, tag_name(code), payload, mpy_tag_is_pointer(code));
        end

        write_rf(6'd0, mpy_make_control(MPY_CTL_FALSE));
        check(!mpy_tag_is_pointer(rs1_tag), "False is not a pointer");
        check(rs1_pay[3:0] == MPY_CTL_FALSE, "False is CONTROL kind 4");
        check(mpy_bool_as_int(rs1_pay) == 32'd0, "False counts as int 0");
        write_rf(6'd1, mpy_make_control(MPY_CTL_TRUE));
        check(!mpy_tag_is_pointer(rs1_tag), "True is not a pointer");
        check(rs1_pay[3:0] == MPY_CTL_TRUE, "True is CONTROL kind 5");
        check(mpy_bool_as_int(rs1_pay) == 32'd1, "True counts as int 1");
        $display("CONTROL False kind=%0d as_int=%0d  True kind=%0d as_int=%0d",
                 MPY_CTL_FALSE, mpy_bool_as_int({28'b0, MPY_CTL_FALSE}),
                 MPY_CTL_TRUE, mpy_bool_as_int({28'b0, MPY_CTL_TRUE}));

        $display("WIDE INT64 COMPLEX SHORT_STR");
        wide_we = 1'b1;
        wide_addr = 6'd20;
        wide_tag = MPY_TAG_INT64;
        wide_pay = {64'b0, 32'h0000_0001, 32'h0000_0002};
        settle();
        check(!wide_fault, "INT64 at slot 20 fits");
        rs1_addr = 6'd20;
        rs2_addr = 6'd21;
        tick();
        wide_we = 1'b0;
        check(rs1_tag == MPY_TAG_INT64, "INT64 head tag");
        check(rs1_pay == 32'h0000_0002, "INT64 low half");
        check(rs2_tag == MPY_TAG_CONT, "INT64 high half is CONT");
        check(rs2_pay == 32'h0000_0001, "INT64 high half");
        check(rs2 == {rs2_tag, rs2_pay}, "CONT read is one 36-bit entry");

        wide_we = 1'b1;
        wide_addr = 6'd24;
        wide_tag = MPY_TAG_COMPLEX;
        wide_pay = {64'b0, 32'hBF80_0000, 32'h3F80_0000};
        settle();
        check(!wide_fault, "COMPLEX at slot 24 fits");
        rs1_addr = 6'd24;
        rs2_addr = 6'd25;
        tick();
        wide_we = 1'b0;
        check(rs1_tag == MPY_TAG_COMPLEX && rs1_pay == 32'h3F80_0000, "COMPLEX real");
        check(rs2_tag == MPY_TAG_CONT && rs2_pay == 32'hBF80_0000, "COMPLEX imag is CONT");

        begin
            logic [119:0] bytes;
            logic [31:0] word0;
            bytes = '0;
            bytes[7:0] = 8'h48;
            bytes[15:8] = 8'h69;
            word0 = mpy_short_str_word(8'd2, bytes, 2'd0);
            wide_we = 1'b1;
            wide_addr = 6'd28;
            wide_tag = MPY_TAG_SHORT_STR;
            wide_pay = {mpy_short_str_word(8'd2, bytes, 2'd3),
                        mpy_short_str_word(8'd2, bytes, 2'd2),
                        mpy_short_str_word(8'd2, bytes, 2'd1),
                        word0};
            settle();
            check(!wide_fault, "SHORT_STR length 2 fits");
            rs1_addr = 6'd28;
            rs2_addr = 6'd31;
            tick();
            wide_we = 1'b0;
            check(rs1_tag == MPY_TAG_SHORT_STR, "SHORT_STR head");
            check(rs1_pay == 32'h0069_4802, "SHORT_STR length and first bytes");
            rs2_addr = 6'd29;
            settle();
            check(rs2_tag == MPY_TAG_CONT && rs2_pay == 32'h0, "SHORT_STR CONT 1");
            rs2_addr = 6'd30;
            settle();
            check(rs2_tag == MPY_TAG_CONT, "SHORT_STR CONT 2");
            rs2_addr = 6'd31;
            settle();
            check(rs2_tag == MPY_TAG_CONT, "SHORT_STR CONT 3");
        end

        write_rf(6'd40, mpy_make_entry(MPY_TAG_INT, 32'h1111_1111));
        wide_we = 1'b1;
        wide_addr = 6'd40;
        wide_tag = MPY_TAG_SHORT_STR;
        wide_pay = 128'd16;
        settle();
        check(wide_fault, "SHORT_STR longer than 15 faults");
        tick();
        wide_we = 1'b0;
        rs1_addr = 6'd40;
        settle();
        check(rs1 == mpy_make_entry(MPY_TAG_INT, 32'h1111_1111),
              "rejected SHORT_STR does not write");

        wide_we = 1'b1;
        wide_addr = 6'd61;
        wide_tag = MPY_TAG_SHORT_STR;
        wide_pay = 128'd1;
        settle();
        check(wide_fault, "SHORT_STR does not cross the file");
        wide_addr = 6'd63;
        wide_tag = MPY_TAG_INT64;
        wide_pay = 128'd1;
        settle();
        check(wide_fault, "INT64 does not cross the file");
        wide_addr = 6'd0;
        wide_tag = MPY_TAG_RESERVED;
        settle();
        check(wide_fault, "reserved tag is not a wide value");
        wide_we = 1'b0;

        wide_we = 1'b1;
        wide_addr = 6'd60;
        wide_tag = MPY_TAG_SHORT_STR;
        wide_pay = {96'b0, 32'd4};
        settle();
        check(!wide_fault, "SHORT_STR at the last four entries fits");
        rs1_addr = 6'd63;
        tick();
        wide_we = 1'b0;
        check(rs1_tag == MPY_TAG_CONT, "last SHORT_STR entry is CONT");

        $display("MUT_COLLEC address clears the low 2 bits");
        begin
            logic [1:0] kind;
            logic [31:0] payload;
            logic [31:0] cleared;
            for (int k = 0; k < 4; k++) begin
                kind = 2'(k);
                payload = mpy_mut_payload(kind, MPY_GC_POOL_BASE);
                cleared = mpy_mut_addr(payload);
                write_rf(6'd2, mpy_make_mut(kind, MPY_GC_POOL_BASE));
                check(rs1_tag == MPY_TAG_MUT_COLLEC, "MUT_COLLEC tag");
                check(mpy_mut_kind(rs1_pay) == kind, "MUT_COLLEC kind");
                check(mpy_pointer_addr(rs1_tag, rs1_pay) == MPY_GC_POOL_BASE,
                      "MUT_COLLEC address");
                check(cleared[1:0] == 2'b00, "cleared address is aligned");
                $display("  MUT_COLLEC %-9s payload=0x%08h addr=0x%08h",
                         mut_name(kind), payload, cleared);
            end
        end

        $display("MEMORY read/write every tag as packed nibbles");
        begin
            logic [31:0] got_data;
            logic [3:0]  got_tag;
            logic [31:0] got_word;
            logic        got_fault;
            logic [3:0]  got_reason;
            logic [2:0]  got_region;
            int          ticks;
            logic [31:0] nibbles;
            for (int tag = 0; tag < MPY_TAG_SPACE; tag++) begin
                logic [31:0] slot_addr;
                logic [31:0] payload;
                slot_addr = MPY_GC_POOL_BASE + 32'(tag * 4);
                payload = 32'h2000_0000 | 32'(tag);
                bus(1'b1, 1'b1, slot_addr, payload, 4'(tag),
                    got_data, got_tag, got_word, got_fault, got_reason, got_region, ticks);
                check(!got_fault, "pool store faulted");
                check(ticks == (1 + MPY_SRAM_LATENCY), "SRAM store latency");
            end
            nibbles = 32'h0;
            for (int tag = 0; tag < MPY_TAGS_PER_WORD; tag++)
                nibbles = mpy_nibble_write(nibbles, 3'(tag), 4'(tag));
            check(nibbles == 32'h7654_3210, "nibble lane 0 is bits [3:0]");
            bus(1'b0, 1'b1, MPY_GC_POOL_BASE, 32'h0, 4'h0,
                got_data, got_tag, got_word, got_fault, got_reason, got_region, ticks);
            check(!got_fault && got_word == 32'h7654_3210, "first tag word is 0x76543210");
            check(got_tag == MPY_TAG_CONTROL, "pool slot 0 tag");
            $display("  pool tag_word[0]=0x%08h", got_word);
            bus(1'b0, 1'b1, MPY_GC_POOL_BASE + 32'd32, 32'h0, 4'h0,
                got_data, got_tag, got_word, got_fault, got_reason, got_region, ticks);
            check(got_word == 32'hFEDC_BA98, "second tag word is 0xFEDCBA98");
            check(got_tag == MPY_TAG_STR, "pool slot 8 tag");
            $display("  pool tag_word[1]=0x%08h", got_word);
            for (int tag = 0; tag < MPY_TAG_SPACE; tag++) begin
                bus(1'b0, 1'b1, MPY_GC_POOL_BASE + 32'(tag * 4), 32'h0, 4'h0,
                    got_data, got_tag, got_word, got_fault, got_reason, got_region, ticks);
                check(!got_fault, "pool load faulted");
                check(got_tag == 4'(tag), "memory tag mismatch");
                check(got_data == (32'h2000_0000 | 32'(tag)), "memory payload mismatch");
            end

            bus(1'b1, 1'b0, MPY_GC_POOL_BASE, 32'hABCD_0001, MPY_TAG_STR,
                got_data, got_tag, got_word, got_fault, got_reason, got_region, ticks);
            check(!got_fault, "untagged store faulted");
            bus(1'b0, 1'b1, MPY_GC_POOL_BASE, 32'h0, 4'h0,
                got_data, got_tag, got_word, got_fault, got_reason, got_region, ticks);
            check(got_data == 32'hABCD_0001, "untagged store wrote the word");
            check(got_tag == MPY_TAG_CONTROL, "untagged store left the nibble");
            $display("  tag_acc=0 left nibble %04b beside payload 0x%08h", got_tag, got_data);
        end

        $display("SPILL one frame as 32-bit words plus nibbles");
        for (int slot = 0; slot < MPY_RF_DEPTH; slot++)
            write_rf(MPY_RF_ADDR_W'(slot), spill_entry_at(slot));
        do_spill(32'h0000_0108, 16'd7, 1'b0);
        check(spill_frame == 5'd0, "first spill is frame 0");
        check(frame_depth == 6'd1, "depth is 1 after one spill");
        begin
            logic [31:0] got_data;
            logic [3:0]  got_tag;
            logic [31:0] got_word;
            logic        got_fault;
            logic [3:0]  got_reason;
            logic [2:0]  got_region;
            int          ticks;
            logic [31:0] expect_word;
            $display("  frame 0: 64 payload words, 8 packed tag words");
            for (int word = 0; word < (MPY_RF_DEPTH / MPY_TAGS_PER_WORD); word++) begin
                expect_word = 32'h0;
                for (int lane = 0; lane < MPY_TAGS_PER_WORD; lane++) begin
                    expect_word = mpy_nibble_write(
                        expect_word, 3'(lane), mpy_entry_tag(spill_entry_at(word * 8 + lane)));
                end
                bus(1'b0, 1'b0,
                    mpy_frame_base(5'd0) + 32'(MPY_FRAME_TAG_OFFSET) + 32'(word * 4),
                    32'h0, 4'h0,
                    got_data, got_tag, got_word, got_fault, got_reason, got_region, ticks);
                check(!got_fault, "tag-word load faulted");
                check(got_data == expect_word, "packed nibble word mismatch");
                $display("  SPILL tag_word[%0d]=0x%08h", word, got_data);
            end
            for (int slot = 0; slot < MPY_RF_DEPTH; slot++) begin
                logic [MPY_ENTRY_WIDTH-1:0] expect_entry;
                expect_entry = spill_entry_at(slot);
                bus(1'b0, 1'b1, mpy_frame_payload_addr(5'd0, 6'(slot)), 32'h0, 4'h0,
                    got_data, got_tag, got_word, got_fault, got_reason, got_region, ticks);
                check(!got_fault, "payload load faulted");
                check(got_data == mpy_entry_payload(expect_entry), "spilled payload mismatch");
                check(got_tag == mpy_entry_tag(expect_entry), "spilled tag mismatch");
                $display("  SPILL payload[%0d]=0x%08h tag=%04b %s",
                         slot, got_data, got_tag, tag_name(got_tag));
                if (mpy_entry_tag(expect_entry) == MPY_TAG_MUT_COLLEC) begin
                    $display("  MUT_COLLEC %-9s payload=0x%08h addr=0x%08h",
                             mut_name(mpy_mut_kind(got_data)), got_data,
                             mpy_pointer_addr(got_tag, got_data));
                    check(mpy_pointer_addr(got_tag, got_data) == MPY_GC_POOL_BASE,
                          "spilled MUT_COLLEC address");
                    check(mpy_pointer_addr(got_tag, got_data)[1:0] == 2'b00,
                          "spilled MUT_COLLEC low bits are clear");
                end
            end
            bus(1'b0, 1'b0, mpy_frame_header_addr(5'd0, 2'(MPY_FRAME_HDR_PC)),
                32'h0, 4'h0, got_data, got_tag, got_word, got_fault, got_reason, got_region, ticks);
            check(got_data == 32'h0000_0108, "spilled return PC");
            bus(1'b0, 1'b0, mpy_frame_header_addr(5'd0, 2'(MPY_FRAME_HDR_NSTATE)),
                32'h0, 4'h0, got_data, got_tag, got_word, got_fault, got_reason, got_region, ticks);
            check(got_data == 32'd7, "spilled n_state");
        end

        for (int frame = 1; frame < MPY_FRAME_DEPTH; frame++)
            do_spill(32'h0, 16'd0, 1'b0);
        check(frame_depth == 6'(MPY_FRAME_DEPTH), "stack holds 32 frames");
        $display("STACK depth=%0d next spill raises RuntimeError: maximum recursion depth exceeded",
                 frame_depth);
        do_spill(32'h0, 16'd0, 1'b1);
        check(frame_depth == 6'(MPY_FRAME_DEPTH), "rejected spill does not grow the stack");
        begin
            logic [31:0] got_data;
            logic [3:0]  got_tag;
            logic [31:0] got_word;
            logic        got_fault;
            logic [3:0]  got_reason;
            logic [2:0]  got_region;
            int          ticks;
            bus(1'b0, 1'b1, mpy_frame_payload_addr(5'd0, 6'd58), 32'h0, 4'h0,
                got_data, got_tag, got_word, got_fault, got_reason, got_region, ticks);
            check(got_tag == MPY_TAG_MUT_COLLEC, "frame 0 survived the full stack");
            check(mpy_mut_kind(got_data) == MPY_MUT_BYTEARRAY, "frame 0 bytearray kind");
            check(mpy_mut_addr(got_data) == MPY_GC_POOL_BASE, "frame 0 bytearray address");
            $display("  MUT_COLLEC bytearray payload=0x%08h addr=0x%08h",
                     got_data, mpy_mut_addr(got_data));
            bus(1'b0, 1'b1, mpy_frame_payload_addr(5'd31, 6'd0), 32'h0, 4'h0,
                got_data, got_tag, got_word, got_fault, got_reason, got_region, ticks);
            check(got_data == mpy_entry_payload(spill_entry_at(0)), "frame 31 payload");
            check(got_tag == MPY_TAG_CONTROL, "frame 31 tag");
        end

        $display("MAP faults");
        expect_fault(1'b0, 32'h2000_0001, MPY_FAULT_UNALIGNED, MPY_REGION_SRAM);
        expect_fault(1'b1, 32'h0000_0000, MPY_FAULT_FLASH_STORE, MPY_REGION_FLASH);
        expect_fault(1'b1, 32'h0000_0008, MPY_FAULT_FLASH_STORE, MPY_REGION_FLASH);
        expect_fault(1'b0, 32'h00F4_0000, MPY_FAULT_BUS, MPY_REGION_NONE);
        expect_fault(1'b0, 32'h0008_0000, MPY_FAULT_BUS, MPY_REGION_NONE);
        expect_fault(1'b0, 32'h2004_0000, MPY_FAULT_BUS, MPY_REGION_NONE);
        expect_ok(1'b0, 1'b0, 32'h0000_0000, 32'h0, 4'h0, 32'h0, 4'h0,
                  MPY_REGION_FLASH, 1 + MPY_SRAM_LATENCY + MPY_FLASH_WAIT_STATES);
        expect_ok(1'b0, 1'b0, 32'h0000_0004, 32'h0, 4'h0, 32'h0, 4'h0,
                  MPY_REGION_FLASH, 1 + MPY_SRAM_LATENCY + MPY_FLASH_WAIT_STATES);
        $display("  flash[0]=0 flash[4]=0 reserved, store faults, wait states=%0d",
                 MPY_FLASH_WAIT_STATES);
        expect_ok(1'b1, 1'b0, MPY_MMIO_BASE + MPY_MMIO_UART_TX, 32'h0000_0041, 4'h0,
                  32'h0, 4'h0, MPY_REGION_MMIO, 1 + MPY_SRAM_LATENCY);
        expect_ok(1'b0, 1'b0, MPY_MMIO_BASE + MPY_MMIO_UART_TX, 32'h0, 4'h0,
                  32'h0000_0041, 4'h0, MPY_REGION_MMIO, 1 + MPY_SRAM_LATENCY);
        expect_ok(1'b1, 1'b0, MPY_SIM_BASE, 32'h0000_0001, 4'h0,
                  32'h0, 4'h0, MPY_REGION_SIM, 1 + MPY_SRAM_LATENCY);
        expect_ok(1'b0, 1'b0, MPY_SIM_BASE, 32'h0, 4'h0,
                  32'h0000_0001, 4'h0, MPY_REGION_SIM, 1 + MPY_SRAM_LATENCY);
        expect_ok(1'b1, 1'b1, MPY_SRAM_BASE + MPY_SRAM_BYTES - 32'd4, 32'h5A5A_5A5A,
                  MPY_TAG_INT, 32'h0, 4'h0, MPY_REGION_SRAM, 1 + MPY_SRAM_LATENCY);
        expect_ok(1'b0, 1'b1, MPY_SRAM_BASE + MPY_SRAM_BYTES - 32'd4, 32'h0, 4'h0,
                  32'h5A5A_5A5A, MPY_TAG_INT, MPY_REGION_SRAM, 1 + MPY_SRAM_LATENCY);

        $display("MPY value encoding: ok");
        $finish;
    end
endmodule
