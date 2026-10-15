// Shared map for the v1 peripheral block.
// Spec: upycore/docs/mpy_peripherals.md
package mpy_mmio_pkg;
    localparam int MPY_NSRC        = 6;
    localparam int MPY_SCHED_DEPTH = 8;

    localparam int MPY_SRC_TIMER  = 0;
    localparam int MPY_SRC_UART   = 1;
    localparam int MPY_SRC_GPIO   = 2;
    localparam int MPY_SRC_SOFT   = 3;
    localparam int MPY_SRC_GC_REQ = 4;
    localparam int MPY_SRC_SIM    = 5;

    localparam logic [31:0] MPY_MMIO_BASE = 32'h4000_0000;

    localparam logic [11:0] MPY_UART_TX     = 12'h000;
    localparam logic [11:0] MPY_UART_RX     = 12'h004;
    localparam logic [11:0] MPY_GPIO_OUT    = 12'h008;
    localparam logic [11:0] MPY_TIMER_COUNT = 12'h00C;
    localparam logic [11:0] MPY_IRQ_STATUS  = 12'h010;
    localparam logic [11:0] MPY_IRQ_ENABLE  = 12'h014;
    localparam logic [11:0] MPY_IRQ_HARD    = 12'h018;
    localparam logic [11:0] MPY_IRQ_GIE     = 12'h01C;
    localparam logic [11:0] MPY_IRQ_ACTIVE  = 12'h020;
    localparam logic [11:0] MPY_IRQ_TABLE   = 12'h024;
    localparam logic [11:0] MPY_SCHED_HEAD  = 12'h028;
    localparam logic [11:0] MPY_SCHED_TAIL  = 12'h02C;
    localparam logic [11:0] MPY_GPIO_IN     = 12'h030;
    localparam logic [11:0] MPY_GPIO_EDGE   = 12'h034;

    // One schedule-ring slot. is_sched distinguishes micropython.schedule
    // from a device IRQ that was queued for soft delivery.
    typedef struct packed {
        logic        is_sched;
        logic [2:0]  src;
        logic [31:0] arg;
        logic [31:0] fn;
    } mpy_sched_entry_t;

    function automatic logic [31:0] mpy_mmio_addr(input logic [11:0] off);
        mpy_mmio_addr = MPY_MMIO_BASE + {20'h0, off};
    endfunction

    function automatic logic [7:0] mpy_sched_occ(
        input logic [7:0] head,
        input logic [7:0] tail
    );
        mpy_sched_occ = tail - head;
    endfunction
endpackage
