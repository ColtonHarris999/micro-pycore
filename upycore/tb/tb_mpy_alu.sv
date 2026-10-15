`include "upycore_defs.svh"

// Exit checks for mpy_alu: True+1, a binary32 add, a complex add issued as
// two scalar float adds, an INT64 that occupies two registers, and upper()
// leaving non-ASCII bytes unchanged.
module tb_mpy_alu;
    import mpy_alu_pkg::*;

    logic        clk;
    logic        rst_n;
    logic        start;
    logic [4:0]  op;
    logic [35:0] a_reg [4];
    logic [35:0] b_reg [4];
    logic [35:0] res  [4];
    logic [2:0]  nreg;
    logic        done;
    logic        trap;
    logic [4:0]  trap_code;
    logic        stall;
    logic        busy;

    mpy_alu dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .start_i(start),
        .op_i(op),
        .a_reg_i(a_reg),
        .b_reg_i(b_reg),
        .res_reg_o(res),
        .res_nreg_o(nreg),
        .done_o(done),
        .trap_o(trap),
        .trap_code_o(trap_code),
        .stall_o(stall),
        .busy_o(busy)
    );

    localparam logic [31:0] F32_M0   = 32'h8000_0000;
    localparam logic [31:0] F32_HALF = 32'h3f00_0000;
    localparam logic [31:0] F32_1    = 32'h3f80_0000;
    localparam logic [31:0] F32_2    = 32'h4000_0000;
    localparam logic [31:0] F32_3    = 32'h4040_0000;
    localparam logic [31:0] F32_4    = 32'h4080_0000;
    localparam logic [31:0] F32_6    = 32'h40c0_0000;

    localparam logic [63:0] F64_M0 = 64'h8000_0000_0000_0000;
    localparam logic [63:0] F64_1  = 64'h3FF0_0000_0000_0000;
    localparam logic [63:0] F64_2  = 64'h4000_0000_0000_0000;
    localparam logic [63:0] F64_3  = 64'h4008_0000_0000_0000;
    localparam logic [63:0] F64_4  = 64'h4010_0000_0000_0000;
    // binary32 min subnormal 2^-149, widened.
    localparam logic [63:0] F64_F32_MIN_SUB = 64'h36A0_0000_0000_0000;

    int          add_seen;
    logic        count_clear;
    logic [63:0] seen_a [4];
    logic [63:0] seen_b [4];
    logic        seen_sub [4];

    initial clk = 1'b0;
    // verilator lint_off BLKSEQ
    always #5 clk = ~clk;
    // verilator lint_on BLKSEQ

    // One count per accept on the existing scalar adder.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || count_clear) begin
            add_seen    <= 0;
            seen_a[0]   <= '0;
            seen_a[1]   <= '0;
            seen_a[2]   <= '0;
            seen_a[3]   <= '0;
            seen_b[0]   <= '0;
            seen_b[1]   <= '0;
            seen_b[2]   <= '0;
            seen_b[3]   <= '0;
            seen_sub[0] <= 1'b0;
            seen_sub[1] <= 1'b0;
            seen_sub[2] <= 1'b0;
            seen_sub[3] <= 1'b0;
        end else if (dut.u_fp_add.start_i && !dut.u_fp_add.busy_o && (add_seen < 4)) begin
            seen_a[add_seen]   <= dut.u_fp_add.op_a_i;
            seen_b[add_seen]   <= dut.u_fp_add.op_b_i;
            seen_sub[add_seen] <= dut.u_fp_add.sub_i;
            add_seen           <= add_seen + 1;
        end
    end

    task automatic clear_regs();
        for (int i = 0; i < 4; i++) begin
            a_reg[i] = '0;
            b_reg[i] = '0;
        end
    endtask

    task automatic run();
        int guard;
        count_clear = 1'b1;
        start = 1'b0;
        @(posedge clk);
        count_clear = 1'b0;
        @(posedge clk);
        start = 1'b1;
        guard = 0;
        do begin
            @(posedge clk);
            guard++;
            if (guard > 50)
                $fatal(1, "timeout op=%0d", op);
        end while (!done && !trap);
    endtask

    task automatic idle();
        start = 1'b0;
        @(posedge clk);
    endtask

    task automatic check(input logic cond, input string msg);
        if (!cond)
            $fatal(1, "%s", msg);
    endtask

    function automatic logic [7:0] ascii_upper(input logic [7:0] b);
        ascii_upper = ((b >= 8'h61) && (b <= 8'h7A)) ? (b - 8'h20) : b;
    endfunction

    initial begin
        logic [7:0] bytes [15];
        logic [7:0] got;
        rst_n = 1'b0;
        start = 1'b0;
        count_clear = 1'b0;
        op = UPY_ALU_ADD;
        clear_regs();
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        check((MPY_CTL_EMPTY == 4'd0) && (MPY_CTL_NONE == 4'd1) &&
              (MPY_CTL_NULL == 4'd2) && (MPY_CTL_TOMBSTONE == 4'd3) &&
              (MPY_CTL_FALSE == 4'd4) && (MPY_CTL_TRUE == 4'd5),
              "CONTROL kind map");
        $display("PASS CONTROL kinds: empty None null tombstone False True");

        // True + 1 == 2. True is CONTROL kind 5, read as int 1.
        clear_regs();
        op = UPY_ALU_ADD;
        a_reg[0] = mpy_reg(MPY_TAG_CONTROL, 32'(MPY_CTL_TRUE));
        b_reg[0] = mpy_reg(MPY_TAG_INT, 32'd1);
        run();
        check(!trap, "True+1 trapped");
        check(!stall && !busy, "True+1 still stalling at done");
        check(nreg == 3'd1, "True+1 used more than one register");
        check(res[0] == mpy_reg(MPY_TAG_INT, 32'd2), "True+1 != 2");
        check(res[1] == '0, "True+1 wrote a second register");
        check(add_seen == 0, "True+1 issued a float add");
        $display("PASS True+1 == 2  tag=%h pay=%h nreg=%0d",
                 mpy_tag(res[0]), mpy_pay(res[0]), nreg);
        idle();

        // A signed-32 add that does not fit becomes an INT64 pair.
        clear_regs();
        op = UPY_ALU_ADD;
        a_reg[0] = mpy_reg(MPY_TAG_INT, 32'h7FFF_FFFF);
        b_reg[0] = mpy_reg(MPY_TAG_INT, 32'd1);
        run();
        check(!trap, "i32 max+1 trapped");
        check(nreg == 3'd2, "i32 max+1 stayed in one register");
        check(res[0] == mpy_reg(MPY_TAG_INT64, 32'h8000_0000), "i32 max+1 low");
        check(res[1] == mpy_reg(MPY_TAG_CONT, 32'h0000_0000), "i32 max+1 high");
        $display("PASS INT max+1 == INT64 low=80000000 high=00000000");
        idle();

        // Equality is a CONTROL bool, not an int.
        clear_regs();
        op = UPY_ALU_EQ;
        a_reg[0] = mpy_reg(MPY_TAG_INT, 32'd1);
        b_reg[0] = mpy_reg(MPY_TAG_INT, 32'd1);
        run();
        check(!trap && (nreg == 3'd1) &&
              (res[0] == mpy_reg(MPY_TAG_CONTROL, 32'(MPY_CTL_TRUE))),
              "1==1 was not True");
        $display("PASS 1==1 is CONTROL True");
        idle();

        // Dict hashing uses the same int view: False -> 0, True -> 1.
        clear_regs();
        op = MPY_OP_HASH;
        a_reg[0] = mpy_reg(MPY_TAG_CONTROL, 32'(MPY_CTL_FALSE));
        run();
        check(!trap && (nreg == 3'd1) && (res[0] == mpy_reg(MPY_TAG_INT, 32'd0)),
               "hash(False) != int 0");
        idle();
        clear_regs();
        op = MPY_OP_HASH;
        a_reg[0] = mpy_reg(MPY_TAG_CONTROL, 32'(MPY_CTL_TRUE));
        run();
        check(!trap && (nreg == 3'd1) && (res[0] == mpy_reg(MPY_TAG_INT, 32'd1)),
               "hash(True) != int 1");
        check(add_seen == 0, "hash issued a float add");
        $display("PASS hash(False)==0 hash(True)==1");
        idle();

        // binary32 1+2 == 3, one scalar add of the widened values.
        clear_regs();
        op = UPY_ALU_ADD;
        a_reg[0] = mpy_reg(MPY_TAG_FLOAT, F32_1);
        b_reg[0] = mpy_reg(MPY_TAG_FLOAT, F32_2);
        run();
        check(!trap, "binary32 add trapped");
        check(nreg == 3'd1, "binary32 add was not one register");
        check(res[0] == mpy_reg(MPY_TAG_FLOAT, F32_3), "binary32 1+2 != 3");
        check(add_seen == 1, "binary32 add was not one float add");
        check(seen_sub[0] == 1'b0, "binary32 add used subtract");
        check((seen_a[0] == F64_1) && (seen_b[0] == F64_2),
               "binary32 add was not widened onto the binary64 adder");
        $display("PASS binary32 1+2 == 3  f32=%h  via one f64 add %h + %h",
                 mpy_pay(res[0]), seen_a[0], seen_b[0]);
        idle();

        // 0.5+0.5 and a subnormal sum both round back to binary32.
        clear_regs();
        op = UPY_ALU_ADD;
        a_reg[0] = mpy_reg(MPY_TAG_FLOAT, F32_HALF);
        b_reg[0] = mpy_reg(MPY_TAG_FLOAT, F32_HALF);
        run();
        check(!trap && (res[0] == mpy_reg(MPY_TAG_FLOAT, F32_1)) && (add_seen == 1),
               "binary32 0.5+0.5 != 1");
        idle();

        clear_regs();
        op = UPY_ALU_ADD;
        a_reg[0] = mpy_reg(MPY_TAG_FLOAT, 32'h0000_0001);
        b_reg[0] = mpy_reg(MPY_TAG_FLOAT, 32'h0000_0001);
        run();
        check(!trap && (res[0] == mpy_reg(MPY_TAG_FLOAT, 32'h0000_0002)),
               "binary32 subnormal 1+1 != 2");
        check((add_seen == 1) && (seen_a[0] == F64_F32_MIN_SUB) &&
               (seen_b[0] == F64_F32_MIN_SUB),
               "subnormal was not widened onto the binary64 adder");
        $display("PASS binary32 subnormal 0x00000001+0x00000001 == 0x00000002");
        idle();

        clear_regs();
        op = UPY_ALU_ADD;
        a_reg[0] = mpy_reg(MPY_TAG_FLOAT, F32_M0);
        b_reg[0] = mpy_reg(MPY_TAG_FLOAT, F32_M0);
        run();
        check(!trap && (res[0] == mpy_reg(MPY_TAG_FLOAT, F32_M0)) &&
               (seen_a[0] == F64_M0) && (seen_b[0] == F64_M0),
               "binary32 -0 + -0 != -0");
        $display("PASS binary32 -0 + -0 == -0");
        idle();

        clear_regs();
        op = UPY_ALU_SUB;
        a_reg[0] = mpy_reg(MPY_TAG_FLOAT, F32_3);
        b_reg[0] = mpy_reg(MPY_TAG_FLOAT, F32_1);
        run();
        check(!trap && (res[0] == mpy_reg(MPY_TAG_FLOAT, F32_2)) && (add_seen == 1) &&
              (seen_sub[0] == 1'b1) && (seen_a[0] == F64_3) && (seen_b[0] == F64_1),
              "binary32 3-1 != 2");
        $display("PASS binary32 3-1 == 2 on the same adder");
        idle();

        // (1+2j) + (3+4j) == (4+6j), two scalar adds, real then imag.
        clear_regs();
        op = UPY_ALU_ADD;
        a_reg[0] = mpy_reg(MPY_TAG_COMPLEX, F32_1);
        a_reg[1] = mpy_reg(MPY_TAG_CONT, F32_2);
        b_reg[0] = mpy_reg(MPY_TAG_COMPLEX, F32_3);
        b_reg[1] = mpy_reg(MPY_TAG_CONT, F32_4);
        run();
        check(!trap, "complex add trapped");
        check(nreg == 3'd2, "complex result did not span two registers");
        check(res[0] == mpy_reg(MPY_TAG_COMPLEX, F32_4), "complex real != 4");
        check(res[1] == mpy_reg(MPY_TAG_CONT, F32_6), "complex imag != 6");
        check(add_seen == 2, "complex add was not two float adds");
        check((seen_sub[0] == 1'b0) && (seen_sub[1] == 1'b0),
               "complex add used subtract");
        check((seen_a[0] == F64_1) && (seen_b[0] == F64_3),
               "first float add was not the real parts");
        check((seen_a[1] == F64_2) && (seen_b[1] == F64_4),
               "second float add was not the imaginary parts");
        $display("PASS complex (1+2j)+(3+4j)==(4+6j) as two float adds");
        $display("     add0 %h + %h", seen_a[0], seen_b[0]);
        $display("     add1 %h + %h", seen_a[1], seen_b[1]);
        idle();

        // INT64 operand already spans two registers. High word is nonzero,
        // so ignoring CONT would sign-extend the low word and produce 0.
        clear_regs();
        op = UPY_ALU_ADD;
        a_reg[0] = mpy_reg(MPY_TAG_INT64, 32'hFFFF_FFFF);
        a_reg[1] = mpy_reg(MPY_TAG_CONT, 32'h0000_0001);
        b_reg[0] = mpy_reg(MPY_TAG_INT, 32'd1);
        run();
        check(!trap, "INT64 add trapped");
        check(nreg == 3'd2, "INT64 result did not span two registers");
        check(res[0] == mpy_reg(MPY_TAG_INT64, 32'h0000_0000), "INT64 low != 0");
        check(res[1] == mpy_reg(MPY_TAG_CONT, 32'h0000_0002), "INT64 high != 2");
        check(add_seen == 0, "INT64 add issued a float add");
        $display("PASS INT64 0x1_ffffffff + 1 == 0x2_00000000 across two registers");
        idle();

        // Signed 64-bit overflow is OverflowError, not a wrapped INT64.
        clear_regs();
        op = UPY_ALU_ADD;
        a_reg[0] = mpy_reg(MPY_TAG_INT64, 32'hFFFF_FFFF);
        a_reg[1] = mpy_reg(MPY_TAG_CONT, 32'h7FFF_FFFF);
        b_reg[0] = mpy_reg(MPY_TAG_INT, 32'd1);
        run();
        check(trap && (trap_code == PY_TRAP_OVERFLOW),
               "INT64 max+1 did not raise OverflowError");
        check(nreg == 3'd0, "overflow wrote a result");
        check(add_seen == 0, "overflow issued a float add");
        $display("PASS INT64 max + 1 raises OverflowError (trap %0d)", trap_code);
        idle();

        // upper() of a 6-byte SHORT_STR. ASCII in register 0 changes.
        // 0xE9, 0xFF, and 0xDF sit in the CONT register and stay put.
        // Latin-1 upper would rewrite all three.
        clear_regs();
        op = MPY_OP_UPPER;
        bytes[0] = 8'h61;
        bytes[1] = 8'h62;
        bytes[2] = 8'h63;
        bytes[3] = 8'hE9;
        bytes[4] = 8'hFF;
        bytes[5] = 8'hDF;
        for (int i = 6; i < 15; i++)
            bytes[i] = 8'h00;
        a_reg[0] = mpy_reg(MPY_TAG_SHORT_STR,
                           mpy_pack4(8'd6, bytes[0], bytes[1], bytes[2]));
        a_reg[1] = mpy_reg(MPY_TAG_CONT,
                           mpy_pack4(bytes[3], bytes[4], bytes[5], bytes[6]));
        a_reg[2] = mpy_reg(MPY_TAG_CONT, 32'h0);
        a_reg[3] = mpy_reg(MPY_TAG_CONT, 32'h0);
        run();
        check(!trap, "upper trapped");
        check(nreg == 3'd4, "SHORT_STR result was not four registers");
        check(mpy_tag(res[0]) == MPY_TAG_SHORT_STR, "upper tag");
        check(mpy_tag(res[1]) == MPY_TAG_CONT, "upper cont1");
        check(mpy_tag(res[2]) == MPY_TAG_CONT, "upper cont2");
        check(mpy_tag(res[3]) == MPY_TAG_CONT, "upper cont3");
        check(mpy_pay(res[0]) == mpy_pack4(8'd6, 8'h41, 8'h42, 8'h43),
               "upper did not case ASCII in the first register");
        check(mpy_pay(res[1]) == mpy_pack4(8'hE9, 8'hFF, 8'hDF, 8'h00),
               "upper changed a non-ASCII byte");
        got = mpy_short_byte(mpy_pay(res[0]), mpy_pay(res[1]),
                             mpy_pay(res[2]), mpy_pay(res[3]), 4'd3);
        check(got == 8'hE9, "byte 3 was not left as 0xE9");
        check(add_seen == 0, "upper issued a float add");
        $display("PASS upper() ASCII abc -> ABC, non-ASCII E9 FF DF unchanged");
        idle();

        // Every byte: a-z moves, everything else including Latin-1 stays.
        for (int u = 0; u < 256; u++) begin
            clear_regs();
            op = MPY_OP_UPPER;
            a_reg[0] = mpy_reg(MPY_TAG_SHORT_STR, {16'b0, u[7:0], 8'd1});
            a_reg[1] = mpy_reg(MPY_TAG_CONT, 32'h0);
            a_reg[2] = mpy_reg(MPY_TAG_CONT, 32'h0);
            a_reg[3] = mpy_reg(MPY_TAG_CONT, 32'h0);
            run();
            check(!trap && (nreg == 3'd4), "byte upper shape");
            check(mpy_pay(res[0]) == {16'b0, ascii_upper(u[7:0]), 8'd1},
                   "byte upper mismatch");
            idle();
        end
        $display("PASS upper() is ASCII-only for all 256 bytes");

        // QSTR is an id and STR is a pointer. upper() does not case-map them.
        clear_regs();
        op = MPY_OP_UPPER;
        a_reg[0] = mpy_reg(MPY_TAG_QSTR, 32'h0000_00E9);
        run();
        check(trap && (trap_code == PY_TRAP_TYPE) && (nreg == 3'd0),
               "upper(QSTR) case-mapped an id");
        idle();
        clear_regs();
        op = MPY_OP_UPPER;
        a_reg[0] = mpy_reg(MPY_TAG_STR, 32'h2000_00E9);
        run();
        check(trap && (trap_code == PY_TRAP_TYPE) && (nreg == 3'd0),
               "upper(STR) case-mapped a pointer");
        $display("PASS upper() leaves a QSTR id and a STR pointer alone");
        idle();

        $display("ALL TESTS PASSED");
        $finish;
    end
endmodule
