`include "mpy_defs.svh"
`include "mpy_abi.svh"

// uPyCore system: mpy_core, mpy_gc and mpy_mem on one memory port.
//
// The collector owns the port while it is busy; the core only waits on an
// allocation or a collection then, so the two never contend. Core accesses
// to the simulator-control page (ABI_SIM_BASE) are answered here: a store to
// SIM_STDOUT or SIM_STDERR emits the low byte on the console port, a store to
// SIM_HALT stops the core's clock-enable view through halt_o, and a load of
// SIM_CYCLES returns the cycle counter. Everything else goes to mpy_mem.
module mpy_soc #(
    parameter int SRAM_LATENCY = MPY_SRAM_LATENCY,
    parameter int FLASH_WAIT_STATES = MPY_FLASH_WAIT_STATES
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    output logic        con_valid_o,
    output logic        con_err_o,
    output logic [7:0]  con_byte_o,

    output logic        halted_o,
    output logic [3:0]  halt_code_o,
    output logic [31:0] halt_value_o,
    output logic [31:0] cycles_o,
    output logic [31:0] ops_o,
    output logic [31:0] gc_collections_o,
    output logic [31:0] gc_free_o,

    output logic        trace_o,
    output logic [31:0] trace_pc_o,
    output logic [7:0]  trace_op_o,
    output logic [6:0]  trace_sp_o
);
    // core <-> port
    logic        c_req, c_we, c_tag_we;
    logic [3:0]  c_be, c_wtag;
    logic [31:0] c_addr, c_wdata;
    logic        c_ack, c_fault;
    logic [31:0] c_rdata;
    logic [3:0]  c_rtag, c_fault_reason;

    // core <-> gc
    logic        g_alloc_req, g_alloc_done, g_alloc_ok, g_collect_req, g_collect_done;
    logic [31:0] g_alloc_nbytes, g_alloc_addr;
    logic [31:0] g_r0lo, g_r0hi, g_r1lo, g_r1hi;
    logic [31:0] g_free, g_total, g_coll, g_ovf;
    logic        g_busy;

    // gc <-> port
    logic        gm_req, gm_we, gm_tag_we, gm_ack;
    logic [31:0] gm_addr, gm_wdata, gm_rdata;
    logic [3:0]  gm_wtag, gm_rtag;

    // memory
    logic        m_req, m_we, m_tag_we, m_ack, m_fault;
    logic [3:0]  m_be, m_wtag, m_rtag, m_fault_reason;
    logic [31:0] m_addr, m_wdata, m_rdata;

    logic        core_halted;
    logic [3:0]  core_hcode;
    logic [31:0] core_hval, core_cycles;

    mpy_core u_core (
        .clk_i, .rst_n_i,
        .m_req_o(c_req), .m_we_o(c_we), .m_tag_we_o(c_tag_we), .m_be_o(c_be),
        .m_addr_o(c_addr), .m_wdata_o(c_wdata), .m_wtag_o(c_wtag),
        .m_ack_i(c_ack), .m_rdata_i(c_rdata), .m_rtag_i(c_rtag),
        .m_fault_i(c_fault), .m_fault_reason_i(c_fault_reason),
        .gc_alloc_req_o(g_alloc_req), .gc_alloc_nbytes_o(g_alloc_nbytes),
        .gc_alloc_done_i(g_alloc_done), .gc_alloc_ok_i(g_alloc_ok), .gc_alloc_addr_i(g_alloc_addr),
        .gc_collect_req_o(g_collect_req),
        .gc_root0_lo_o(g_r0lo), .gc_root0_hi_o(g_r0hi),
        .gc_root1_lo_o(g_r1lo), .gc_root1_hi_o(g_r1hi),
        .gc_collect_done_i(g_collect_done),
        .gc_free_i(g_free), .gc_total_i(g_total), .gc_collections_i(g_coll),
        .halted_o(core_halted), .halt_code_o(core_hcode), .halt_value_o(core_hval),
        .cycles_o(core_cycles), .ops_o,
        .trace_o, .trace_pc_o, .trace_op_o, .trace_sp_o
    );

    mpy_gc #(
        .POOL_BASE(ABI_GC_POOL_BASE),
        .POOL_BYTES(ABI_GC_POOL_BYTES)
    ) u_gc (
        .clk_i, .rst_n_i,
        .alloc_req_i(g_alloc_req), .alloc_nbytes_i(g_alloc_nbytes),
        .alloc_done_o(g_alloc_done), .alloc_ok_o(g_alloc_ok), .alloc_addr_o(g_alloc_addr),
        .collect_req_i(g_collect_req),
        .root0_lo_i(g_r0lo), .root0_hi_i(g_r0hi), .root1_lo_i(g_r1lo), .root1_hi_i(g_r1hi),
        .collect_done_o(g_collect_done),
        .busy_o(g_busy), .free_blocks_o(g_free), .total_blocks_o(g_total),
        .collections_o(g_coll), .overflows_o(g_ovf),
        .mem_req_o(gm_req), .mem_we_o(gm_we), .mem_tag_we_o(gm_tag_we),
        .mem_addr_o(gm_addr), .mem_wdata_o(gm_wdata), .mem_wtag_o(gm_wtag),
        .mem_ack_i(gm_ack), .mem_rdata_i(gm_rdata), .mem_rtag_i(gm_rtag)
    );

    mpy_mem #(
        .FLASH_WAIT_STATES(FLASH_WAIT_STATES),
        .SRAM_LATENCY(SRAM_LATENCY)
    ) u_mem (
        .clk_i, .rst_n_i,
        .req_i(m_req), .we_i(m_we), .tag_we_i(m_tag_we), .be_i(m_be),
        .addr_i(m_addr), .wdata_i(m_wdata), .wtag_i(m_wtag),
        .ack_o(m_ack), .rdata_o(m_rdata), .rtag_o(m_rtag),
        .fault_o(m_fault), .fault_reason_o(m_fault_reason)
    );

    // Sim-page decode for core requests.
    logic c_sim;
    assign c_sim = (mpy_region_of(c_addr) == MPY_REGION_SIM);

    logic        sim_ack;
    logic [31:0] sim_rdata;
    logic        sim_halt;
    logic [31:0] sim_halt_val;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            sim_ack <= 1'b0; sim_rdata <= 32'd0;
            con_valid_o <= 1'b0; con_err_o <= 1'b0; con_byte_o <= 8'd0;
            sim_halt <= 1'b0; sim_halt_val <= 32'd0;
        end else begin
            sim_ack <= 1'b0;
            con_valid_o <= 1'b0;
            if (c_req && c_sim) begin
                sim_ack <= 1'b1;
                sim_rdata <= 32'd0;
                if (c_we) begin
                    case ((c_addr - ABI_SIM_BASE) >> 2)
                        32'(ABI_SIM_STDOUT): begin con_valid_o <= 1'b1; con_err_o <= 1'b0; con_byte_o <= c_wdata[7:0]; end
                        32'(ABI_SIM_STDERR): begin con_valid_o <= 1'b1; con_err_o <= 1'b1; con_byte_o <= c_wdata[7:0]; end
                        32'(ABI_SIM_HALT): begin sim_halt <= 1'b1; sim_halt_val <= c_wdata; end
                        default: ;
                    endcase
                end else if (((c_addr - ABI_SIM_BASE) >> 2) == 32'(ABI_SIM_CYCLES)) begin
                    sim_rdata <= core_cycles;
                end
            end
        end
    end

    // Port mux: the collector while busy, else the core (sim page excluded).
    always_comb begin
        if (g_busy) begin
            m_req = gm_req; m_we = gm_we; m_tag_we = gm_tag_we; m_be = 4'hF;
            m_addr = gm_addr; m_wdata = gm_wdata; m_wtag = gm_wtag;
        end else begin
            m_req = c_req && !c_sim; m_we = c_we; m_tag_we = c_tag_we; m_be = c_be;
            m_addr = c_addr; m_wdata = c_wdata; m_wtag = c_wtag;
        end
    end
    assign gm_ack = g_busy && m_ack;
    assign gm_rdata = m_rdata;
    assign gm_rtag = m_rtag;
    assign c_ack = (!g_busy && m_ack) || sim_ack;
    assign c_rdata = sim_ack ? sim_rdata : m_rdata;
    assign c_rtag = sim_ack ? 4'd0 : m_rtag;
    assign c_fault = !sim_ack && m_fault;
    assign c_fault_reason = m_fault_reason;

    assign halted_o = core_halted || sim_halt;
    assign halt_code_o = core_halted ? core_hcode : ABI_HALT_SYSEXIT;
    assign halt_value_o = core_halted ? core_hval : sim_halt_val;
    assign cycles_o = core_cycles;
    assign gc_collections_o = g_coll;
    assign gc_free_o = g_free;

    logic unused;
    assign unused = ^{g_total, g_ovf};
endmodule
