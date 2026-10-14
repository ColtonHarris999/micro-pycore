// Unit testbench for mpy_decode. Vectors come from mpy_decode_oracle.py,
// which checks each fixture operand against mpy-tool.py -xd.
module tb_mpy_decode;
    import mpy_dec::*;

    logic clk;
    logic rst_n;

    logic        pre_start;
    logic        pre_valid;
    logic [7:0]  pre_byte;
    logic        pre_ready;
    logic        pre_done;
    logic        pre_error;
    logic [15:0] n_state;
    logic [15:0] n_exc;
    logic [15:0] scope_flags;
    logic [15:0] n_pos;
    logic [15:0] n_kwonly;
    logic [15:0] n_def;
    logic [15:0] n_info;
    logic [15:0] n_cell;
    logic [15:0] opcode_off;
    logic [15:0] line_off;
    logic [15:0] line_end;

    logic               instr_valid;
    logic [63:0]        bytes;
    logic [3:0]         nbytes;
    logic               decoded_valid;
    logic               illegal;
    logic               truncated;
    logic               arg_overflow;
    logic [3:0]         len;
    logic [7:0]         opcode;
    logic [1:0]         format;
    entry_e             entry;
    logic               arg_valid;
    logic signed [31:0] arg;
    logic               extra_valid;
    logic [7:0]         extra;

    mpy_prelude_decode pre (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .start_i(pre_start),
        .byte_valid_i(pre_valid),
        .byte_i(pre_byte),
        .ready_o(pre_ready),
        .done_o(pre_done),
        .error_o(pre_error),
        .n_state_o(n_state),
        .n_exc_stack_o(n_exc),
        .scope_flags_o(scope_flags),
        .n_pos_args_o(n_pos),
        .n_kwonly_args_o(n_kwonly),
        .n_def_pos_args_o(n_def),
        .n_info_o(n_info),
        .n_cell_o(n_cell),
        .opcode_off_o(opcode_off),
        .line_info_off_o(line_off),
        .line_info_end_o(line_end)
    );

    mpy_decode dec (
        .instr_valid_i(instr_valid),
        .bytes_i(bytes),
        .nbytes_i(nbytes),
        .decoded_valid_o(decoded_valid),
        .illegal_o(illegal),
        .truncated_o(truncated),
        .arg_overflow_o(arg_overflow),
        .len_o(len),
        .opcode_o(opcode),
        .format_o(format),
        .entry_o(entry),
        .arg_valid_o(arg_valid),
        .arg_o(arg),
        .extra_valid_o(extra_valid),
        .extra_o(extra)
    );

    initial clk = 1'b0;
    always #5 clk <= ~clk;

    int checks;
    int fd;
    string path;
    string line;
    byte unsigned mem [0:8191];
    int mem_n;

    function automatic int hex_val(input int c);
        if (c >= "0" && c <= "9") return c - "0";
        if (c >= "a" && c <= "f") return c - "a" + 10;
        if (c >= "A" && c <= "F") return c - "A" + 10;
        return -1;
    endfunction

    function automatic void chomp(inout string s);
        int n;
        int c;
        begin
            n = s.len();
            while (n > 0) begin
                c = int'(s.getc(n - 1));
                if (c != "\n" && c != "\r") break;
                if (n == 1) s = "";
                else s = s.substr(0, n - 2);
                n = s.len();
            end
        end
    endfunction

    task automatic load_hex(input string hexstr);
        int i;
        int hi;
        int lo;
        begin
            mem_n = 0;
            if (hexstr.len() % 2 != 0) begin
                $fatal(1, "odd hex length: %s", hexstr);
            end
            for (i = 0; i < hexstr.len(); i += 2) begin
                hi = hex_val(int'(hexstr.getc(i)));
                lo = hex_val(int'(hexstr.getc(i + 1)));
                if (hi < 0 || lo < 0) $fatal(1, "bad hex: %s", hexstr);
                mem[mem_n] = byte'(hi * 16 + lo);
                mem_n += 1;
            end
        end
    endtask

    task automatic fail(input string msg);
        begin
            $fatal(1, "%s", msg);
        end
    endtask

    task automatic check_instr(
        input int exp_opcode,
        input int exp_len,
        input int exp_arg_valid,
        input int exp_arg,
        input int exp_extra_valid,
        input int exp_extra,
        input int exp_illegal,
        input string exp_entry
    );
        string got;
        begin
            instr_valid = 1'b1;
            nbytes = (mem_n > 8) ? 4'd8 : mem_n[3:0];
            bytes = 64'h0;
            for (int i = 0; i < mem_n && i < 8; i++) begin
                bytes[8 * i +: 8] = mem[i];
            end
            #1;
            got = entry.name();
            if ($isunknown(format) || !decoded_valid || truncated || arg_overflow) begin
                $fatal(1, "decode failed opcode %0d valid %0b trunc %0b overflow %0b",
                       exp_opcode, decoded_valid, truncated, arg_overflow);
            end
            if (opcode != exp_opcode[7:0] || len != exp_len[3:0] ||
                arg_valid != exp_arg_valid[0] ||
                (exp_arg_valid != 0 && arg != exp_arg) ||
                extra_valid != exp_extra_valid[0] ||
                (exp_extra_valid != 0 && extra != exp_extra[7:0]) ||
                illegal != exp_illegal[0] || got != exp_entry) begin
                $fatal(1,
                    "operand mismatch opcode got %0d exp %0d len %0d/%0d arg %0d (v %0b)/%0d (v %0b) extra %0d (v %0b)/%0d (v %0b) illegal %0b/%0b entry %s/%s",
                    opcode, exp_opcode, len, exp_len, arg, arg_valid, exp_arg, exp_arg_valid,
                    extra, extra_valid, exp_extra, exp_extra_valid,
                    illegal, exp_illegal, got, exp_entry);
            end
            checks += 1;
        end
    endtask

    task automatic check_prelude(
        input int exp_state,
        input int exp_exc,
        input int exp_flags,
        input int exp_pos,
        input int exp_kw,
        input int exp_def,
        input int exp_info,
        input int exp_cell,
        input int exp_op,
        input int exp_line,
        input int exp_line_end
    );
        int consumed;
        begin
            consumed = 0;
            pre_valid = 1'b0;
            pre_start = 1'b0;
            @(negedge clk);
            for (int i = 0; i < mem_n; i++) begin
                pre_start = (i == 0);
                pre_valid = 1'b1;
                pre_byte = mem[i];
                @(posedge clk);
                @(negedge clk);
                consumed += 1;
                pre_start = 1'b0;
                if (pre_done || pre_error) break;
            end
            pre_valid = 1'b0;
            if (pre_ready) begin
                $fatal(1, "prelude still ready after it finished");
            end
            if (pre_error || !pre_done) begin
                $fatal(1, "prelude did not finish consumed %0d error %0b done %0b",
                       consumed, pre_error, pre_done);
            end
            // n_state is the Python value count from the prelude, not a
            // register count after two-wide or four-wide expansion.
            if (consumed != exp_op || n_state != exp_state[15:0] ||
                n_exc != exp_exc[15:0] || scope_flags != exp_flags[15:0] ||
                n_pos != exp_pos[15:0] || n_kwonly != exp_kw[15:0] ||
                n_def != exp_def[15:0] || n_info != exp_info[15:0] ||
                n_cell != exp_cell[15:0] || opcode_off != exp_op[15:0] ||
                line_off != exp_line[15:0] || line_end != exp_line_end[15:0]) begin
                $fatal(1,
                    "prelude mismatch consumed %0d n_state %0d/%0d exc %0d/%0d flags %0d/%0d pos %0d/%0d kw %0d/%0d def %0d/%0d info %0d/%0d cell %0d/%0d op %0d/%0d line %0d/%0d end %0d/%0d",
                    consumed, n_state, exp_state, n_exc, exp_exc, scope_flags, exp_flags,
                    n_pos, exp_pos, n_kwonly, exp_kw, n_def, exp_def,
                    n_info, exp_info, n_cell, exp_cell, opcode_off, exp_op,
                    line_off, exp_line, line_end, exp_line_end);
            end
            $display("prelude n_state %0d opcode_off %0d line %0d..%0d",
                     n_state, opcode_off, line_off, line_end);
            checks += 1;
        end
    endtask

    initial begin
        checks = 0;
        rst_n = 1'b0;
        pre_start = 1'b0;
        pre_valid = 1'b0;
        pre_byte = 8'h00;
        instr_valid = 1'b0;
        bytes = 64'h0;
        nbytes = 4'd0;
        if (!$value$plusargs("VECTOR=%s", path)) begin
            $fatal(1, "missing +VECTOR");
        end
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "cannot open %s", path);
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        while (!$feof(fd)) begin
            if ($fgets(line, fd) == 0) break;
            chomp(line);
            if (line.len() == 0) continue;
            if (line.getc(0) == "#") begin
                $display("%s", line);
                continue;
            end
            if (line.getc(0) == "P") begin
                int st, ex, fl, po, kw, df, inf, ncell, opo, l0, l1;
                string hexstr;
                int n;
                n = $sscanf(line, "P %d %d %d %d %d %d %d %d %d %d %d %s",
                            st, ex, fl, po, kw, df, inf, ncell, opo, l0, l1, hexstr);
                if (n != 12) $fatal(1, "bad prelude line: %s", line);
                load_hex(hexstr);
                check_prelude(st, ex, fl, po, kw, df, inf, ncell, opo, l0, l1);
            end else if (line.getc(0) == "I" || line.getc(0) == "S") begin
                int ip, opc, ln, av, ag, ev, exb, ill;
                string ent, hexstr;
                int n;
                if (line.getc(0) == "I") begin
                    n = $sscanf(line, "I %d %d %d %d %d %d %d %d %s %s",
                                ip, opc, ln, av, ag, ev, exb, ill, ent, hexstr);
                    if (n != 10) $fatal(1, "bad instruction line: %s", line);
                    if (ip < 0) $fatal(1, "bad ip %0d", ip);
                end else begin
                    n = $sscanf(line, "S %d %d %d %d %d %d %d %s %s",
                                opc, ln, av, ag, ev, exb, ill, ent, hexstr);
                    if (n != 9) $fatal(1, "bad synthetic line: %s", line);
                end
                load_hex(hexstr);
                check_instr(opc, ln, av, ag, ev, exb, ill, ent);
            end else begin
                $fatal(1, "bad vector line: %s", line);
            end
        end
        $fclose(fd);

        // A short window must not invent the rest of a varuint.
        mem_n = 2;
        mem[0] = 8'h22;
        mem[1] = 8'h87;
        instr_valid = 1'b1;
        nbytes = 4'd2;
        bytes = 64'h0;
        bytes[7:0] = 8'h22;
        bytes[15:8] = 8'h87;
        #1;
        if (!truncated || decoded_valid) begin
            $fatal(1, "truncated varuint was accepted");
        end
        checks += 1;

        $display("mpy_decode checks: %0d ok at time %0t", checks, $time);
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "timeout");
    end
endmodule
