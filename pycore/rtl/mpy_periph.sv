// UART, GPIO, timer, and the IRQ register file.
// Spec: pycore/docs/mpy_peripherals.md
//
// The six draft offsets are unchanged. Added registers start at 0x18.
// UART_RX is one byte: a load pops it, and a second byte sets sticky
// overrun bit 30 and is dropped. TIMER_COUNT advances on timer_step.
// Compare 0 disables the timer. mpy_irq clears a source when its
// callback is accepted.
module mpy_periph
    import mpy_mmio_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_n_i,

    input  logic        req_i,
    input  logic        we_i,
    input  logic [31:0] addr_i,
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output logic        ack_o,
    output logic        fault_o,

    input  logic        timer_step_i,
    input  logic        uart_rx_stb_i,
    input  logic [7:0]  uart_rx_byte_i,
    output logic        uart_tx_stb_o,
    output logic [7:0]  uart_tx_byte_o,
    output logic [31:0] gpio_out_o,

    input  logic        soft_set_i,
    input  logic        gc_req_i,
    input  logic        sim_set_i,

    input  logic        bc_boundary_i,
    input  logic        jump_i,
    input  logic        done_i,

    output logic        fire_o,
    output logic        fire_hard_o,
    output logic        fire_sched_o,
    output logic [2:0]  fire_src_o,
    output logic [31:0] fire_fn_o,
    output logic [31:0] fire_arg_o,
    output logic        heap_locked_o,
    output logic        sched_locked_o,
    output logic        irq_active_o,

    input  logic        handler_we_i,
    input  logic [2:0]  handler_idx_i,
    input  logic [31:0] handler_fn_i,
    input  logic [31:0] handler_arg_i,

    input  logic        sched_push_i,
    input  logic [31:0] sched_fn_i,
    input  logic [31:0] sched_arg_i,
    output logic        sched_ok_o,
    output logic        sched_full_o,

    input  logic [31:0] pc_i,
    input  logic [31:0] fp_i,
    input  logic [31:0] sp_i,
    input  logic [31:0] exc_sp_i,
    output logic [31:0] saved_pc_o,
    output logic [31:0] saved_fp_o,
    output logic [31:0] saved_sp_o,
    output logic [31:0] saved_exc_sp_o
);
    logic [11:0] off;
    logic        in_window;
    logic        aligned;
    logic        req_ok;

    logic wr_tx, wr_rx, wr_gout, wr_tc, wr_stat, wr_en, wr_hard, wr_gie;
    logic wr_table, wr_gin, wr_gedge, rd_rx;

    logic [31:0] gpio_out_r, gpio_in_r, gpio_edge_r;
    logic [31:0] compare_r, count_r;
    logic [7:0]  rx_byte_r, tx_byte_r;
    logic        rx_valid_r, overrun_r;
    logic [MPY_NSRC-1:0] status_r, enable_r, hard_r;
    logic        gie_r;
    logic [31:0] irq_table_r;

    logic [32:0] count_inc;
    logic        timer_match;
    logic        uart_take;
    logic        uart_drop;
    logic        gpio_hit;
    logic [MPY_NSRC-1:0] event_set;
    logic [MPY_NSRC-1:0] accept_clr;
    logic [MPY_NSRC-1:0] w1c;
    logic [MPY_NSRC-1:0] status_n;
    logic [7:0]          sched_head;
    logic [7:0]          sched_tail;

    assign off = addr_i[11:0];
    assign in_window = (addr_i[31:12] == 20'h00000) ||
                       (addr_i[31:12] == MPY_MMIO_BASE[31:12]);
    assign aligned = (addr_i[1:0] == 2'b00);
    assign fault_o = req_i && (!aligned || !in_window);
    assign req_ok  = req_i && aligned && in_window;
    assign ack_o   = req_ok;

    assign wr_tx    = req_ok && we_i && (off == MPY_UART_TX);
    assign wr_rx    = req_ok && we_i && (off == MPY_UART_RX);
    assign wr_gout  = req_ok && we_i && (off == MPY_GPIO_OUT);
    assign wr_tc    = req_ok && we_i && (off == MPY_TIMER_COUNT);
    assign wr_stat  = req_ok && we_i && (off == MPY_IRQ_STATUS);
    assign wr_en    = req_ok && we_i && (off == MPY_IRQ_ENABLE);
    assign wr_hard  = req_ok && we_i && (off == MPY_IRQ_HARD);
    assign wr_gie   = req_ok && we_i && (off == MPY_IRQ_GIE);
    assign wr_table = req_ok && we_i && (off == MPY_IRQ_TABLE);
    assign wr_gin   = req_ok && we_i && (off == MPY_GPIO_IN);
    assign wr_gedge = req_ok && we_i && (off == MPY_GPIO_EDGE);
    assign rd_rx    = req_ok && !we_i && (off == MPY_UART_RX);

    assign gpio_out_o    = gpio_out_r;
    assign uart_tx_stb_o = wr_tx;
    assign uart_tx_byte_o = wr_tx ? wdata_i[7:0] : tx_byte_r;

    assign count_inc = {1'b0, count_r} + 33'd1;
    assign timer_match = timer_step_i && (compare_r != 32'h0) &&
                         (count_inc >= {1'b0, compare_r});
    assign uart_take = uart_rx_stb_i && !rx_valid_r;
    assign uart_drop = uart_rx_stb_i && rx_valid_r;
    assign gpio_hit  = wr_gin && gpio_edge_hit(gpio_edge_r, gpio_in_r, wdata_i);

    assign event_set[MPY_SRC_TIMER]  = timer_match;
    assign event_set[MPY_SRC_UART]   = uart_take;
    assign event_set[MPY_SRC_GPIO]   = gpio_hit;
    assign event_set[MPY_SRC_SOFT]   = soft_set_i;
    assign event_set[MPY_SRC_GC_REQ] = gc_req_i;
    assign event_set[MPY_SRC_SIM]    = sim_set_i;

    assign w1c = wr_stat ? wdata_i[MPY_NSRC-1:0] : '0;
    // The event that is accepted this cycle is cleared with the status
    // bit. A later event, while the callback is already running, has
    // accept_clr low and sets the bit again.
    assign status_n = (status_r & ~w1c & ~accept_clr) | (event_set & ~accept_clr);

    mpy_irq u_irq (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .status_i(status_r),
        .event_set_i(event_set),
        .enable_i(enable_r),
        .hard_i(hard_r),
        .gie_i(gie_r),
        .accept_clr_o(accept_clr),
        .bc_boundary_i(bc_boundary_i),
        .jump_i(jump_i),
        .done_i(done_i),
        .fire_o(fire_o),
        .fire_hard_o(fire_hard_o),
        .fire_sched_o(fire_sched_o),
        .fire_src_o(fire_src_o),
        .fire_fn_o(fire_fn_o),
        .fire_arg_o(fire_arg_o),
        .heap_locked_o(heap_locked_o),
        .sched_locked_o(sched_locked_o),
        .irq_active_o(irq_active_o),
        .handler_we_i(handler_we_i),
        .handler_idx_i(handler_idx_i),
        .handler_fn_i(handler_fn_i),
        .handler_arg_i(handler_arg_i),
        .sched_push_i(sched_push_i),
        .sched_fn_i(sched_fn_i),
        .sched_arg_i(sched_arg_i),
        .sched_ok_o(sched_ok_o),
        .sched_full_o(sched_full_o),
        .sched_head_o(sched_head),
        .sched_tail_o(sched_tail),
        .pc_i(pc_i),
        .fp_i(fp_i),
        .sp_i(sp_i),
        .exc_sp_i(exc_sp_i),
        .saved_pc_o(saved_pc_o),
        .saved_fp_o(saved_fp_o),
        .saved_sp_o(saved_sp_o),
        .saved_exc_sp_o(saved_exc_sp_o)
    );

    function automatic logic gpio_edge_hit(
        input logic [31:0] edge_cfg,
        input logic [31:0] old_in,
        input logic [31:0] new_in
    );
        logic [15:0] rose;
        logic [15:0] fell;
        logic        hit;
        rose = ~old_in[15:0] & new_in[15:0];
        fell = old_in[15:0] & ~new_in[15:0];
        hit  = 1'b0;
        for (int i = 0; i < 16; i++) begin
            case (edge_cfg[2*i +: 2])
                2'd1: hit = hit | rose[i];
                2'd2: hit = hit | fell[i];
                2'd3: hit = hit | rose[i] | fell[i];
                default: hit = hit;
            endcase
        end
        gpio_edge_hit = hit;
    endfunction

    always_comb begin
        rdata_o = 32'h0;
        if (req_ok && !we_i) begin
            case (off)
                MPY_UART_TX:     rdata_o = {24'h0, tx_byte_r};
                MPY_UART_RX:     rdata_o = {rx_valid_r, overrun_r, 22'h0, rx_byte_r};
                MPY_GPIO_OUT:    rdata_o = gpio_out_r;
                MPY_TIMER_COUNT: rdata_o = count_r;
                MPY_IRQ_STATUS:  rdata_o = {{(32-MPY_NSRC){1'b0}}, status_r};
                MPY_IRQ_ENABLE:  rdata_o = {{(32-MPY_NSRC){1'b0}}, enable_r};
                MPY_IRQ_HARD:    rdata_o = {{(32-MPY_NSRC){1'b0}}, hard_r};
                MPY_IRQ_GIE:     rdata_o = {31'h0, gie_r};
                MPY_IRQ_ACTIVE:  rdata_o = {31'h0, irq_active_o};
                MPY_IRQ_TABLE:   rdata_o = irq_table_r;
                MPY_SCHED_HEAD:  rdata_o = {24'h0, sched_head};
                MPY_SCHED_TAIL:  rdata_o = {24'h0, sched_tail};
                MPY_GPIO_IN:     rdata_o = gpio_in_r;
                MPY_GPIO_EDGE:   rdata_o = gpio_edge_r;
                default:         rdata_o = 32'h0;
            endcase
        end
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            gpio_out_r  <= 32'h0;
            gpio_in_r   <= 32'h0;
            gpio_edge_r <= 32'h0;
            compare_r   <= 32'h0;
            count_r     <= 32'h0;
            rx_byte_r   <= 8'h0;
            tx_byte_r   <= 8'h0;
            rx_valid_r  <= 1'b0;
            overrun_r   <= 1'b0;
            status_r    <= '0;
            enable_r    <= '0;
            hard_r      <= '0;
            gie_r       <= 1'b1;
            irq_table_r <= 32'h0;
        end else begin
            if (wr_gout)
                gpio_out_r <= wdata_i;
            if (wr_gin)
                gpio_in_r <= wdata_i;
            if (wr_gedge)
                gpio_edge_r <= wdata_i;
            if (wr_tc)
                compare_r <= wdata_i;
            if (wr_en)
                enable_r <= wdata_i[MPY_NSRC-1:0];
            if (wr_hard)
                hard_r <= wdata_i[MPY_NSRC-1:0];
            if (wr_gie)
                gie_r <= wdata_i[0];
            if (wr_table)
                irq_table_r <= wdata_i;

            if (timer_match)
                count_r <= 32'h0;
            else if (timer_step_i && (compare_r != 32'h0))
                count_r <= count_inc[31:0];

            if (wr_tx)
                tx_byte_r <= wdata_i[7:0];

            // A byte that arrives while the buffer is full is dropped.
            // A same-cycle load loses to the new byte so the push is kept.
            if (uart_take) begin
                rx_valid_r <= 1'b1;
                rx_byte_r  <= uart_rx_byte_i;
            end else if (rd_rx && rx_valid_r) begin
                rx_valid_r <= 1'b0;
                rx_byte_r  <= 8'h0;
            end

            if (wr_rx && wdata_i[30])
                overrun_r <= 1'b0;
            if (uart_drop)
                overrun_r <= 1'b1;

            status_r <= status_n;
        end
    end
endmodule
