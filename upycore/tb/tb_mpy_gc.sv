// mpy_gc unit testbench.
//
// 1. A dropped reference is collected and the next allocation reuses it.
//    The live object is an INSTANCE whose one field keeps a child alive, and
//    a poison word in the next field must not.
// 2. FLOAT, CONT, and the other non-pointer tags are not traced, including
//    False and True (CONTROL kinds).
// 3. One allocation larger than the pool returns the preallocated emergency
//    MemoryError object. Nothing in the pool is committed.
// 4. A FUNCTION keeps its closure (field 1), not a poison word past that.
// 5. A MUT_COLLEC dict pointer is followed only after the low 2 bits are
//    cleared, and its entry table keeps the value alive.

`include "mpy_defs.svh"

module tb_mpy_gc;
    localparam int POOL_BYTES = 64;
    localparam logic [31:0] BASE = 32'h2000_0000;
    localparam logic [31:0] ROOT = 32'h2000_0000;
    localparam logic [31:0] EMERG = 32'h2000_0200;
    localparam logic [31:0] POOL = 32'h2000_1000;
    localparam int MEM_BYTES = 8192;
    localparam int NS = MEM_BYTES / 4;
    localparam logic [31:0] SENTINEL = 32'hE11E_0001;

    logic clk;
    logic rst_n;
    logic [15:0] root_count;
    logic alloc_req;
    logic [31:0] alloc_nbytes;
    logic alloc_busy;
    logic alloc_done;
    logic alloc_ok;
    logic alloc_memerr;
    logic alloc_aborted;
    logic [31:0] alloc_addr;
    logic collect_req;
    logic collect_done;
    logic busy;
    logic stack_overflow;
    logic [31:0] free_bytes;
    logic [31:0] commit_count;
    logic trace_follow;
    logic trace_refuse;
    logic [3:0] trace_tag;
    logic [31:0] trace_addr;
    logic [4:0] state_o;
    logic mem_req;
    logic mem_we;
    logic [31:0] mem_addr;
    logic [31:0] mem_wdata;
    logic mem_tag_we;
    logic [3:0] mem_wtag;
    logic mem_ack;
    logic [31:0] mem_rdata;
    logic [3:0] mem_rtag;

    logic [31:0] data_mem [0:NS-1];
    logic [3:0]  tag_mem  [0:NS-1];

    int writes;
    bit mon_en;
    bit mon_clear;
    bit saw_float;
    bit saw_cont;
    bit bad_follow_tag;
    bit bad_follow_addr;
    logic [31:0] decoy_a;
    logic [31:0] decoy_b;

    mpy_gc #(
        .POOL_BYTES(POOL_BYTES),
        .POOL_BASE(POOL),
        .STACK_DEPTH(32)
    ) dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .root_base_i(ROOT),
        .root_count_i(root_count),
        .emergency_addr_i(EMERG),
        .alloc_req_i(alloc_req),
        .alloc_nbytes_i(alloc_nbytes),
        .alloc_busy_o(alloc_busy),
        .alloc_done_o(alloc_done),
        .alloc_ok_o(alloc_ok),
        .alloc_memerr_o(alloc_memerr),
        .alloc_aborted_o(alloc_aborted),
        .alloc_addr_o(alloc_addr),
        .collect_req_i(collect_req),
        .collect_done_o(collect_done),
        .busy_o(busy),
        .stack_overflow_o(stack_overflow),
        .free_bytes_o(free_bytes),
        .commit_count_o(commit_count),
        .trace_follow_o(trace_follow),
        .trace_refuse_o(trace_refuse),
        .trace_tag_o(trace_tag),
        .trace_addr_o(trace_addr),
        .state_o(state_o),
        .mem_req_o(mem_req),
        .mem_we_o(mem_we),
        .mem_addr_o(mem_addr),
        .mem_wdata_o(mem_wdata),
        .mem_tag_we_o(mem_tag_we),
        .mem_wtag_o(mem_wtag),
        .mem_ack_i(mem_ack),
        .mem_rdata_i(mem_rdata),
        .mem_rtag_i(mem_rtag)
    );

    wire in_range = (mem_addr >= BASE) && (mem_addr < BASE + MEM_BYTES) &&
                    (mem_addr[1:0] == 2'b00);
    wire [12:0] raw_slot = 13'((mem_addr - BASE) >> 2);
    wire slot_ok = in_range && (raw_slot < 13'(NS));
    wire [$clog2(NS)-1:0] slot = slot_ok ? raw_slot[$clog2(NS)-1:0] : '0;

    assign mem_ack = mem_req;
    assign mem_rdata = slot_ok ? data_mem[slot] : 32'h0;
    assign mem_rtag = slot_ok ? tag_mem[slot] : MPY_TAG_CONTROL;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function automatic bit tag_is_ptr(input logic [3:0] tag);
        case (tag)
            MPY_TAG_STR, MPY_TAG_TUPLE, MPY_TAG_MUT_COLLEC, MPY_TAG_RANGE,
            MPY_TAG_ITER, MPY_TAG_BYTES, MPY_TAG_OBJECT: tag_is_ptr = 1'b1;
            default: tag_is_ptr = 1'b0;
        endcase
    endfunction

    always @(posedge clk) begin
        if (mem_req && mem_we && in_range) begin
            data_mem[slot] <= mem_wdata;
            if (mem_tag_we)
                tag_mem[slot] <= mem_wtag;
            writes <= writes + 1;
        end
        if (mon_clear) begin
            saw_float <= 1'b0;
            saw_cont <= 1'b0;
            bad_follow_tag <= 1'b0;
            bad_follow_addr <= 1'b0;
        end else begin
            if (mon_en && trace_follow) begin
                if (!tag_is_ptr(trace_tag))
                    bad_follow_tag <= 1'b1;
                if ((trace_addr == decoy_a) || (trace_addr == decoy_b))
                    bad_follow_addr <= 1'b1;
            end
            if (mon_en && trace_refuse && (trace_tag == MPY_TAG_FLOAT))
                saw_float <= 1'b1;
            if (mon_en && trace_refuse && (trace_tag == MPY_TAG_CONT))
                saw_cont <= 1'b1;
        end
    end

    task automatic check(input bit cond, input string msg);
        begin
            if (!cond) begin
                $display("FAIL: %s (state=%0d free=%0d commits=%0d)",
                         msg, state_o, free_bytes, commit_count);
                $fatal(1);
            end
        end
    endtask

    task automatic slot_write(
        input logic [31:0] addr,
        input logic [31:0] payload,
        input logic [3:0] tag
    );
        logic [$clog2(NS)-1:0] s;
        begin
            s = ($clog2(NS))'((addr - BASE) >> 2);
            data_mem[s] = payload;
            tag_mem[s] = tag;
        end
    endtask

    task automatic slot_read(
        input logic [31:0] addr,
        output logic [31:0] payload,
        output logic [3:0] tag
    );
        logic [$clog2(NS)-1:0] s;
        begin
            s = ($clog2(NS))'((addr - BASE) >> 2);
            payload = data_mem[s];
            tag = tag_mem[s];
        end
    endtask

    task automatic plant_emergency;
        begin
            slot_write(EMERG, MPY_OB_EXCEPTION, MPY_TAG_INT);
            slot_write(EMERG + 32'd4, 32'h0, MPY_TAG_CONTROL);
            slot_write(EMERG + 32'd8, {28'h0, MPY_CTL_NONE}, MPY_TAG_CONTROL);
            slot_write(EMERG + 32'd12, SENTINEL, MPY_TAG_INT);
        end
    endtask

    task automatic reset_dut;
        int i;
        begin
            rst_n = 1'b0;
            alloc_req = 1'b0;
            collect_req = 1'b0;
            root_count = 16'd0;
            alloc_nbytes = 32'h0;
            mon_en = 1'b0;
            mon_clear = 1'b0;
            writes = 0;
            decoy_a = 32'h0;
            decoy_b = 32'h0;
            for (i = 0; i < NS; i++) begin
                data_mem[i] = 32'h0;
                tag_mem[i] = MPY_TAG_CONTROL;
            end
            plant_emergency();
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            #1;
        end
    endtask

    task automatic do_alloc(
        input int unsigned nbytes,
        input bit watch,
        output logic [31:0] addr,
        output bit ok,
        output bit memerr,
        output bit aborted
    );
        int guard;
        int w0;
        int w_abort;
        begin
            w0 = writes;
            w_abort = writes;
            @(posedge clk);
            alloc_nbytes = nbytes[31:0];
            alloc_req = 1'b1;
            @(posedge clk);
            alloc_req = 1'b0;
            ok = 1'b0;
            memerr = 1'b0;
            aborted = 1'b0;
            addr = 32'h0;
            guard = 0;
            while (guard < 20000) begin
                @(posedge clk);
                #1;
                if (alloc_aborted && !aborted) begin
                    aborted = 1'b1;
                    w_abort = writes;
                end
                if (alloc_done) begin
                    ok = alloc_ok;
                    memerr = alloc_memerr;
                    addr = alloc_addr;
                    break;
                end
                guard++;
            end
            check(guard < 20000, "allocation timed out");
            check(!alloc_busy && !busy, "engine still busy after the allocation");
            if (watch && aborted)
                check(w_abort == w0, "heap was written before the abort");
            if (watch && memerr)
                check(writes == w0, "MemoryError path wrote the pool");
        end
    endtask

    task automatic do_collect;
        int guard;
        begin
            @(posedge clk);
            collect_req = 1'b1;
            @(posedge clk);
            collect_req = 1'b0;
            guard = 0;
            while (guard < 20000) begin
                @(posedge clk);
                #1;
                if (collect_done)
                    break;
                guard++;
            end
            check(guard < 20000, "collection timed out");
            check(!stack_overflow, "mark stack overflowed");
            check(!busy, "engine still busy after collection");
        end
    endtask

    task automatic alloc_ok_at(input int unsigned nbytes, output logic [31:0] addr);
        bit ok;
        bit memerr;
        bit aborted;
        begin
            do_alloc(nbytes, 1'b0, addr, ok, memerr, aborted);
            check(ok && !memerr && !aborted, "expected a grant with no collection");
        end
    endtask

    // INSTANCE: one field keeps `keeper`. The next word is poison and must
    // not keep `dropped` alive. Pool is full, so the next 4-byte alloc
    // aborts, collects, and reuses `dropped`.
    task automatic test_dropped_reference;
        logic [31:0] inst;
        logic [31:0] keeper;
        logic [31:0] dropped;
        logic [31:0] pad;
        logic [31:0] again;
        logic [31:0] commits;
        bit ok;
        bit memerr;
        bit aborted;
        begin
            $display("TEST dropped reference");
            reset_dut();
            alloc_ok_at(16, inst);
            alloc_ok_at(4, keeper);
            alloc_ok_at(4, dropped);
            alloc_ok_at(40, pad);
            check(inst + 32'd16 == keeper, "keeper follows the instance");
            check(keeper + 32'd4 == dropped, "dropped follows the keeper");
            check(dropped + 32'd4 == pad, "pad fills the pool");

            slot_write(inst, MPY_OB_INSTANCE, MPY_TAG_INT);
            slot_write(inst + 32'd4, 32'h0, MPY_TAG_CONTROL);
            slot_write(inst + 32'd8, keeper, MPY_TAG_TUPLE);
            slot_write(inst + 32'd12, dropped, MPY_TAG_TUPLE);
            slot_write(keeper, 32'h0, MPY_TAG_INT);
            slot_write(ROOT, inst, MPY_TAG_OBJECT);
            root_count = 16'd1;

            commits = commit_count;
            do_alloc(4, 1'b1, again, ok, memerr, aborted);
            check(aborted, "a full pool must abort before commit");
            check(ok && !memerr, "the retry must grant the dropped block");
            check(again == dropped, "the dropped reference was not reused");
            check(commit_count == commits + 32'd1, "retry committed more than once");
            check(free_bytes == 32'd40, "free bytes after reusing the dropped block");
            check(data_mem[int'((inst + 32'd8 - BASE) >> 2)] == keeper,
                  "collection cleared the live instance field");
            $display("PASS dropped reference reused at 0x%08x", again);
        end
    endtask

    // Every non-pointer tag sits in a rooted tuple and names a decoy. None
    // of those decoys may be marked. False's payload is decoy B's address.
    task automatic test_refuse_immediates;
        logic [31:0] tuple;
        logic [31:0] again_a;
        logic [31:0] again_b;
        logic [31:0] elem;
        begin
            $display("TEST refuse immediates");
            reset_dut();
            alloc_ok_at(4, decoy_a);
            alloc_ok_at(4, decoy_b);
            alloc_ok_at(40, tuple);
            check(decoy_b == decoy_a + 32'd4, "decoy B is the next granule");
            check(decoy_b[3:0] == MPY_CTL_FALSE, "decoy B must look like False");

            slot_write(tuple, 32'd9, MPY_TAG_INT);
            elem = tuple + 32'd4;
            slot_write(elem, decoy_a, MPY_TAG_FLOAT); elem += 32'd4;
            slot_write(elem, decoy_b, MPY_TAG_CONT); elem += 32'd4;
            // True: low nibble is the kind. Masking it off yields decoy A.
            slot_write(elem, decoy_a + 32'd5, MPY_TAG_CONTROL); elem += 32'd4;
            // False: the payload is exactly decoy B.
            slot_write(elem, decoy_b, MPY_TAG_CONTROL); elem += 32'd4;
            slot_write(elem, decoy_a, MPY_TAG_INT); elem += 32'd4;
            slot_write(elem, decoy_a, MPY_TAG_INT64); elem += 32'd4;
            slot_write(elem, decoy_b, MPY_TAG_COMPLEX); elem += 32'd4;
            slot_write(elem, decoy_a, MPY_TAG_QSTR); elem += 32'd4;
            slot_write(elem, decoy_b, MPY_TAG_SHORT_STR);

            slot_write(ROOT, tuple, MPY_TAG_TUPLE);
            root_count = 16'd1;
            mon_clear = 1'b1;
            @(posedge clk);
            #1;
            mon_clear = 1'b0;
            mon_en = 1'b1;
            do_collect();
            repeat (2) @(posedge clk);
            #1;
            mon_en = 1'b0;

            check(saw_float, "a FLOAT word was not refused");
            check(saw_cont, "a CONT word was not refused");
            check(!bad_follow_tag, "a non-pointer tag was traced");
            check(!bad_follow_addr, "a decoy address was traced");
            check(free_bytes == 32'd24, "decoys were not freed");

            alloc_ok_at(4, again_a);
            alloc_ok_at(4, again_b);
            check(again_a == decoy_a, "FLOAT/True decoy was not reusable");
            check(again_b == decoy_b, "CONT/False decoy was not reusable");
            $display("PASS refused FLOAT and CONT; decoys reused");
        end
    endtask

    task automatic test_memory_error;
        logic [31:0] addr;
        logic [31:0] later;
        logic [31:0] commits;
        logic [31:0] kind;
        logic [31:0] mark;
        logic [3:0] kind_tag;
        logic [3:0] mark_tag;
        bit ok;
        bit memerr;
        bit aborted;
        int w0;
        begin
            $display("TEST MemoryError");
            reset_dut();
            commits = commit_count;
            w0 = writes;
            do_alloc(128, 1'b1, addr, ok, memerr, aborted);
            check(aborted, "an oversize alloc must abort and collect");
            check(memerr && !ok, "an oversize alloc must raise MemoryError");
            check(addr == EMERG, "MemoryError did not come from the emergency object");
            check(commit_count == commits, "oversize alloc committed pool state");
            check(writes == w0, "oversize alloc wrote pool memory");
            check(free_bytes == POOL_BYTES[31:0], "pool changed on MemoryError");
            slot_read(EMERG, kind, kind_tag);
            slot_read(EMERG + 32'd12, mark, mark_tag);
            check(kind == MPY_OB_EXCEPTION, "emergency kind was overwritten");
            check(kind_tag == MPY_TAG_INT, "emergency kind tag changed");
            check(mark == SENTINEL, "emergency sentinel was overwritten");
            check(mark_tag == MPY_TAG_INT, "emergency sentinel tag changed");

            alloc_ok_at(4, later);
            check(later == POOL, "pool was not empty after MemoryError");
            check(later != EMERG, "a later alloc returned the emergency object");
            $display("PASS MemoryError from emergency object 0x%08x", addr);
        end
    endtask

    // FUNCTION has two fields. Field 1 is the closure. The word after that
    // is poison and must not keep `dropped`.
    task automatic test_function_fields;
        logic [31:0] fn;
        logic [31:0] keeper;
        logic [31:0] dropped;
        logic [31:0] pad;
        logic [31:0] again;
        bit ok;
        bit memerr;
        bit aborted;
        begin
            $display("TEST function fields");
            reset_dut();
            alloc_ok_at(20, fn);
            alloc_ok_at(4, keeper);
            alloc_ok_at(4, dropped);
            alloc_ok_at(36, pad);
            check(pad == dropped + 32'd4, "function pad does not fill the pool");
            slot_write(fn, MPY_OB_FUNCTION, MPY_TAG_INT);
            slot_write(fn + 32'd4, 32'h0, MPY_TAG_CONTROL);
            slot_write(fn + 32'd8, 32'h0000_0100, MPY_TAG_INT);
            slot_write(fn + 32'd12, keeper, MPY_TAG_TUPLE);
            slot_write(fn + 32'd16, dropped, MPY_TAG_TUPLE);
            slot_write(keeper, 32'h0, MPY_TAG_INT);
            slot_write(ROOT, fn, MPY_TAG_OBJECT);
            root_count = 16'd1;
            do_alloc(4, 1'b1, again, ok, memerr, aborted);
            check(aborted && ok && !memerr, "function case did not reuse after collect");
            check(again == dropped, "function closure was not traced from the kind word");
            $display("PASS function closure kept, poison word ignored");
        end
    endtask

    // Dict pointer carries kind 1 in the low bits. The entry value must live.
    task automatic test_mut_collec;
        logic [31:0] dict;
        logic [31:0] entries;
        logic [31:0] keeper;
        logic [31:0] dropped;
        logic [31:0] pad;
        logic [31:0] again;
        bit ok;
        bit memerr;
        bit aborted;
        begin
            $display("TEST MUT_COLLEC");
            reset_dut();
            alloc_ok_at(16, dict);
            alloc_ok_at(8, entries);
            alloc_ok_at(4, keeper);
            alloc_ok_at(4, dropped);
            alloc_ok_at(32, pad);
            check(pad == dropped + 32'd4, "dict pad does not fill the pool");
            check(dict[1:0] == 2'b00, "dict object is 4-byte aligned");

            slot_write(dict, 32'd1, MPY_TAG_INT);
            slot_write(dict + 32'd4, 32'd1, MPY_TAG_INT);
            slot_write(dict + 32'd8, entries, MPY_TAG_TUPLE);
            slot_write(dict + 32'd12, 32'h0, MPY_TAG_CONTROL);
            slot_write(entries, 32'd7, MPY_TAG_INT);
            slot_write(entries + 32'd4, keeper, MPY_TAG_TUPLE);
            slot_write(keeper, 32'h0, MPY_TAG_INT);
            // Kind is dict. The address the tracer follows must drop these bits.
            slot_write(ROOT, dict | 32'd1, MPY_TAG_MUT_COLLEC);
            root_count = 16'd1;

            do_alloc(4, 1'b1, again, ok, memerr, aborted);
            check(aborted && ok && !memerr, "dict case did not complete the retry");
            check(again == dropped, "MUT_COLLEC pointer was not masked before the walk");
            $display("PASS MUT_COLLEC low bits cleared, entry kept");
        end
    endtask

    initial begin
        reset_dut();
        test_dropped_reference();
        test_refuse_immediates();
        test_memory_error();
        test_function_fields();
        test_mut_collec();
        $display("PASS tb_mpy_gc");
        $finish;
    end

    initial begin
        repeat (200000) @(posedge clk);
        $display("FAIL: global timeout (state=%0d)", state_o);
        $fatal(1);
    end
endmodule
