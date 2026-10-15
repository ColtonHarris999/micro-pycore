// Growth checks for mpy_container.
//
// 1. A list append that needs room allocates a new item array. The list
//    object address does not change. Capacity sits in front of item 0.
// 2. A dict of ints, with a tombstone and no types table, resizes on the
//    py/map.c size table. Ints hash to themselves. The object stays put
//    and bit 31 stays clear.
// 3. A dict whose type header tp_hash is a function resizes with a
//    precomputed slot-number dict. The accelerator uses that hash and
//    does not call the function. A second object whose tp_hash is empty
//    CONTROL is hashed by address. An int in the same dict is hashed here.

`timescale 1ns/1ps

module tb_mpy_container;
    localparam logic [3:0] TAG_CONTROL = 4'b0000;
    localparam logic [3:0] TAG_INT     = 4'b0001;
    localparam logic [3:0] TAG_FLOAT   = 4'b0011;
    localparam logic [3:0] TAG_QSTR    = 4'b0110;
    localparam logic [3:0] TAG_STR     = 4'b1000;
    localparam logic [3:0] TAG_TUPLE   = 4'b1001;
    localparam logic [3:0] TAG_BYTES   = 4'b1101;
    localparam logic [3:0] TAG_OBJECT  = 4'b1110;

    localparam logic [3:0] CTL_EMPTY = 4'd0;
    localparam logic [3:0] CTL_NONE  = 4'd1;
    localparam logic [3:0] CTL_TOMB  = 4'd3;
    localparam logic [3:0] CTL_FALSE = 4'd4;
    localparam logic [3:0] CTL_TRUE  = 4'd5;

    localparam logic [1:0] KIND_LIST = 2'd0;
    localparam logic [1:0] KIND_DICT = 2'd1;
    localparam logic [1:0] KIND_SET  = 2'd2;
    localparam logic [1:0] KIND_BA   = 2'd3;

    localparam logic [6:0] OP_L_APPEND = 7'd1;
    localparam logic [6:0] OP_D_RESIZE = 7'd2;
    localparam logic [6:0] OP_S_RESIZE = 7'd3;
    localparam logic [6:0] OP_B_GROW   = 7'd4;

    logic        clk;
    logic        rst_n;
    logic        cmd_valid;
    logic        cmd_ready;
    logic [6:0]  cmd_op;
    logic [31:0] cmd_obj;
    logic [31:0] cmd_b;
    logic [3:0]  cmd_btag;
    logic [31:0] cmd_heap;
    logic [31:0] cmd_hlim;
    logic [31:0] qstr_base;

    logic        dr_valid, dr_ready, dr_ok, dr_short, dr_fault;
    logic [31:0] dr_heap, dr_need;
    logic        cr_valid, idle;

    logic        req, we, ack, fault;
    logic [31:0] addr, wdata, rdata;
    logic [3:0]  wtag, rtag;

    logic [31:0] mem_d [logic [31:0]];
    logic [3:0]  mem_t [logic [31:0]];
    logic [31:0] rlog [$];
    int          writes;
    int          errors;
    int          cycles;

    logic        got_ok, got_short, got_fault;
    logic [31:0] got_heap, got_need;

    mpy_container dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .cmd_valid_i(cmd_valid),
        .cmd_ready_o(cmd_ready),
        .cmd_op_i(cmd_op),
        .cmd_obj_i(cmd_obj),
        .cmd_b_i(cmd_b),
        .cmd_b_tag_i(cmd_btag),
        .cmd_heap_ptr_i(cmd_heap),
        .cmd_heap_limit_i(cmd_hlim),
        .qstr_hash_base_i(qstr_base),
        .dr_valid_o(dr_valid),
        .dr_ready_i(dr_ready),
        .dr_ok_o(dr_ok),
        .dr_short_o(dr_short),
        .dr_fault_o(dr_fault),
        .dr_heap_o(dr_heap),
        .dr_need_o(dr_need),
        .cr_valid_o(cr_valid),
        .idle_o(idle),
        .req_o(req),
        .we_o(we),
        .addr_o(addr),
        .wdata_o(wdata),
        .wtag_o(wtag),
        .ack_i(ack),
        .fault_i(fault),
        .rdata_i(rdata),
        .rtag_i(rtag)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (rst_n)
            cycles <= cycles + 1;
        if (cycles > 200000) begin
            $display("FAIL timeout");
            $fatal(1);
        end
    end

    function automatic bit bad_addr(input logic [31:0] a);
        if (a == 32'd0)
            return 1'b1;
        if (a[31:16] == 16'hDEAD)
            return 1'b1;
        if ((a >= 32'h0000_1800) && (a < 32'h0000_1900))
            return 1'b1;
        if ((a >= 32'h0000_5000) && (a < 32'h0000_5100))
            return 1'b1;
        return 1'b0;
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ack   <= 1'b0;
            fault <= 1'b0;
            rdata <= 32'd0;
            rtag  <= 4'd0;
        end else begin
            ack   <= 1'b0;
            fault <= 1'b0;
            if (req) begin
                ack <= 1'b1;
                if (bad_addr(addr) || (addr[1:0] != 2'b00)) begin
                    fault <= 1'b1;
                    rdata <= 32'd0;
                    rtag  <= 4'd0;
                end else if (we) begin
                    mem_d[addr] <= wdata;
                    mem_t[addr] <= wtag;
                    writes      <= writes + 1;
                end else begin
                    rlog.push_back(addr);
                    if (mem_d.exists(addr) != 0) begin
                        rdata <= mem_d[addr];
                        rtag  <= mem_t[addr];
                    end else begin
                        rdata <= 32'd0;
                        rtag  <= TAG_CONTROL;
                    end
                end
            end
        end
    end

    task automatic wr(input logic [31:0] a, input logic [3:0] t, input logic [31:0] d);
        mem_d[a] = d;
        mem_t[a] = t;
    endtask

    function automatic logic [31:0] rd(input logic [31:0] a);
        if (mem_d.exists(a) != 0)
            rd = mem_d[a];
        else
            rd = 32'hXXXX_XXXX;
    endfunction

    function automatic logic [3:0] rtag_of(input logic [31:0] a);
        if (mem_t.exists(a) != 0)
            rtag_of = mem_t[a];
        else
            rtag_of = 4'hX;
    endfunction

    function automatic bit saw(input logic [31:0] a);
        foreach (rlog[i]) begin
            if (rlog[i] == a)
                return 1'b1;
        end
        return 1'b0;
    endfunction

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            errors = errors + 1;
            $display("FAIL %s (phase %s)", msg, dut.err_phase_r.name());
        end
    endtask

    task automatic run_cmd(
        input logic [6:0]  op,
        input logic [31:0] obj,
        input logic [31:0] b,
        input logic [3:0]  btag,
        input logic [31:0] heap,
        input logic [31:0] hlim
    );
        int guard;
        while (!cmd_ready) @(posedge clk);
        @(negedge clk);
        cmd_op    = op;
        cmd_obj   = obj;
        cmd_b     = b;
        cmd_btag  = btag;
        cmd_heap  = heap;
        cmd_hlim  = hlim;
        cmd_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        cmd_valid = 1'b0;
        guard = 0;
        while (!dr_valid) begin
            @(posedge clk);
            guard = guard + 1;
            if (guard > 100000) begin
                $display("FAIL timeout op %0d phase %s", op, dut.phase_r.name());
                $fatal(1);
            end
        end
        got_ok    = dr_ok;
        got_short = dr_short;
        got_fault = dr_fault;
        got_heap  = dr_heap;
        got_need  = dr_need;
        check(cr_valid == dr_ok, "container-ready tracks a successful result");
        @(negedge clk);
        dr_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        dr_ready = 1'b0;
    endtask

    task automatic expect_ok(input logic [31:0] heap_end, input string msg);
        check(got_ok && !got_short && !got_fault, msg);
        check(got_heap == heap_end, {msg, " heap"});
    endtask

    logic [31:0] scratch;
    logic [31:0] heap_bump;

    task automatic one_key(
        input logic [3:0]  tag,
        input logic [31:0] val,
        input logic [31:0] expect_hash,
        input string       name
    );
        logic [31:0] dict, tbl, slot, neu;
        int s;
        dict  = scratch;
        tbl = scratch + 32'd32;
        scratch = scratch + 32'd64;
        neu = heap_bump;
        heap_bump = heap_bump + 32'd32;
        wr(dict,        TAG_CONTROL, 32'd1);
        wr(dict + 4,    TAG_CONTROL, 32'd2);
        wr(dict + 8,    TAG_CONTROL, tbl);
        wr(dict + 12,   TAG_CONTROL, 32'd0);
        wr(dict + 16,   TAG_CONTROL, 32'hCAFE_CAFE);
        wr(tbl,       tag,         val);
        wr(tbl + 4,   TAG_INT,     32'd42);
        wr(tbl + 8,   TAG_CONTROL, 32'd0);
        wr(tbl + 12,  TAG_CONTROL, 32'd0);
        rlog.delete();
        run_cmd(OP_D_RESIZE, dict | KIND_DICT, 32'd0, TAG_CONTROL, neu, neu + 32'd64);
        expect_ok(neu + 32'd32, name);
        check(rd(dict) == 32'd1, {name, " used"});
        check(rd(dict + 4) == 32'd4, {name, " alloc"});
        check(rd(dict + 8) == neu, {name, " table"});
        check(rd(dict + 12) == 32'd0, {name, " types"});
        check(rd(dict + 16) == 32'hCAFE_CAFE, {name, " sentinel"});
        slot = expect_hash % 32'd4;
        for (s = 0; s < 4; s = s + 1) begin
            if (s == slot) begin
                check(rtag_of(neu + (s * 8)) == tag, {name, " key tag"});
                check(rd(neu + (s * 8)) == val, {name, " key"});
                check(rtag_of(neu + (s * 8) + 4) == TAG_INT, {name, " val tag"});
                check(rd(neu + (s * 8) + 4) == 32'd42, {name, " val"});
            end else begin
                check(rtag_of(neu + (s * 8)) == TAG_CONTROL, {name, " empty tag"});
                check(rd(neu + (s * 8)) == 32'd0, {name, " empty"});
            end
        end
    endtask

    initial begin
        errors    = 0;
        cycles    = 0;
        writes    = 0;
        cmd_valid = 1'b0;
        dr_ready  = 1'b0;
        qstr_base = 32'd0;
        cmd_op    = '0;
        cmd_obj   = '0;
        cmd_b     = '0;
        cmd_btag  = '0;
        cmd_heap  = '0;
        cmd_hlim  = '0;
        rst_n     = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        test_list();
        test_dict_ints();
        test_dict_custom();
        test_set();
        test_bytearray();
        test_hashes();
        test_unhashable();

        if (errors == 0) begin
            $display("PASS mpy_container growth");
            $finish;
        end else begin
            $display("FAIL %0d checks", errors);
            $fatal(1);
        end
    end

    task automatic test_list();
        int w0;
        logic [31:0] list_at;
        list_at = 32'h0000_1000;

        // len 3, cap 4. Item 0 is at 0x1104. Capacity is the word before it.
        wr(list_at,      TAG_CONTROL, 32'd3);
        wr(list_at + 4,  TAG_CONTROL, 32'h0000_1104);
        wr(list_at + 8,  TAG_CONTROL, 32'hCAFE_CAFE);
        wr(32'h0000_1100, TAG_CONTROL, 32'd4);
        wr(32'h0000_1104, TAG_INT, 32'd10);
        wr(32'h0000_1108, TAG_INT, 32'd11);
        wr(32'h0000_110C, TAG_INT, 32'd12);

        run_cmd(OP_L_APPEND, list_at | KIND_LIST, 32'd13, TAG_INT,
                32'h0000_3000, 32'h0000_4000);
        expect_ok(32'h0000_3000, "list in-place append");
        check(rd(list_at) == 32'd4, "in-place length");
        check(rd(list_at + 4) == 32'h0000_1104, "in-place pointer stays");
        check(rd(list_at + 8) == 32'hCAFE_CAFE, "list sentinel after in-place");
        check(rd(32'h0000_1110) == 32'd13, "in-place new item");
        check(rtag_of(32'h0000_1110) == TAG_INT, "in-place new tag");

        w0 = writes;
        run_cmd(OP_L_APPEND, list_at | KIND_LIST, 32'd14, TAG_INT,
                32'h0000_3000, 32'h0000_3004);
        check(got_short && !got_ok && !got_fault, "list short heap");
        check(got_need == 32'd36, "list short need");
        check(writes == w0, "short heap writes nothing");
        check(rd(list_at) == 32'd4, "short leaves length");
        check(rd(list_at + 4) == 32'h0000_1104, "short leaves pointer");

        run_cmd(OP_L_APPEND, list_at | KIND_LIST, 32'd14, TAG_INT,
                32'h0000_3000, 32'h0000_4000);
        expect_ok(32'h0000_3024, "list grow");
        check(rd(list_at) == 32'd5, "grown length");
        check(rtag_of(list_at) == TAG_CONTROL, "length tag");
        check(rd(list_at + 4) == 32'h0000_3004, "item array moved");
        check(rtag_of(list_at + 4) == TAG_CONTROL, "pointer tag");
        check(rd(list_at + 8) == 32'hCAFE_CAFE, "list object did not grow a header word");
        check(rd(32'h0000_3000) == 32'd8, "new capacity");
        check(rd(32'h0000_3004) == 32'd10, "copied 0");
        check(rd(32'h0000_3008) == 32'd11, "copied 1");
        check(rd(32'h0000_300C) == 32'd12, "copied 2");
        check(rd(32'h0000_3010) == 32'd13, "copied 3");
        check(rd(32'h0000_3014) == 32'd14, "appended");
        check(rtag_of(32'h0000_3014) == TAG_INT, "appended tag");
        check(rd(32'h0000_3018) == 32'd0, "spare 0");
        check(rd(32'h0000_301C) == 32'd0, "spare 1");
        check(rd(32'h0000_3020) == 32'd0, "spare 2");

        // Empty list: minimum allocation is 4, object stays at 0x1200.
        wr(32'h0000_1200,     TAG_CONTROL, 32'd0);
        wr(32'h0000_1204,     TAG_CONTROL, 32'd0);
        wr(32'h0000_1208,     TAG_CONTROL, 32'hCAFE_CAFE);
        run_cmd(OP_L_APPEND, 32'h0000_1200 | KIND_LIST, 32'd7, TAG_INT,
                32'h0000_3100, 32'h0000_4000);
        expect_ok(32'h0000_3114, "empty list grow");
        check(rd(32'h0000_1200) == 32'd1, "empty length");
        check(rd(32'h0000_1204) == 32'h0000_3104, "empty items");
        check(rd(32'h0000_1208) == 32'hCAFE_CAFE, "empty sentinel");
        check(rd(32'h0000_3100) == 32'd4, "min cap 4");
        check(rd(32'h0000_3104) == 32'd7, "first item");

        w0 = writes;
        run_cmd(OP_L_APPEND, 32'h0000_4001, 32'd1, TAG_INT,
                32'h0000_3200, 32'h0000_4000);
        check(got_fault && !got_ok, "list op rejects a dict pointer");
        check(writes == w0, "kind fault writes nothing");
        $display("ok list");
    endtask

    task automatic test_dict_ints();
        logic [31:0] dict, tbl, neu;
        dict  = 32'h0000_4000;
        tbl = 32'h0000_4100;
        neu   = 32'h0000_6000;
        wr(dict,      TAG_CONTROL, 32'd2);
        wr(dict + 4,  TAG_CONTROL, 32'd4);
        wr(dict + 8,  TAG_CONTROL, tbl);
        wr(dict + 12, TAG_CONTROL, 32'd0);
        wr(dict + 16, TAG_CONTROL, 32'hCAFE_CAFE);
        wr(tbl,      TAG_INT,     32'd1);
        wr(tbl + 4,  TAG_INT,     32'd10);
        wr(tbl + 8,  TAG_CONTROL, {28'd0, CTL_TOMB});
        wr(tbl + 12, TAG_INT,     32'd99);
        wr(tbl + 16, TAG_INT,     32'd3);
        wr(tbl + 20, TAG_INT,     32'd30);
        wr(tbl + 24, TAG_CONTROL, 32'd0);
        wr(tbl + 28, TAG_CONTROL, 32'd0);

        rlog.delete();
        run_cmd(OP_D_RESIZE, dict | KIND_DICT, 32'd0, TAG_CONTROL, neu, neu + 32'd128);
        expect_ok(neu + 32'd48, "dict ints");
        check(rd(dict) == 32'd2, "dict used, indicator clear");
        check(rd(dict + 4) == 32'd6, "dict alloc 6");
        check(rd(dict + 8) == neu, "dict table moved");
        check(rd(dict + 12) == 32'd0, "no types table");
        check(rd(dict + 16) == 32'hCAFE_CAFE, "dict object stayed two-plus-two words");
        check(!saw(32'h0000_5000), "int dict does not walk a types table");
        // 1 % 6 = 1, 3 % 6 = 3. Tombstone dropped.
        check(rd(neu + 8) == 32'd1 && rd(neu + 12) == 32'd10, "int 1 at slot 1");
        check(rtag_of(neu + 8) == TAG_INT, "int 1 tag");
        check(rd(neu + 24) == 32'd3 && rd(neu + 28) == 32'd30, "int 3 at slot 3");
        check(rd(neu + 0) == 32'd0, "slot 0 empty");
        check(rd(neu + 16) == 32'd0, "slot 2 empty");
        check(rd(neu + 32) == 32'd0, "slot 4 empty");
        check(rd(neu + 40) == 32'd0, "slot 5 empty");
        check(rd(tbl + 8) == {28'd0, CTL_TOMB}, "old tombstone left behind");
        $display("ok dict ints");
    endtask

    task automatic test_dict_custom();
        logic [31:0] dict, tbl, ch, cht, neu;
        // Types. tp_hash is word 5. tp_dict is a poison pointer.
        wr(32'h0000_2400, TAG_CONTROL, 32'd2);
        wr(32'h0000_2404, TAG_CONTROL, 32'd0);
        wr(32'h0000_2408, TAG_CONTROL, 32'hDEAD_0000);
        wr(32'h0000_240C, TAG_CONTROL, 32'd0);
        wr(32'h0000_2410, TAG_CONTROL, 32'd0);
        wr(32'h0000_2414, TAG_OBJECT,  32'h0000_1800);

        wr(32'h0000_2480, TAG_CONTROL, 32'd2);
        wr(32'h0000_2484, TAG_CONTROL, 32'd0);
        wr(32'h0000_2488, TAG_CONTROL, 32'hDEAD_0004);
        wr(32'h0000_248C, TAG_CONTROL, 32'd0);
        wr(32'h0000_2490, TAG_CONTROL, 32'd0);
        wr(32'h0000_2494, TAG_CONTROL, {28'd0, CTL_EMPTY});

        wr(32'h0000_2000, TAG_CONTROL, 32'd1);
        wr(32'h0000_2004, TAG_OBJECT,  32'h0000_2400);
        wr(32'h0000_2104, TAG_CONTROL, 32'd1);
        wr(32'h0000_2108, TAG_OBJECT,  32'h0000_2480);

        dict  = 32'h0000_4200;
        tbl = 32'h0000_4300;
        ch    = 32'h0000_8000;
        cht   = 32'h0000_8100;
        neu   = 32'h0000_6100;

        wr(dict,      TAG_CONTROL, 32'h8000_0003);
        wr(dict + 4,  TAG_CONTROL, 32'd4);
        wr(dict + 8,  TAG_CONTROL, tbl);
        wr(dict + 12, TAG_CONTROL, 32'h0000_5000);
        wr(dict + 16, TAG_CONTROL, 32'hCAFE_CAFE);
        // slot 0 custom object, slot 1 default object, slot 2 int 3
        wr(tbl,      TAG_OBJECT, 32'h0000_2000);
        wr(tbl + 4,  TAG_INT,    32'd70);
        wr(tbl + 8,  TAG_OBJECT, 32'h0000_2104);
        wr(tbl + 12, TAG_INT,    32'd71);
        wr(tbl + 16, TAG_INT,    32'd3);
        wr(tbl + 20, TAG_INT,    32'd72);
        wr(tbl + 24, TAG_CONTROL, 32'd0);
        wr(tbl + 28, TAG_CONTROL, 32'd0);

        // Slot-number dict: key 0 -> hash 11. Indicator stays clear.
        wr(ch,      TAG_CONTROL, 32'd1);
        wr(ch + 4,  TAG_CONTROL, 32'd2);
        wr(ch + 8,  TAG_CONTROL, cht);
        wr(ch + 12, TAG_CONTROL, 32'd0);
        wr(cht,      TAG_INT, 32'd0);
        wr(cht + 4,  TAG_INT, 32'd11);
        wr(cht + 8,  TAG_CONTROL, 32'd0);
        wr(cht + 12, TAG_CONTROL, 32'd0);

        rlog.delete();
        run_cmd(OP_D_RESIZE, dict | KIND_DICT, ch | KIND_DICT, TAG_CONTROL,
                neu, neu + 32'd128);
        expect_ok(neu + 32'd48, "custom dict");
        check(rd(dict) == 32'h8000_0003, "indicator stays set, used 3");
        check(rd(dict + 4) == 32'd6, "custom alloc");
        check(rd(dict + 8) == neu, "custom table");
        check(rd(dict + 12) == 32'h0000_5000, "types pointer preserved");
        check(rd(dict + 16) == 32'hCAFE_CAFE, "custom sentinel");
        // 11 % 6 = 5, address 0x2104 % 6 = 4, int 3 % 6 = 3.
        check(rd(neu + 40) == 32'h0000_2000, "custom key used precomputed hash");
        check(rtag_of(neu + 40) == TAG_OBJECT, "custom key tag");
        check(rd(neu + 44) == 32'd70, "custom value");
        check(rd(neu + 32) == 32'h0000_2104, "default object hashed by address");
        check(rd(neu + 36) == 32'd71, "default value");
        check(rd(neu + 24) == 32'd3 && rd(neu + 28) == 32'd72, "int hashed here");
        check(rd(neu + 16) == 32'd0, "address slot left empty");
        check(saw(32'h0000_2494), "read default tp_hash on the type header");
        check(!saw(32'h0000_1800), "did not call the custom function");
        check(!saw(32'hDEAD_0000), "did not look up __hash__ in tp_dict");
        check(!saw(32'hDEAD_0004), "did not walk the default tp_dict");
        check(!saw(32'h0000_5000), "did not walk the types table");
        check(rd(ch) == 32'd1 && rd(ch + 8) == cht, "computed-hash dict unchanged");
        $display("ok dict custom");
    endtask

    task automatic test_set();
        logic [31:0] obj, tbl, neu, ch;
        obj   = 32'h0000_4400;
        tbl = 32'h0000_4500;
        neu   = 32'h0000_6200;
        wr(obj,      TAG_CONTROL, 32'd2);
        wr(obj + 4,  TAG_CONTROL, 32'd4);
        wr(obj + 8,  TAG_CONTROL, tbl);
        wr(obj + 12, TAG_CONTROL, 32'd0);
        wr(obj + 16, TAG_CONTROL, 32'hCAFE_CAFE);
        wr(tbl,      TAG_INT, 32'd1);
        wr(tbl + 4,  TAG_CONTROL, {28'd0, CTL_TOMB});
        wr(tbl + 8,  TAG_INT, 32'd3);
        wr(tbl + 12, TAG_CONTROL, 32'd0);
        run_cmd(OP_S_RESIZE, obj | KIND_SET, 32'd0, TAG_CONTROL, neu, neu + 32'd64);
        expect_ok(neu + 32'd24, "set ints");
        check(rd(obj) == 32'd2, "set used");
        check(rd(obj + 4) == 32'd6, "set alloc");
        check(rd(obj + 8) == neu, "set table");
        check(rd(obj + 12) == 32'd0, "set types");
        check(rd(obj + 16) == 32'hCAFE_CAFE, "set sentinel");
        check(rd(neu + 4) == 32'd1, "set int 1");
        check(rd(neu + 12) == 32'd3, "set int 3");
        check(rd(neu + 0) == 32'd0 && rd(neu + 8) == 32'd0, "set holes");

        // Same precomputed dict: slot 0 -> 11. New alloc 4, 11 % 4 = 3.
        ch = 32'h0000_8000;
        obj   = 32'h0000_4600;
        tbl = 32'h0000_4700;
        neu   = 32'h0000_6300;
        wr(obj,      TAG_CONTROL, 32'h8000_0001);
        wr(obj + 4,  TAG_CONTROL, 32'd2);
        wr(obj + 8,  TAG_CONTROL, tbl);
        wr(obj + 12, TAG_CONTROL, 32'h0000_5000);
        wr(obj + 16, TAG_CONTROL, 32'hCAFE_CAFE);
        wr(tbl,     TAG_OBJECT, 32'h0000_2000);
        wr(tbl + 4, TAG_CONTROL, 32'd0);
        rlog.delete();
        run_cmd(OP_S_RESIZE, obj | KIND_SET, ch | KIND_DICT, TAG_CONTROL,
                neu, neu + 32'd64);
        expect_ok(neu + 32'd16, "set custom");
        check(rd(obj) == 32'h8000_0001, "set indicator");
        check(rd(obj + 4) == 32'd4, "set custom alloc");
        check(rd(obj + 12) == 32'h0000_5000, "set types preserved");
        check(rd(neu + 12) == 32'h0000_2000, "set used precomputed hash");
        check(rd(neu + 0) == 32'd0, "set did not use the address hash");
        check(!saw(32'h0000_1800), "set did not call __hash__");
        $display("ok set");
    endtask

    task automatic test_bytearray();
        logic [31:0] obj;
        obj = 32'h0000_4800;
        wr(obj,      TAG_CONTROL, 32'd3);
        wr(obj + 4,  TAG_CONTROL, 32'd16);
        wr(obj + 8,  TAG_CONTROL, 32'h0000_4900);
        wr(obj + 12, TAG_CONTROL, 32'hCAFE_CAFE);
        wr(32'h0000_4900, TAG_CONTROL, 32'h0033_2211);
        run_cmd(OP_B_GROW, obj | KIND_BA, 32'd0, TAG_CONTROL,
                32'h0000_6400, 32'h0000_7000);
        expect_ok(32'h0000_6400, "bytearray spare");
        check(rd(obj + 8) == 32'h0000_4900, "spare buffer stays");
        check(rd(obj + 4) == 32'd16, "spare capacity stays");

        wr(obj + 4, TAG_CONTROL, 32'd3);
        run_cmd(OP_B_GROW, obj | KIND_BA, 32'd0, TAG_CONTROL,
                32'h0000_6400, 32'h0000_7000);
        expect_ok(32'h0000_640C, "bytearray grow");
        check(rd(obj) == 32'd3, "bytearray length");
        check(rd(obj + 4) == 32'd11, "bytearray capacity +8");
        check(rd(obj + 8) == 32'h0000_6400, "bytearray buffer moved");
        check(rd(obj + 12) == 32'hCAFE_CAFE, "bytearray sentinel");
        check(rd(32'h0000_6400) == 32'h0033_2211, "bytearray bytes copied");
        check(rd(32'h0000_6404) == 32'd0, "bytearray pad 0");
        check(rd(32'h0000_6408) == 32'd0, "bytearray pad 1");
        $display("ok bytearray");
    endtask

    task automatic test_hashes();
        scratch   = 32'h0000_A000;
        heap_bump = 32'h0000_B000;

        one_key(TAG_CONTROL, {28'd0, CTL_NONE}, 32'd6, "none");
        one_key(TAG_CONTROL, {28'd0, CTL_FALSE}, 32'd0, "false");
        one_key(TAG_CONTROL, {28'd0, CTL_TRUE}, 32'd1, "true");
        one_key(TAG_INT, 32'hFFFF_FFFF, 32'hFFFF_FFFF, "int -1");
        one_key(TAG_FLOAT, 32'h406C_CCCD, 32'd3, "float 3.7");
        one_key(TAG_FLOAT, 32'hBFC0_0000, 32'hFFFF_FFFF, "float -1.5");

        wr(32'h0000_9000, TAG_CONTROL, 32'd2);
        wr(32'h0000_9004, TAG_INT, 32'd8);
        wr(32'h0000_9008, TAG_INT, 32'd9);
        one_key(TAG_TUPLE, 32'h0000_9000, 32'd17, "tuple");

        wr(32'h0000_9020, TAG_CONTROL, 32'd1);
        wr(32'h0000_9024, TAG_TUPLE, 32'h0000_9040);
        wr(32'h0000_9040, TAG_CONTROL, 32'd1);
        wr(32'h0000_9044, TAG_INT, 32'd8);
        one_key(TAG_TUPLE, 32'h0000_9020, 32'd8, "nested tuple");

        wr(32'h0000_9100, TAG_CONTROL, 32'd1);
        wr(32'h0000_9104, TAG_CONTROL, 32'h0000_9110);
        wr(32'h0000_9110, TAG_CONTROL, 32'h0000_0041);
        one_key(TAG_BYTES, 32'h0000_9100, 32'd46564, "bytes A");

        wr(32'h0000_9200, TAG_CONTROL, 32'd1);
        wr(32'h0000_9204, TAG_CONTROL, 32'd7);
        wr(32'h0000_9208, TAG_CONTROL, 32'hDEAD_1000);
        one_key(TAG_STR, 32'h0000_9200, 32'd7, "str stored");
        check(!saw(32'hDEAD_1000), "stored string hash skips the bytes");

        wr(32'h0000_9220, TAG_CONTROL, 32'd1);
        wr(32'h0000_9224, TAG_CONTROL, 32'd0);
        wr(32'h0000_9228, TAG_CONTROL, 32'h0000_9230);
        wr(32'h0000_9230, TAG_CONTROL, 32'h0000_0041);
        one_key(TAG_STR, 32'h0000_9220, 32'd46564, "str lazy");
        check(rd(32'h0000_9224) == 32'd46564, "lazy hash written back");

        wr(32'h0000_770C, TAG_CONTROL, 32'd99);
        qstr_base = 32'h0000_7700;
        one_key(TAG_QSTR, 32'd3, 32'd99, "qstr");
        qstr_base = 32'd0;

        // Tuple of the default-hash instance. Seed 0 + address 0x2104.
        wr(32'h0000_9300, TAG_CONTROL, 32'd1);
        wr(32'h0000_9304, TAG_OBJECT, 32'h0000_2104);
        one_key(TAG_TUPLE, 32'h0000_9300, 32'h0000_2104, "tuple of object");

        // Mixed dict, alloc 8 -> 10, so the probe order is checked too.
        begin
            logic [31:0] dict, tbl, neu;
            dict  = 32'h0000_A800;
            tbl = 32'h0000_A840;
            neu   = 32'h0000_C000;
            wr(dict,      TAG_CONTROL, 32'd8);
            wr(dict + 4,  TAG_CONTROL, 32'd8);
            wr(dict + 8,  TAG_CONTROL, tbl);
            wr(dict + 12, TAG_CONTROL, 32'd0);
            wr(dict + 16, TAG_CONTROL, 32'hCAFE_CAFE);
            wr(tbl + 0,  TAG_INT,     32'hFFFF_FFFF);
            wr(tbl + 4,  TAG_INT,     32'd0);
            wr(tbl + 8,  TAG_CONTROL, {28'd0, CTL_NONE});
            wr(tbl + 12, TAG_INT,     32'd1);
            wr(tbl + 16, TAG_CONTROL, {28'd0, CTL_FALSE});
            wr(tbl + 20, TAG_INT,     32'd2);
            wr(tbl + 24, TAG_CONTROL, {28'd0, CTL_TRUE});
            wr(tbl + 28, TAG_INT,     32'd3);
            wr(tbl + 32, TAG_FLOAT,   32'h406C_CCCD);
            wr(tbl + 36, TAG_INT,     32'd4);
            wr(tbl + 40, TAG_TUPLE,   32'h0000_9000);
            wr(tbl + 44, TAG_INT,     32'd5);
            wr(tbl + 48, TAG_BYTES,   32'h0000_9100);
            wr(tbl + 52, TAG_INT,     32'd6);
            wr(tbl + 56, TAG_STR,     32'h0000_9200);
            wr(tbl + 60, TAG_INT,     32'd7);
            run_cmd(OP_D_RESIZE, dict | KIND_DICT, 32'd0, TAG_CONTROL,
                    neu, neu + 32'd256);
            expect_ok(neu + 32'd80, "mixed rehash");
            check(rd(dict + 4) == 32'd10, "mixed alloc 10");
            check(rd(neu + 0)  == {28'd0, CTL_FALSE}, "slot0 false");
            check(rd(neu + 8)  == {28'd0, CTL_TRUE}, "slot1 true");
            check(rd(neu + 16) == 32'd0, "slot2 empty");
            check(rtag_of(neu + 24) == TAG_FLOAT, "slot3 float");
            check(rd(neu + 32) == 32'h0000_9100, "slot4 bytes");
            check(rd(neu + 40) == 32'hFFFF_FFFF, "slot5 -1");
            check(rd(neu + 48) == {28'd0, CTL_NONE}, "slot6 none");
            check(rd(neu + 56) == 32'h0000_9000, "slot7 tuple");
            check(rd(neu + 64) == 32'h0000_9200, "slot8 str");
            check(rd(neu + 72) == 32'd0, "slot9 empty");
            check(rd(neu + 4)  == 32'd2, "false value follows its key");
        end
        $display("ok hashes");
    endtask

    task automatic test_unhashable();
        logic [31:0] dict, tbl, ch, cht;
        int w0;
        wr(32'h0000_2500, TAG_CONTROL, 32'd2);
        wr(32'h0000_2504, TAG_CONTROL, 32'd0);
        wr(32'h0000_2508, TAG_CONTROL, 32'hDEAD_0008);
        wr(32'h0000_250C, TAG_CONTROL, 32'd0);
        wr(32'h0000_2510, TAG_CONTROL, 32'd0);
        wr(32'h0000_2514, TAG_CONTROL, {28'd0, CTL_NONE});
        wr(32'h0000_2200, TAG_CONTROL, 32'd1);
        wr(32'h0000_2204, TAG_OBJECT,  32'h0000_2500);

        dict  = 32'h0000_4A00;
        tbl = 32'h0000_4B00;
        wr(dict,      TAG_CONTROL, 32'h8000_0001);
        wr(dict + 4,  TAG_CONTROL, 32'd2);
        wr(dict + 8,  TAG_CONTROL, tbl);
        wr(dict + 12, TAG_CONTROL, 32'd0);
        wr(tbl,     TAG_OBJECT, 32'h0000_2200);
        wr(tbl + 4, TAG_INT,    32'd1);
        wr(tbl + 8, TAG_CONTROL, 32'd0);
        wr(tbl + 12, TAG_CONTROL, 32'd0);
        w0 = writes;
        rlog.delete();
        run_cmd(OP_D_RESIZE, dict | KIND_DICT, 32'd0, TAG_CONTROL,
                32'h0000_6600, 32'h0000_7000);
        check(got_fault && !got_ok, "unhashable tp_hash None faults");
        check(rd(dict + 8) == tbl, "unhashable leaves the table pointer");
        check(!saw(32'hDEAD_0008), "unhashable does not search tp_dict");

        // Function tp_hash, computed-hash dict has no slot 0 entry.
        ch  = 32'h0000_8200;
        cht = 32'h0000_8300;
        wr(ch,      TAG_CONTROL, 32'd0);
        wr(ch + 4,  TAG_CONTROL, 32'd2);
        wr(ch + 8,  TAG_CONTROL, cht);
        wr(ch + 12, TAG_CONTROL, 32'd0);
        wr(cht,      TAG_CONTROL, 32'd0);
        wr(cht + 4,  TAG_CONTROL, 32'd0);
        wr(cht + 8,  TAG_CONTROL, 32'd0);
        wr(cht + 12, TAG_CONTROL, 32'd0);
        wr(dict, TAG_CONTROL, 32'h8000_0001);
        wr(tbl, TAG_OBJECT, 32'h0000_2000);
        w0 = writes;
        rlog.delete();
        run_cmd(OP_D_RESIZE, dict | KIND_DICT, ch | KIND_DICT, TAG_CONTROL,
                32'h0000_6700, 32'h0000_7000);
        check(got_fault && !got_ok, "missing precomputed hash faults");
        check(rd(dict + 8) == tbl, "missing hash leaves the old table");
        check(saw(32'h0000_2414), "missing hash still reads tp_hash");
        check(!saw(32'h0000_1800), "missing hash does not call the function");
        check(writes != w0, "resize allocated before the hash fault");
        $display("ok unhashable");
    endtask
endmodule
