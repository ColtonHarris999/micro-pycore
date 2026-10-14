// Phase-5 peripheral exit.
// Counts GPIO_OUT edges for blink, echoes UART bytes that fit, records one
// overrun, and raises on the ninth micropython.schedule.
// Expected edges and echo bytes come from pycore/tools/mpy_periph_model.py.
// The unix machine module is not used.
module tb_mpy_periph;
    import mpy_mmio_pkg::*;

    localparam logic [31:0] BLINK_FN  = 32'h0000_0A11;
    localparam logic [31:0] BLINK_ARG = 32'h0000_0B22;
    localparam logic [31:0] ECHO_FN   = 32'h0000_0E41;
    localparam logic [31:0] ECHO_ARG  = 32'h0000_0E42;
    localparam logic [31:0] HARD_FN   = 32'h0000_0C0F;
    localparam logic [31:0] HARD_ARG  = 32'h0000_00EE;

    logic        clk = 1'b0;
    logic        rst_n = 1'b0;
    logic        req = 1'b0;
    logic        we = 1'b0;
    logic [31:0] addr_bus = 32'h0;
    logic [31:0] wdata = 32'h0;
    logic [31:0] rdata;
    logic        ack;
    logic        fault;
    logic        timer_step = 1'b0;
    logic        uart_rx_stb = 1'b0;
    logic [7:0]  uart_rx_byte = 8'h0;
    logic        uart_tx_stb;
    logic [7:0]  uart_tx_byte;
    logic [31:0] gpio_out;
    logic        soft_set = 1'b0;
    logic        gc_req = 1'b0;
    logic        sim_set = 1'b0;
    logic        bc_boundary = 1'b0;
    logic        jump = 1'b0;
    logic        done = 1'b0;
    logic        fire, fire_hard, fire_sched;
    logic [2:0]  fire_src;
    logic [31:0] fire_fn, fire_arg;
    logic        heap_locked, sched_locked, irq_active;
    logic        handler_we = 1'b0;
    logic [2:0]  handler_idx = 3'h0;
    logic [31:0] handler_fn = 32'h0;
    logic [31:0] handler_arg = 32'h0;
    logic        sched_push = 1'b0;
    logic [31:0] sched_fn = 32'h0;
    logic [31:0] sched_arg = 32'h0;
    logic        sched_ok, sched_full;
    logic [31:0] pc = 32'h0;
    logic [31:0] fp = 32'h0;
    logic [31:0] sp = 32'h0;
    logic [31:0] exc_sp = 32'h0;
    logic [31:0] saved_pc, saved_fp, saved_sp, saved_exc;

    logic [7:0] tx_log[$];
    int         overrun_seen;
    int         tick_now;
    logic [31:0] got_mask;
    int          got_edges;

    int blink_period, blink_ticks, expect_edges, hold_compare, hold_steps;
    int hold_idle_steps, hold_count, expect_tx_word, expect_txn, expect_overrun;
    int expect_sched_raise;
    logic [31:0] expect_edge_mask, expect_off_mask;

    mpy_periph dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .req_i(req),
        .we_i(we),
        .addr_i(addr_bus),
        .wdata_i(wdata),
        .rdata_o(rdata),
        .ack_o(ack),
        .fault_o(fault),
        .timer_step_i(timer_step),
        .uart_rx_stb_i(uart_rx_stb),
        .uart_rx_byte_i(uart_rx_byte),
        .uart_tx_stb_o(uart_tx_stb),
        .uart_tx_byte_o(uart_tx_byte),
        .gpio_out_o(gpio_out),
        .soft_set_i(soft_set),
        .gc_req_i(gc_req),
        .sim_set_i(sim_set),
        .bc_boundary_i(bc_boundary),
        .jump_i(jump),
        .done_i(done),
        .fire_o(fire),
        .fire_hard_o(fire_hard),
        .fire_sched_o(fire_sched),
        .fire_src_o(fire_src),
        .fire_fn_o(fire_fn),
        .fire_arg_o(fire_arg),
        .heap_locked_o(heap_locked),
        .sched_locked_o(sched_locked),
        .irq_active_o(irq_active),
        .handler_we_i(handler_we),
        .handler_idx_i(handler_idx),
        .handler_fn_i(handler_fn),
        .handler_arg_i(handler_arg),
        .sched_push_i(sched_push),
        .sched_fn_i(sched_fn),
        .sched_arg_i(sched_arg),
        .sched_ok_o(sched_ok),
        .sched_full_o(sched_full),
        .pc_i(pc),
        .fp_i(fp),
        .sp_i(sp),
        .exc_sp_i(exc_sp),
        .saved_pc_o(saved_pc),
        .saved_fp_o(saved_fp),
        .saved_sp_o(saved_sp),
        .saved_exc_sp_o(saved_exc)
    );

    always #5 clk = ~clk;

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $error("FAIL: %s", msg);
            $fatal(1);
        end
    endtask

    task automatic quiet_inputs();
        req         = 1'b0;
        we          = 1'b0;
        timer_step  = 1'b0;
        uart_rx_stb = 1'b0;
        soft_set    = 1'b0;
        gc_req      = 1'b0;
        sim_set     = 1'b0;
        bc_boundary = 1'b0;
        jump        = 1'b0;
        done        = 1'b0;
        handler_we  = 1'b0;
        sched_push  = 1'b0;
    endtask

    task automatic do_reset();
        quiet_inputs();
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        @(negedge clk);
    endtask

    task automatic bus_write(input logic [31:0] addr, input logic [31:0] data);
        @(negedge clk);
        req      = 1'b1;
        we       = 1'b1;
        addr_bus = addr;
        wdata    = data;
        #1;
        check(!fault && ack, "MMIO store faulted");
        if (uart_tx_stb)
            tx_log.push_back(uart_tx_byte);
        @(posedge clk);
        @(negedge clk);
        req = 1'b0;
        we  = 1'b0;
    endtask

    task automatic bus_write_bad(input logic [31:0] addr, input logic [31:0] data);
        @(negedge clk);
        req      = 1'b1;
        we       = 1'b1;
        addr_bus = addr;
        wdata    = data;
        #1;
        check(fault && !ack, "expected a bus fault");
        check(!uart_tx_stb, "faulting store must not transmit");
        @(posedge clk);
        @(negedge clk);
        req = 1'b0;
        we  = 1'b0;
    endtask

    task automatic bus_read(input logic [31:0] addr, output logic [31:0] data);
        @(negedge clk);
        req      = 1'b1;
        we       = 1'b0;
        addr_bus = addr;
        wdata    = 32'h0;
        #1;
        check(!fault && ack, "MMIO load faulted");
        data = rdata;
        @(posedge clk);
        @(negedge clk);
        req = 1'b0;
    endtask

    task automatic step_timer();
        @(negedge clk);
        timer_step = 1'b1;
        @(posedge clk);
        @(negedge clk);
        timer_step = 1'b0;
    endtask

    task automatic pulse_boundary();
        @(negedge clk);
        bc_boundary = 1'b1;
        jump        = 1'b0;
        @(posedge clk);
        @(negedge clk);
        bc_boundary = 1'b0;
    endtask

    task automatic pulse_jump();
        @(negedge clk);
        bc_boundary = 1'b1;
        jump        = 1'b1;
        @(posedge clk);
        @(negedge clk);
        bc_boundary = 1'b0;
        jump        = 1'b0;
    endtask

    task automatic pulse_done();
        @(negedge clk);
        done = 1'b1;
        @(posedge clk);
        @(negedge clk);
        done = 1'b0;
    endtask

    task automatic idle_clocks(input int n);
        for (int k = 0; k < n; k++) begin
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task automatic install_handler(
        input logic [2:0] idx,
        input logic [31:0] fn,
        input logic [31:0] arg
    );
        @(negedge clk);
        handler_we  = 1'b1;
        handler_idx = idx;
        handler_fn  = fn;
        handler_arg = arg;
        @(posedge clk);
        @(negedge clk);
        handler_we = 1'b0;
    endtask

    task automatic push_rx(input logic [7:0] byte_i);
        @(negedge clk);
        uart_rx_stb  = 1'b1;
        uart_rx_byte = byte_i;
        @(posedge clk);
        @(negedge clk);
        uart_rx_stb = 1'b0;
    endtask

    task automatic pulse_level(input int which);
        @(negedge clk);
        soft_set = (which == MPY_SRC_SOFT);
        gc_req   = (which == MPY_SRC_GC_REQ);
        sim_set  = (which == MPY_SRC_SIM);
        @(posedge clk);
        @(negedge clk);
        soft_set = 1'b0;
        gc_req   = 1'b0;
        sim_set  = 1'b0;
    endtask

    task automatic do_sched(
        input logic [31:0] fn,
        input logic [31:0] arg,
        output bit ok,
        output bit full
    );
        @(negedge clk);
        sched_push = 1'b1;
        sched_fn   = fn;
        sched_arg  = arg;
        @(posedge clk);
        @(negedge clk);
        ok   = sched_ok;
        full = sched_full;
        sched_push = 1'b0;
    endtask

    task automatic read_occ(output logic [7:0] occ);
        logic [31:0] head_v, tail_v;
        bus_read(mpy_mmio_addr(MPY_SCHED_HEAD), head_v);
        bus_read(mpy_mmio_addr(MPY_SCHED_TAIL), tail_v);
        check(head_v[31:8] == 24'h0 && tail_v[31:8] == 24'h0,
              "schedule indexes are one byte");
        occ = tail_v[7:0] - head_v[7:0];
    endtask

    task automatic toggle_gpio();
        logic [31:0] value;
        bus_read(mpy_mmio_addr(MPY_GPIO_OUT), value);
        check(value == gpio_out, "GPIO_OUT load mismatch");
        bus_write(mpy_mmio_addr(MPY_GPIO_OUT), value ^ 32'h1);
        check(gpio_out == (value ^ 32'h1), "GPIO_OUT store did not update the pin");
        got_mask  = got_mask | (32'h1 << (tick_now - 1));
        got_edges = got_edges + 1;
    endtask

    task automatic blink_run(input int period, input int ticks, input int extra_idles,
                             input logic [31:0] expect_mask);
        logic [31:0] value;
        do_reset();
        got_mask  = 32'h0;
        got_edges = 0;
        bus_write(mpy_mmio_addr(MPY_TIMER_COUNT), 32'(period));
        bus_write(mpy_mmio_addr(MPY_IRQ_ENABLE), 32'h1 << MPY_SRC_TIMER);
        bus_write(mpy_mmio_addr(MPY_IRQ_HARD), 32'h0);
        bus_write(mpy_mmio_addr(MPY_IRQ_GIE), 32'h1);
        install_handler(MPY_SRC_TIMER, BLINK_FN, BLINK_ARG);
        for (int tick = 1; tick <= ticks; tick++) begin
            tick_now = tick;
            step_timer();
            idle_clocks(extra_idles);
            if (expect_mask[tick - 1]) begin
                bus_read(mpy_mmio_addr(MPY_TIMER_COUNT), value);
                check(value == 32'h0, "match reloads the counter to 0");
                bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
                check(value[MPY_SRC_TIMER], "match sets the timer status bit");
            end
            pulse_boundary();
            check(!fire, "soft timer IRQ waits for a jump opcode");
            pulse_jump();
            if (expect_mask[tick - 1]) begin
                check(fire, "blink callback missing at the jump");
                check(!fire_hard, "blink timer is a soft IRQ");
                check(fire_sched == 1'b0, "device callback is not a schedule pop");
                check(fire_src == 3'(MPY_SRC_TIMER), "blink source");
                check(fire_fn == BLINK_FN && fire_arg == BLINK_ARG, "blink handler");
                check(!heap_locked && !sched_locked && !irq_active,
                      "soft callback may allocate");
                toggle_gpio();
                pulse_done();
                check(!fire && !heap_locked, "callback returned");
                bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
                check(!value[MPY_SRC_TIMER], "accepting the callback clears timer status");
            end else begin
                check(!fire, "unexpected blink callback");
            end
        end
        check(got_mask == expect_mask, "GPIO_OUT edge mask");
        check(got_edges == $countones(expect_mask), "GPIO_OUT edge count");
        $display("BLINK period=%0d ticks=%0d idles=%0d edges=%0d mask=0x%0h",
                 period, ticks, extra_idles, got_edges, got_mask);
    endtask

    task automatic check_faults_and_table();
        logic [31:0] value;
        do_reset();
        bus_write(mpy_mmio_addr(MPY_GPIO_OUT), 32'h0000_00A5);
        bus_write_bad(MPY_MMIO_BASE + 32'h1, 32'hFFFF_FFFF);
        bus_write_bad(32'h2000_0000, 32'h1);
        bus_read(mpy_mmio_addr(MPY_GPIO_OUT), value);
        check(value == 32'h0000_00A5, "faulting stores changed GPIO_OUT");
        bus_read(mpy_mmio_addr(12'h038), value);
        check(value == 32'h0, "unimplemented offset reads as 0");
        bus_write(mpy_mmio_addr(MPY_IRQ_TABLE), 32'h2000_0100);
        bus_read(mpy_mmio_addr(MPY_IRQ_TABLE), value);
        check(value == 32'h2000_0100, "IRQ_TABLE round trip");
    endtask

    task automatic check_timer_hold();
        logic [31:0] value;
        do_reset();
        bus_write(mpy_mmio_addr(MPY_TIMER_COUNT), 32'(hold_compare));
        for (int i = 0; i < hold_steps; i++)
            step_timer();
        bus_read(mpy_mmio_addr(MPY_TIMER_COUNT), value);
        check(value == 32'(hold_count), "counter after partial period");
        bus_write(mpy_mmio_addr(MPY_TIMER_COUNT), 32'h0);
        for (int i = 0; i < hold_idle_steps; i++)
            step_timer();
        bus_read(mpy_mmio_addr(MPY_TIMER_COUNT), value);
        check(value == 32'(hold_count), "compare 0 holds the counter");
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(value == 32'h0, "disabled timer sets no IRQ");
        // Write-1-to-clear still retires a latched bit.
        bus_write(mpy_mmio_addr(MPY_TIMER_COUNT), 32'h1);
        step_timer();
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(value[MPY_SRC_TIMER], "timer status latches while masked");
        bus_write(mpy_mmio_addr(MPY_IRQ_STATUS), 32'h1 << MPY_SRC_TIMER);
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(!value[MPY_SRC_TIMER], "write-1-to-clear");
    endtask

    task automatic check_gie();
        logic [31:0] value;
        do_reset();
        install_handler(MPY_SRC_TIMER, BLINK_FN, BLINK_ARG);
        bus_write(mpy_mmio_addr(MPY_TIMER_COUNT), 32'h1);
        bus_write(mpy_mmio_addr(MPY_IRQ_ENABLE), 32'h1 << MPY_SRC_TIMER);
        bus_write(mpy_mmio_addr(MPY_IRQ_HARD), 32'h0);
        bus_read(mpy_mmio_addr(MPY_IRQ_GIE), value);
        check(value == 32'h1, "GIE resets set");
        bus_write(mpy_mmio_addr(MPY_IRQ_GIE), 32'h0);
        step_timer();
        pulse_boundary();
        check(!fire, "GIE clear blocks a boundary");
        pulse_jump();
        check(!fire, "GIE clear blocks a soft IRQ");
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(value[MPY_SRC_TIMER], "pending status survives disable_irq");
        bus_write(mpy_mmio_addr(MPY_IRQ_GIE), 32'h1);
        pulse_boundary();
        check(!fire, "restored GIE still waits for a jump");
        pulse_jump();
        check(fire && !heap_locked && fire_src == 3'(MPY_SRC_TIMER),
              "enable_irq restores soft delivery");
        pulse_done();
    endtask

    task automatic service_echo();
        logic [31:0] rx;
        pulse_boundary();
        check(!fire, "UART soft IRQ waits for a jump");
        pulse_jump();
        check(fire && !fire_hard && !heap_locked && !irq_active, "echo callback");
        check(fire_src == 3'(MPY_SRC_UART), "echo source");
        check(fire_fn == ECHO_FN, "echo handler");
        bus_read(mpy_mmio_addr(MPY_UART_RX), rx);
        check(rx[31], "UART_RX valid");
        check(rx[29:8] == 22'h0, "UART_RX reserved bits stay clear");
        if (rx[30])
            overrun_seen = overrun_seen + 1;
        bus_write(mpy_mmio_addr(MPY_UART_TX), {24'h0, rx[7:0]});
        pulse_done();
    endtask

    task automatic check_echo();
        logic [31:0] value;
        logic [31:0] tx_word;
        do_reset();
        tx_log.delete();
        overrun_seen = 0;
        bus_write(mpy_mmio_addr(MPY_IRQ_ENABLE), 32'h1 << MPY_SRC_UART);
        bus_write(mpy_mmio_addr(MPY_IRQ_HARD), 32'h0);
        bus_write(mpy_mmio_addr(MPY_IRQ_GIE), 32'h1);
        install_handler(MPY_SRC_UART, ECHO_FN, ECHO_ARG);
        push_rx(8'h41);
        service_echo();
        push_rx(8'h42);
        service_echo();
        push_rx(8'h43);
        push_rx(8'h44);
        service_echo();
        tx_word = 32'h0;
        check(tx_log.size() == expect_txn, "echo byte count");
        for (int i = 0; i < tx_log.size(); i++)
            tx_word = tx_word | (32'(tx_log[i]) << (8 * i));
        check(tx_word == 32'(expect_tx_word), "echo bytes");
        check(overrun_seen == expect_overrun, "one overrun recorded");
        bus_read(mpy_mmio_addr(MPY_UART_RX), value);
        check(!value[31], "pop clears data-valid");
        check(value[30], "overrun sticks after the pop");
        check(value[29:8] == 22'h0, "UART_RX reserved bits stay clear");
        check(value[7:0] == 8'h00, "popped buffer is empty");
        bus_write(mpy_mmio_addr(MPY_UART_RX), 32'h1 << 30);
        bus_read(mpy_mmio_addr(MPY_UART_RX), value);
        check(!value[30], "writing bit 30 clears overrun");
        $display("ECHO tx=0x%0h bytes=%0d overrun=%0d",
                 tx_word, tx_log.size(), overrun_seen);
    endtask

    task automatic check_schedule();
        bit          ok;
        bit          full;
        logic [7:0]  occ;
        do_reset();
        for (int n = 1; n < expect_sched_raise; n++) begin
            do_sched(32'(n), 32'h0, ok, full);
            check(ok && !full, "schedule push should fit");
        end
        do_sched(32'(expect_sched_raise), 32'h0, ok, full);
        check(!ok && full, "ninth schedule must raise");
        $display("RuntimeError: schedule queue full");
        read_occ(occ);
        check(occ == 8'd8, "ring stays full after the refused push");
        pulse_boundary();
        check(!fire, "schedule does not run at a non-jump boundary");
        pulse_jump();
        check(fire && fire_sched && !fire_hard, "schedule callback");
        check(!heap_locked && !sched_locked && !irq_active,
              "schedule callback may allocate");
        check(fire_fn == 32'h1, "oldest schedule entry runs");
        pulse_done();
        check(!fire, "one callback returned");
        pulse_jump();
        check(fire && fire_sched && fire_fn == 32'h2, "one callback per jump");
        check(!heap_locked, "second schedule callback may allocate");
        pulse_done();
        read_occ(occ);
        check(occ == 8'd6, "two jumps leave six entries");
    endtask

    task automatic check_hard();
        logic [31:0] value;
        do_reset();
        pc     = 32'h0000_1000;
        fp     = 32'h0000_2000;
        sp     = 32'h0000_3000;
        exc_sp = 32'h0000_4000;
        install_handler(MPY_SRC_TIMER, HARD_FN, HARD_ARG);
        bus_write(mpy_mmio_addr(MPY_TIMER_COUNT), 32'h1);
        bus_write(mpy_mmio_addr(MPY_IRQ_ENABLE), 32'h1 << MPY_SRC_TIMER);
        bus_write(mpy_mmio_addr(MPY_IRQ_HARD), 32'h1 << MPY_SRC_TIMER);
        bus_write(mpy_mmio_addr(MPY_IRQ_GIE), 32'h1);
        step_timer();
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(value[MPY_SRC_TIMER], "hard timer latched");
        idle_clocks(2);
        check(!fire, "hard IRQ waits for a bytecode boundary");
        pulse_boundary();
        check(fire && fire_hard && heap_locked && sched_locked && irq_active,
              "hard IRQ at the boundary locks the heap");
        check(fire_fn == HARD_FN && fire_arg == HARD_ARG, "hard handler");
        check(saved_pc == pc && saved_fp == fp && saved_sp == sp &&
              saved_exc == exc_sp, "hard entry saves the frame");
        bus_read(mpy_mmio_addr(MPY_IRQ_ACTIVE), value);
        check(value[0], "IRQ_ACTIVE while the hard handler runs");
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(!value[MPY_SRC_TIMER], "accepting the hard callback clears status");
        step_timer();
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(value[MPY_SRC_TIMER], "an edge during the callback sets status again");
        pulse_boundary();
        pulse_jump();
        check(fire && fire_hard && heap_locked, "hard handler does not nest");
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(value[MPY_SRC_TIMER], "the new edge stays pending through the handler");
        pulse_done();
        check(!fire && !heap_locked && !sched_locked && !irq_active,
              "hard return unlocks the heap");
        bus_read(mpy_mmio_addr(MPY_IRQ_ACTIVE), value);
        check(!value[0], "IRQ_ACTIVE clears on return");
        idle_clocks(1);
        check(!fire, "the pending edge still waits for a boundary");
        pulse_boundary();
        check(fire && fire_hard && heap_locked, "the edge is taken at the next boundary");
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(!value[MPY_SRC_TIMER], "second accept clears status");
        pulse_done();
        $display("HARD heap_locked=1 at bytecode boundary");
    endtask

    task automatic check_gpio_edge();
        logic [31:0] value;
        do_reset();
        bus_write(mpy_mmio_addr(MPY_GPIO_EDGE), 32'h1);
        bus_write(mpy_mmio_addr(MPY_GPIO_IN), 32'h0);
        bus_write(mpy_mmio_addr(MPY_GPIO_IN), 32'h1);
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(value[MPY_SRC_GPIO], "rising edge sets GPIO status");
        bus_write(mpy_mmio_addr(MPY_GPIO_IN), 32'h0);
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(value[MPY_SRC_GPIO], "falling edge does not match rising mode");
        bus_write(mpy_mmio_addr(MPY_IRQ_STATUS), 32'h1 << MPY_SRC_GPIO);
        bus_write(mpy_mmio_addr(MPY_GPIO_EDGE), 32'h2);
        bus_write(mpy_mmio_addr(MPY_GPIO_IN), 32'h1);
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(!value[MPY_SRC_GPIO], "rising edge does not match falling mode");
        bus_write(mpy_mmio_addr(MPY_GPIO_IN), 32'h0);
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(value[MPY_SRC_GPIO], "falling edge sets GPIO status");
        bus_write(mpy_mmio_addr(MPY_IRQ_STATUS), 32'h1 << MPY_SRC_GPIO);
        bus_write(mpy_mmio_addr(MPY_GPIO_EDGE), 32'h0);
        bus_write(mpy_mmio_addr(MPY_GPIO_IN), 32'h1);
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(!value[MPY_SRC_GPIO], "edge mode off");
        bus_write(mpy_mmio_addr(MPY_GPIO_EDGE), 32'h3);
        bus_write(mpy_mmio_addr(MPY_GPIO_IN), 32'h0);
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(value[MPY_SRC_GPIO], "both-edges mode");
    endtask

    task automatic check_level_sources();
        logic [31:0] value;
        do_reset();
        bus_write(mpy_mmio_addr(MPY_IRQ_ACTIVE), 32'h1);
        bus_write(mpy_mmio_addr(MPY_SCHED_HEAD), 32'h0000_00ff);
        bus_write(mpy_mmio_addr(MPY_SCHED_TAIL), 32'h0000_00ff);
        bus_read(mpy_mmio_addr(MPY_IRQ_ACTIVE), value);
        check(value == 32'h0, "IRQ_ACTIVE ignores stores");
        bus_read(mpy_mmio_addr(MPY_SCHED_HEAD), value);
        check(value == 32'h0, "SCHED_HEAD ignores stores");
        bus_read(mpy_mmio_addr(MPY_SCHED_TAIL), value);
        check(value == 32'h0, "SCHED_TAIL ignores stores");
        pulse_level(MPY_SRC_SIM);
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(value[MPY_SRC_SIM], "SIM stimulus sets status");
        bus_write(mpy_mmio_addr(MPY_IRQ_STATUS), 32'h1 << MPY_SRC_SIM);
        pulse_level(MPY_SRC_SOFT);
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(value[MPY_SRC_SOFT] && !value[MPY_SRC_SIM], "SOFT source");
        bus_write(mpy_mmio_addr(MPY_IRQ_STATUS), 32'h1 << MPY_SRC_SOFT);
        pulse_level(MPY_SRC_GC_REQ);
        bus_read(mpy_mmio_addr(MPY_IRQ_STATUS), value);
        check(value[MPY_SRC_GC_REQ], "GC_REQ source");
        bus_read(mpy_mmio_addr(MPY_IRQ_ACTIVE), value);
        check(value == 32'h0, "IRQ_ACTIVE is clear with no hard handler");
    endtask

    initial begin
        tick_now     = 0;
        overrun_seen = 0;
        got_mask     = 32'h0;
        got_edges    = 0;
        if (!$value$plusargs("BLINK_PERIOD=%d", blink_period)) $fatal(1, "missing BLINK_PERIOD");
        if (!$value$plusargs("BLINK_TICKS=%d", blink_ticks)) $fatal(1, "missing BLINK_TICKS");
        if (!$value$plusargs("EXPECT_EDGES=%d", expect_edges)) $fatal(1, "missing EXPECT_EDGES");
        if (!$value$plusargs("HOLD_COMPARE=%d", hold_compare)) $fatal(1, "missing HOLD_COMPARE");
        if (!$value$plusargs("HOLD_STEPS=%d", hold_steps)) $fatal(1, "missing HOLD_STEPS");
        if (!$value$plusargs("HOLD_IDLE_STEPS=%d", hold_idle_steps)) $fatal(1, "missing HOLD_IDLE_STEPS");
        if (!$value$plusargs("HOLD_COUNT=%d", hold_count)) $fatal(1, "missing HOLD_COUNT");
        if (!$value$plusargs("EXPECT_TX_WORD=%d", expect_tx_word)) $fatal(1, "missing EXPECT_TX_WORD");
        if (!$value$plusargs("EXPECT_TXN=%d", expect_txn)) $fatal(1, "missing EXPECT_TXN");
        if (!$value$plusargs("EXPECT_OVERRUN=%d", expect_overrun)) $fatal(1, "missing EXPECT_OVERRUN");
        if (!$value$plusargs("EXPECT_SCHED_RAISE_AT=%d", expect_sched_raise))
            $fatal(1, "missing EXPECT_SCHED_RAISE_AT");
        if (!$value$plusargs("EXPECT_EDGE_MASK=%d", expect_edge_mask))
            $fatal(1, "missing EXPECT_EDGE_MASK");
        if (!$value$plusargs("EXPECT_OFF_MASK=%d", expect_off_mask))
            $fatal(1, "missing EXPECT_OFF_MASK");
        check(blink_ticks > 0 && blink_ticks <= 32, "blink ticks fit the edge mask");
        check($countones(expect_edge_mask) == expect_edges, "model edge count");

        check_faults_and_table();
        check_timer_hold();
        blink_run(blink_period, blink_ticks, 0, expect_edge_mask);
        blink_run(blink_period, blink_ticks, 3, expect_edge_mask);
        blink_run(0, blink_ticks, 3, expect_off_mask);
        check_gie();
        check_echo();
        check_schedule();
        check_hard();
        check_gpio_edge();
        check_level_sources();

        $display("PASS: mpy periph blink/echo/overrun/schedule");
        $finish;
    end
endmodule
