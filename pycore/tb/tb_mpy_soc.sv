
// Runs one linked image on mpy_soc.
//
//   +IMAGE=<out>.hex +TAGS=<out>.tags.hex   flash contents (mpy_link.py)
//   +STDOUT=<path> +STDERR=<path>           console streams (default: this log)
//   +MAX_CYCLES=<n>                         give up after n cycles (default 50M)
//   +TRACE=1                                one line per executed opcode
//
// The last line is `MPY_HALT code=<n> value=<hex> cycles=<n> ops=<n> gc=<n>`
// or `MPY_TIMEOUT cycles=<n> ...` (pycore/tools/mpy_hw_tests.py parses it).
module tb_mpy_soc;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic        con_valid, con_err;
    logic [7:0]  con_byte;
    logic        halted;
    logic [3:0]  halt_code;
    logic [31:0] halt_value, cycles, ops, gc_coll, gc_free;
    logic        trace;
    logic [31:0] trace_pc;
    logic [7:0]  trace_op;
    logic [6:0]  trace_sp;

    mpy_soc u_soc (
        .clk_i(clk), .rst_n_i(rst_n),
        .con_valid_o(con_valid), .con_err_o(con_err), .con_byte_o(con_byte),
        .halted_o(halted), .halt_code_o(halt_code), .halt_value_o(halt_value),
        .cycles_o(cycles), .ops_o(ops), .gc_collections_o(gc_coll), .gc_free_o(gc_free),
        .trace_o(trace), .trace_pc_o(trace_pc), .trace_op_o(trace_op), .trace_sp_o(trace_sp)
    );

    int    fd_out, fd_err;
    longint max_cycles;
    bit    do_trace;
    longint n;

    initial begin
        string path;
        int t;
        fd_out = 0; fd_err = 0;
        if ($value$plusargs("STDOUT=%s", path)) fd_out = $fopen(path, "wb");
        if ($value$plusargs("STDERR=%s", path)) fd_err = $fopen(path, "wb");
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 50_000_000;
        do_trace = $value$plusargs("TRACE=%d", t) && t != 0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n && con_valid) begin
            if (con_err) begin
                if (fd_err != 0) $fwrite(fd_err, "%c", con_byte);
                else $write("%c", con_byte);
            end else begin
                if (fd_out != 0) $fwrite(fd_out, "%c", con_byte);
                else $write("%c", con_byte);
            end
        end
        if (rst_n && do_trace && trace)
            $display("TRACE pc=%08x op=%02x sp=%0d", trace_pc, trace_op, trace_sp);
    end

    initial begin
        n = 0;
        @(posedge rst_n);
        while (!halted && n < max_cycles) begin
            @(posedge clk);
            n++;
        end
        // let the last console byte land
        repeat (4) @(posedge clk);
        if (fd_out != 0) $fclose(fd_out);
        if (fd_err != 0) $fclose(fd_err);
        if (halted)
            $display("MPY_HALT code=%0d value=%08x cycles=%0d ops=%0d gc=%0d free=%0d",
                     halt_code, halt_value, cycles, ops, gc_coll, gc_free);
        else
            $display("MPY_TIMEOUT cycles=%0d ops=%0d gc=%0d pc=%08x op=%02x",
                     cycles, ops, gc_coll, trace_pc, trace_op);
        $finish;
    end
endmodule
