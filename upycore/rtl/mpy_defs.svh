`ifndef MPY_DEFS_SVH
`define MPY_DEFS_SVH

// Names below are the locked catalog. Current RTL does not read every one.
/* verilator lint_off UNUSEDPARAM */

// MicroPython value encoding (planning/micropython_pivot_plan.md §0.5, §6 item 6).
// One architectural value is a 4-bit tag beside a 32-bit payload. The register
// file is one 36-bit array. SRAM and flash data words stay 32 bits.

localparam int MPY_VAL_WIDTH   = 32;
localparam int MPY_TAG_WIDTH   = 4;
localparam int MPY_ENTRY_WIDTH = MPY_TAG_WIDTH + MPY_VAL_WIDTH; // 36
localparam int MPY_TAG_LSB     = MPY_VAL_WIDTH;                 // 32

// Locked tag table. 0101 stays unassigned.
localparam logic [3:0] MPY_TAG_CONTROL    = 4'b0000;
localparam logic [3:0] MPY_TAG_INT        = 4'b0001;
localparam logic [3:0] MPY_TAG_INT64      = 4'b0010;
localparam logic [3:0] MPY_TAG_FLOAT      = 4'b0011;
localparam logic [3:0] MPY_TAG_COMPLEX    = 4'b0100;
localparam logic [3:0] MPY_TAG_RESERVED   = 4'b0101;
localparam logic [3:0] MPY_TAG_QSTR       = 4'b0110;
localparam logic [3:0] MPY_TAG_SHORT_STR  = 4'b0111;
localparam logic [3:0] MPY_TAG_STR        = 4'b1000;
localparam logic [3:0] MPY_TAG_TUPLE      = 4'b1001;
localparam logic [3:0] MPY_TAG_MUT_COLLEC = 4'b1010;
localparam logic [3:0] MPY_TAG_RANGE      = 4'b1011;
localparam logic [3:0] MPY_TAG_ITER       = 4'b1100;
localparam logic [3:0] MPY_TAG_BYTES      = 4'b1101;
localparam logic [3:0] MPY_TAG_OBJECT     = 4'b1110;
localparam logic [3:0] MPY_TAG_CONT       = 4'b1111;

localparam int MPY_TAG_SPACE = 16;

// CONTROL payload[3:0]. False and True live here, not in their own tags.
localparam logic [3:0] MPY_CTL_EMPTY     = 4'd0;
localparam logic [3:0] MPY_CTL_NONE      = 4'd1;
localparam logic [3:0] MPY_CTL_NULL      = 4'd2; // end of iteration
localparam logic [3:0] MPY_CTL_TOMBSTONE = 4'd3;
localparam logic [3:0] MPY_CTL_FALSE     = 4'd4;
localparam logic [3:0] MPY_CTL_TRUE      = 4'd5;

// MUT_COLLEC kind is the pointer's low 2 bits. The address clears them.
localparam logic [1:0] MPY_MUT_LIST      = 2'd0;
localparam logic [1:0] MPY_MUT_DICT      = 2'd1;
localparam logic [1:0] MPY_MUT_SET       = 2'd2;
localparam logic [1:0] MPY_MUT_BYTEARRAY = 2'd3;

// OBJECT word 0 kinds.
localparam logic [31:0] MPY_OB_INSTANCE     = 32'd1;
localparam logic [31:0] MPY_OB_TYPE         = 32'd2;
localparam logic [31:0] MPY_OB_BOUND_METHOD = 32'd3;
localparam logic [31:0] MPY_OB_BUILTIN      = 32'd4;
localparam logic [31:0] MPY_OB_EXCEPTION    = 32'd6;
localparam logic [31:0] MPY_OB_CELL         = 32'd7;
localparam logic [31:0] MPY_OB_FUNCTION     = 32'd8;
localparam logic [31:0] MPY_OB_MODULE       = 32'd11;

// Wide values. CONT is the extra register, not a value on its own.
localparam int MPY_SPAN_SCALAR    = 1;
localparam int MPY_SPAN_INT64     = 2;
localparam int MPY_SPAN_COMPLEX   = 2;
localparam int MPY_SPAN_SHORT_STR = 4;
localparam int MPY_SHORT_STR_MAX_BYTES = 15;

// Eight tags fill one 32-bit word. Lane 0 is bits [3:0].
localparam int MPY_TAGS_PER_WORD = 8;

// Address windows. There is no DRAM, no L1, and no L2.
// The old 256 KB spill at 0xF40000 is not a window.
localparam logic [31:0] MPY_FLASH_BASE           = 32'h0000_0000;
localparam logic [31:0] MPY_FLASH_BYTES          = 32'h0008_0000; // 512 KB
localparam logic [31:0] MPY_FLASH_RESERVED_BYTES = 32'd8;

localparam logic [31:0] MPY_SRAM_BASE  = 32'h2000_0000;
localparam logic [31:0] MPY_SRAM_BYTES = 32'h0004_0000; // 256 KB

localparam logic [31:0] MPY_MMIO_BASE  = 32'h4000_0000;
localparam logic [31:0] MPY_MMIO_BYTES = 32'h0000_1000; // 4 KB

localparam logic [31:0] MPY_SIM_BASE  = 32'hE000_0000;
localparam logic [31:0] MPY_SIM_BYTES = 32'd256;

localparam int MPY_SRAM_LATENCY       = 1;
localparam int MPY_FLASH_WAIT_STATES  = 1;

localparam int MPY_SRAM_WORDS      = 65536;
localparam int MPY_FLASH_WORDS     = 131072;
localparam int MPY_SRAM_TAG_WORDS  = MPY_SRAM_WORDS / MPY_TAGS_PER_WORD;
localparam int MPY_FLASH_TAG_WORDS = MPY_FLASH_WORDS / MPY_TAGS_PER_WORD;
localparam int MPY_MMIO_WORDS      = 1024;
localparam int MPY_SIM_WORDS       = 64;

// Frame stack: variable-size records back to back (upycore/docs/mpy_core.md).
localparam logic [31:0] MPY_FRAME_RESERVE_BASE  = MPY_SRAM_BASE;
localparam logic [31:0] MPY_FRAME_RESERVE_BYTES = 32'h0000_8000; // 32 KB

// Schedule ring (depth 8) then the handler table, then the GC pool.
localparam int MPY_SCHED_DEPTH       = 8;
localparam int MPY_SCHED_ENTRY_WORDS = 2;
localparam logic [31:0] MPY_SCHED_BASE  = MPY_SRAM_BASE + MPY_FRAME_RESERVE_BYTES;
localparam logic [31:0] MPY_SCHED_BYTES = 32'h0000_0040; // 64 B window, 64 B used

localparam int MPY_IRQ_NSOURCES = 6;
localparam int MPY_IRQ_SRC_TIMER  = 0;
localparam int MPY_IRQ_SRC_UART   = 1;
localparam int MPY_IRQ_SRC_GPIO   = 2;
localparam int MPY_IRQ_SRC_SOFT   = 3;
localparam int MPY_IRQ_SRC_GC_REQ = 4;
localparam int MPY_IRQ_SRC_SIM    = 5;
localparam int MPY_HANDLER_ENTRY_WORDS = 2;
localparam int MPY_HANDLER_USED_BYTES  = MPY_IRQ_NSOURCES * MPY_HANDLER_ENTRY_WORDS * 4; // 48
localparam logic [31:0] MPY_HANDLER_BASE  = MPY_SCHED_BASE + MPY_SCHED_BYTES;
localparam logic [31:0] MPY_HANDLER_BYTES = 32'h0000_0040; // 64 B window, 48 B used

// System roots (32 words) and the argument staging buffer (256 words)
// follow the handler table; upycore/tools/mpy_abi.py is the source.
localparam logic [31:0] MPY_SYSROOT_BASE  = MPY_HANDLER_BASE + MPY_HANDLER_BYTES;
localparam logic [31:0] MPY_ARGBUF_BASE   = MPY_SYSROOT_BASE + 32'h80;
localparam logic [31:0] MPY_GC_POOL_BASE  = MPY_ARGBUF_BASE + 32'h400;
localparam logic [31:0] MPY_GC_POOL_BYTES =
    MPY_SRAM_BYTES - (MPY_GC_POOL_BASE - MPY_SRAM_BASE);

localparam logic [2:0] MPY_REGION_NONE  = 3'd0;
localparam logic [2:0] MPY_REGION_FLASH = 3'd1;
localparam logic [2:0] MPY_REGION_SRAM  = 3'd2;
localparam logic [2:0] MPY_REGION_MMIO  = 3'd3;
localparam logic [2:0] MPY_REGION_SIM   = 3'd4;

localparam logic [3:0] MPY_FAULT_NONE        = 4'd0;
localparam logic [3:0] MPY_FAULT_UNALIGNED   = 4'd1;
localparam logic [3:0] MPY_FAULT_FLASH_STORE = 4'd2;
localparam logic [3:0] MPY_FAULT_BUS         = 4'd3;
localparam logic [3:0] MPY_FAULT_STACK       = 4'd4;
localparam logic [3:0] MPY_FAULT_SPAN        = 4'd5;

// Names for the simulator-control page. This module does not raise them.
localparam logic [3:0] MPY_HALT_CLEAN       = 4'd0;
localparam logic [3:0] MPY_HALT_UNCAUGHT    = 4'd1;
localparam logic [3:0] MPY_HALT_BAD_OPCODE  = 4'd2;
localparam logic [3:0] MPY_HALT_BAD_IMAGE   = 4'd3;
localparam logic [3:0] MPY_HALT_FLASH_STORE = 4'd4;
localparam logic [3:0] MPY_HALT_UNALIGNED   = 4'd5;
localparam logic [3:0] MPY_HALT_BUS         = 4'd6;
localparam logic [3:0] MPY_HALT_STACK       = 4'd7;
localparam logic [3:0] MPY_HALT_STEP        = 4'd8;

// Word offsets from MPY_MMIO_BASE. Side effects are not in mpy_mem.
localparam logic [31:0] MPY_MMIO_UART_TX     = 32'h00;
localparam logic [31:0] MPY_MMIO_UART_RX     = 32'h04;
localparam logic [31:0] MPY_MMIO_GPIO_OUT    = 32'h08;
localparam logic [31:0] MPY_MMIO_TIMER_COUNT = 32'h0C;
localparam logic [31:0] MPY_MMIO_IRQ_STATUS  = 32'h10;
localparam logic [31:0] MPY_MMIO_IRQ_ENABLE  = 32'h14;
localparam logic [31:0] MPY_MMIO_IRQ_HARD    = 32'h18;
localparam logic [31:0] MPY_MMIO_IRQ_GIE     = 32'h1C;
localparam logic [31:0] MPY_MMIO_IRQ_ACTIVE  = 32'h20;
localparam logic [31:0] MPY_MMIO_IRQ_TABLE   = 32'h24;
localparam logic [31:0] MPY_MMIO_SCHED_HEAD  = 32'h28;
localparam logic [31:0] MPY_MMIO_SCHED_TAIL  = 32'h2C;
localparam logic [31:0] MPY_MMIO_GPIO_IN     = 32'h30;
localparam logic [31:0] MPY_MMIO_GPIO_EDGE   = 32'h34;

/* verilator lint_on UNUSEDPARAM */

function automatic logic [MPY_ENTRY_WIDTH-1:0] mpy_make_entry(
    input logic [MPY_TAG_WIDTH-1:0] tag,
    input logic [MPY_VAL_WIDTH-1:0] payload
);
    mpy_make_entry = {tag, payload};
endfunction

function automatic logic [MPY_TAG_WIDTH-1:0] mpy_entry_tag(
    input logic [MPY_ENTRY_WIDTH-1:0] entry
);
    mpy_entry_tag = entry[MPY_ENTRY_WIDTH-1:MPY_TAG_LSB];
endfunction

function automatic logic [MPY_VAL_WIDTH-1:0] mpy_entry_payload(
    input logic [MPY_ENTRY_WIDTH-1:0] entry
);
    mpy_entry_payload = entry[MPY_VAL_WIDTH-1:0];
endfunction

function automatic logic [MPY_ENTRY_WIDTH-1:0] mpy_make_control(
    input logic [3:0] kind
);
    mpy_make_control = mpy_make_entry(MPY_TAG_CONTROL, {28'b0, kind});
endfunction

// Physical registers occupied by a head tag. Reserved occupies none.
// CONT itself is one register: the extra entry of a wide value.
function automatic logic [2:0] mpy_tag_span(
    input logic [MPY_TAG_WIDTH-1:0] tag
);
    case (tag)
        MPY_TAG_INT64, MPY_TAG_COMPLEX: mpy_tag_span = 3'(MPY_SPAN_INT64);
        MPY_TAG_SHORT_STR:              mpy_tag_span = 3'(MPY_SPAN_SHORT_STR);
        MPY_TAG_RESERVED:               mpy_tag_span = 3'd0;
        default:                        mpy_tag_span = 3'(MPY_SPAN_SCALAR);
    endcase
endfunction

// Collector rule: follow a word only when the nibble is a pointer tag.
// CONTROL (including False and True), INT, INT64, FLOAT, COMPLEX, QSTR,
// SHORT_STR, CONT, and the reserved code are not pointers.
function automatic logic mpy_tag_is_pointer(
    input logic [MPY_TAG_WIDTH-1:0] tag
);
    case (tag)
        MPY_TAG_STR, MPY_TAG_TUPLE, MPY_TAG_MUT_COLLEC,
        MPY_TAG_RANGE, MPY_TAG_ITER, MPY_TAG_BYTES, MPY_TAG_OBJECT:
            mpy_tag_is_pointer = 1'b1;
        default:
            mpy_tag_is_pointer = 1'b0;
    endcase
endfunction

function automatic logic mpy_control_is_bool(
    input logic [MPY_VAL_WIDTH-1:0] payload
);
    mpy_control_is_bool = (payload[3:0] == MPY_CTL_FALSE) ||
                          (payload[3:0] == MPY_CTL_TRUE);
endfunction

// Arithmetic and dict hashing use False as int 0 and True as int 1.
function automatic logic [MPY_VAL_WIDTH-1:0] mpy_bool_as_int(
    input logic [MPY_VAL_WIDTH-1:0] payload
);
    mpy_bool_as_int = (payload[3:0] == MPY_CTL_TRUE) ? 32'd1 : 32'd0;
endfunction

function automatic logic [31:0] mpy_mut_payload(
    input logic [1:0] kind,
    input logic [31:0] addr
);
    mpy_mut_payload = {addr[31:2], kind};
endfunction

function automatic logic [31:0] mpy_mut_addr(
    input logic [31:0] payload
);
    mpy_mut_addr = {payload[31:2], 2'b00};
endfunction

function automatic logic [1:0] mpy_mut_kind(
    input logic [31:0] payload
);
    mpy_mut_kind = payload[1:0];
endfunction

function automatic logic [MPY_ENTRY_WIDTH-1:0] mpy_make_mut(
    input logic [1:0] kind,
    input logic [31:0] addr
);
    mpy_make_mut = mpy_make_entry(MPY_TAG_MUT_COLLEC, mpy_mut_payload(kind, addr));
endfunction

// Address a collector follows. MUT_COLLEC clears the low 2 bits first.
function automatic logic [31:0] mpy_pointer_addr(
    input logic [MPY_TAG_WIDTH-1:0] tag,
    input logic [MPY_VAL_WIDTH-1:0] payload
);
    if (tag == MPY_TAG_MUT_COLLEC)
        mpy_pointer_addr = mpy_mut_addr(payload);
    else
        mpy_pointer_addr = payload;
endfunction

function automatic logic [31:0] mpy_nibble_write(
    input logic [31:0] word,
    input logic [2:0]  lane,
    input logic [3:0]  nibble
);
    logic [31:0] mask;
    logic [31:0] bits;
    begin
        mask = ~(32'h0000_000F << {lane, 2'b00});
        bits = {28'b0, nibble} << {lane, 2'b00};
        mpy_nibble_write = (word & mask) | bits;
    end
endfunction

function automatic logic [3:0] mpy_nibble_read(
    input logic [31:0] word,
    input logic [2:0]  lane
);
    logic [31:0] shifted;
    begin
        shifted = word >> {lane, 2'b00};
        mpy_nibble_read = shifted[3:0];
    end
endfunction

function automatic logic [2:0] mpy_region_of(
    input logic [31:0] addr
);
    // Flash starts at 0, so the base compare is the size compare.
    if (addr < MPY_FLASH_BYTES)
        mpy_region_of = MPY_REGION_FLASH;
    else if ((addr >= MPY_SRAM_BASE) && ((addr - MPY_SRAM_BASE) < MPY_SRAM_BYTES))
        mpy_region_of = MPY_REGION_SRAM;
    else if ((addr >= MPY_MMIO_BASE) && ((addr - MPY_MMIO_BASE) < MPY_MMIO_BYTES))
        mpy_region_of = MPY_REGION_MMIO;
    else if ((addr >= MPY_SIM_BASE) && ((addr - MPY_SIM_BASE) < MPY_SIM_BYTES))
        mpy_region_of = MPY_REGION_SIM;
    else
        mpy_region_of = MPY_REGION_NONE;
endfunction

function automatic logic mpy_flash_addr_reserved(
    input logic [31:0] addr
);
    mpy_flash_addr_reserved = (addr < MPY_FLASH_RESERVED_BYTES);
endfunction

function automatic logic [15:0] mpy_sram_word_index(
    input logic [31:0] addr
);
    mpy_sram_word_index = 16'((addr - MPY_SRAM_BASE) >> 2);
endfunction

function automatic logic [16:0] mpy_flash_word_index(
    input logic [31:0] addr
);
    mpy_flash_word_index = 17'((addr - MPY_FLASH_BASE) >> 2);
endfunction

// SHORT_STR: length in the first payload's low byte, then up to 15 bytes
// across that register and three CONT registers. The first register holds
// bytes 0..2 after the length. Each CONT register holds the next four.
function automatic logic [31:0] mpy_short_str_word(
    input logic [7:0]  nbytes,
    input logic [119:0] bytes,
    input logic [1:0]  which
);
    logic [7:0] b [0:14];
    integer i;
    begin
        for (i = 0; i < 15; i = i + 1)
            b[i] = bytes[8*i +: 8];
        case (which)
            2'd0: mpy_short_str_word = {b[2], b[1], b[0], nbytes};
            2'd1: mpy_short_str_word = {b[6], b[5], b[4], b[3]};
            2'd2: mpy_short_str_word = {b[10], b[9], b[8], b[7]};
            default: mpy_short_str_word = {b[14], b[13], b[12], b[11]};
        endcase
    end
endfunction

`endif
