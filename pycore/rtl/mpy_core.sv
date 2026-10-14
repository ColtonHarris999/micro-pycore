// uPyCore execution core: runs MicroPython v1.29.0 bytecode from a linked
// flash image (pycore/tools/mpy_link.py) against the ABI in mpy_abi.svh.
//
// One frame is live in registers: the value stack and locals (rf), the
// exception-block stack (xh/xv/xf/xp), and the frame header fields. A call
// spills the caller to its frame record in SRAM and builds the callee's
// record above it; a return or an unwinding exception refills the caller.
//
// The core handles the common shapes of every opcode itself: small and
// long-long ints and binary32 floats, str/qstr equality and hashing, list,
// tuple, dict and set access, attribute lookup through instance dicts and
// type MROs, calls of bytecode functions with plain positional binding,
// bound methods, natives, instance creation, and exception unwinding with
// tracebacks. Anything else is a call into a firmware hook (HOOKS in the ABI):
// the core marshals the operands, calls the hook like any Python function,
// and a return kind (RK) or continuation (CONT) says what to do with the
// result. Firmware frames carry RC_FLAG_FIRMWARE and add no traceback lines.
//
// Subroutines use a small return-state stack (rstk). Raising an exception
// resets it: an exception abandons whatever microcode was in flight.
//
// Every heap value that must survive an allocation sits in rf, ab, the frame
// header, t[0..7], or xc. Before a collection the core spills all of them to
// the frame record, ARGBUF, and SYSROOT, which the collector scans as roots.

`include "mpy_defs.svh"
`include "mpy_abi.svh"

/* verilator lint_off WIDTH */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off BLKSEQ */
module mpy_core
    import mpy_dec::*;
    import mpy_alu_pkg::*;
#(
    parameter int RSTK_DEPTH = 16
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    output logic        m_req_o,
    output logic        m_we_o,
    output logic        m_tag_we_o,
    output logic [3:0]  m_be_o,
    output logic [31:0] m_addr_o,
    output logic [31:0] m_wdata_o,
    output logic [3:0]  m_wtag_o,
    input  logic        m_ack_i,
    input  logic [31:0] m_rdata_i,
    input  logic [3:0]  m_rtag_i,
    input  logic        m_fault_i,
    input  logic [3:0]  m_fault_reason_i,

    output logic        gc_alloc_req_o,
    output logic [31:0] gc_alloc_nbytes_o,
    input  logic        gc_alloc_done_i,
    input  logic        gc_alloc_ok_i,
    input  logic [31:0] gc_alloc_addr_i,
    output logic        gc_collect_req_o,
    output logic [31:0] gc_root0_lo_o,
    output logic [31:0] gc_root0_hi_o,
    output logic [31:0] gc_root1_lo_o,
    output logic [31:0] gc_root1_hi_o,
    input  logic        gc_collect_done_i,
    input  logic [31:0] gc_free_i,
    input  logic [31:0] gc_total_i,
    input  logic [31:0] gc_collections_i,

    output logic        halted_o,
    output logic [3:0]  halt_code_o,
    output logic [31:0] halt_value_o,
    output logic [31:0] cycles_o,
    output logic [31:0] ops_o,
    output logic        trace_o,
    output logic [31:0] trace_pc_o,
    output logic [7:0]  trace_op_o,
    output logic [6:0]  trace_sp_o
);
    typedef logic [35:0] val_t;

    localparam val_t VNULL  = {ABI_TAG_CONTROL, ABI_CTL_NULL};
    localparam val_t VNONE  = {ABI_TAG_CONTROL, ABI_CTL_NONE};
    localparam val_t VSTOP  = {ABI_TAG_CONTROL, ABI_CTL_STOP};
    localparam val_t VTOMB  = {ABI_TAG_CONTROL, ABI_CTL_TOMB};
    localparam val_t VFALSE = {ABI_TAG_CONTROL, ABI_CTL_FALSE};
    localparam val_t VTRUE  = {ABI_TAG_CONTROL, ABI_CTL_TRUE};

    localparam logic [31:0] TT = 32'(ABI_TYPE_TABLE);
    localparam logic [31:0] EMERG_ADDR = ABI_SYSROOT_BASE + 4 * ABI_SR_EMERG;
    localparam logic [31:0] HASH_NONE = 32'd6;
    localparam logic [7:0]  FF_FW = 8'h01;
    localparam logic [7:0]  FF_NOTB = 8'h80;

    localparam logic [1:0] LK_FIND = 2'd0;
    localparam logic [1:0] LK_ADD = 2'd1;
    localparam logic [1:0] LK_REMOVE = 2'd2;

    // ------------------------------------------------------------------
    // Value helpers
    // ------------------------------------------------------------------
    function automatic logic [3:0] tg(input val_t v); tg = v[35:32]; endfunction
    function automatic logic [31:0] adr(input val_t v); adr = {v[31:2], 2'b00}; endfunction
    function automatic val_t vint(input logic [31:0] x); vint = {ABI_TAG_INT, x}; endfunction
    function automatic val_t vobj(input logic [31:0] x); vobj = {ABI_TAG_OBJECT, x}; endfunction
    function automatic val_t vbool(input logic b); vbool = b ? VTRUE : VFALSE; endfunction
    function automatic val_t vmut(input logic [31:0] a, input logic [1:0] k); vmut = {ABI_TAG_MUT, a[31:2], k}; endfunction
    function automatic logic is_bool(input val_t v); is_bool = (v == VTRUE) || (v == VFALSE); endfunction
    function automatic logic intlike(input val_t v); intlike = (tg(v) == ABI_TAG_INT) || is_bool(v); endfunction
    function automatic logic numlike(input val_t v);
        numlike = intlike(v) || tg(v) == ABI_TAG_INT64 || tg(v) == ABI_TAG_FLOAT;
    endfunction
    function automatic logic [31:0] ival(input val_t v);
        ival = is_bool(v) ? {31'd0, v == VTRUE} : v[31:0];
    endfunction
    function automatic logic strlike(input val_t v);
        strlike = (tg(v) == ABI_TAG_QSTR) || (tg(v) == ABI_TAG_STR);
    endfunction
    function automatic logic is_mut(input val_t v, input logic [1:0] k);
        is_mut = (tg(v) == ABI_TAG_MUT) && (v[1:0] == k);
    endfunction
    function automatic logic [31:0] sx31(input logic [31:0] x); sx31 = {x[30], x[30:0]}; endfunction
    function automatic logic fits31(input logic [63:0] x);
        fits31 = (x[63:30] == {34{1'b0}}) || (x[63:30] == {34{1'b1}});
    endfunction
    function automatic logic fits32(input logic [63:0] x);
        fits32 = (x[63:31] == {33{1'b0}}) || (x[63:31] == {33{1'b1}});
    endfunction
    // Address of a pointer value; an INT is taken as a raw address.
    function automatic logic [31:0] padr(input val_t v);
        padr = (tg(v) == ABI_TAG_INT) ? v[31:0] : adr(v);
    endfunction
    function automatic logic [7:0] byte_of(input logic [31:0] w, input logic [1:0] i);
        byte_of = w[8*i +: 8];
    endfunction

    // MicroPython's mp_map growth sequence (py/map.c).
    function automatic logic [31:0] next_alloc(input logic [31:0] x);
        logic [31:0] t [0:33];
        logic [31:0] r;
        t = '{0, 2, 4, 6, 8, 10, 12, 17, 23, 29, 37, 47, 59, 73, 97, 127, 167, 223, 293, 389,
              521, 691, 919, 1223, 1627, 2161, 3229, 4831, 7243, 10861, 16273, 24407, 36607, 54907};
        r = (x + (x >> 1)) | 32'd1;
        for (int i = 33; i >= 0; i--) if (t[i] >= x) r = t[i];
        next_alloc = r;
    endfunction

    function automatic logic [7:0] msg_type(input logic [7:0] id);
        case (id)
            ABI_MSG_RECURSION: msg_type = ABI_MSGT_RECURSION;
            ABI_MSG_DIV_ZERO: msg_type = ABI_MSGT_DIV_ZERO;
            ABI_MSG_OVERFLOW: msg_type = ABI_MSGT_OVERFLOW;
            ABI_MSG_LIST_INDEX: msg_type = ABI_MSGT_LIST_INDEX;
            ABI_MSG_TUPLE_INDEX: msg_type = ABI_MSGT_TUPLE_INDEX;
            ABI_MSG_STR_INDEX: msg_type = ABI_MSGT_STR_INDEX;
            ABI_MSG_LOCAL_UNBOUND: msg_type = ABI_MSGT_LOCAL_UNBOUND;
            ABI_MSG_NEG_SHIFT: msg_type = ABI_MSGT_NEG_SHIFT;
            ABI_MSG_NO_ACTIVE_EXC: msg_type = ABI_MSGT_NO_ACTIVE_EXC;
            ABI_MSG_ZERO_STEP: msg_type = ABI_MSGT_ZERO_STEP;
            ABI_MSG_STOP_ITER: msg_type = ABI_MSGT_STOP_ITER;
            ABI_MSG_MEMORY: msg_type = ABI_MSGT_MEMORY;
            ABI_MSG_ASSERT: msg_type = ABI_MSGT_ASSERT;
            ABI_MSG_BYTES_INDEX: msg_type = ABI_MSGT_BYTES_INDEX;
            ABI_MSG_RANGE_INDEX: msg_type = ABI_MSGT_RANGE_INDEX;
            ABI_MSG_POP_EMPTY: msg_type = ABI_MSGT_POP_EMPTY;
            ABI_MSG_HEAP_LOCKED: msg_type = ABI_MSGT_HEAP_LOCKED;
            ABI_MSG_SCHED_FULL: msg_type = ABI_MSGT_SCHED_FULL;
            ABI_MSG_KBD: msg_type = ABI_MSGT_KBD;
            default: msg_type = ABI_MSGT_EMPTY;
        endcase
    endfunction

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    typedef enum logic [9:0] {
        S_BOOT,
        S_HALT,
        S_MWAIT,
        S_AL,
        S_AL_OOM,
        S_AL_OOM2,
        S_AL_RT,
        S_AL_W,
        S_AT,
        S_AT_ID,
        S_AT_IDR,
        S_AT_K,
        S_AT_M1,
        S_AT_M2,
        S_AT_MD2,
        S_AT_ML,
        S_AT_MOD,
        S_AT_MODR,
        S_AT_MR,
        S_AT_MRO,
        S_AT_MT,
        S_AT_NT,
        S_AT_T1,
        S_AT_VK,
        S_BF,
        S_BF_DEF,
        S_BF_DEF2,
        S_BF_VA,
        S_BF_VA2,
        S_BIN,
        S_BIN_FB,
        S_BL_A,
        S_BL_L,
        S_BM_A,
        S_BOOT1,
        S_BOOT10,
        S_BOOT11,
        S_BOOT12,
        S_BOOT13,
        S_BOOT14,
        S_BOOT15,
        S_BOOT16,
        S_BOOT2,
        S_BOOT3,
        S_BOOT4,
        S_BOOT5,
        S_BOOT6,
        S_BOOT7,
        S_BOOT8,
        S_BOOT9,
        S_BS,
        S_BS1,
        S_BS2,
        S_BSET_R,
        S_BT_R,
        S_CALL,
        S_CALL_BF,
        S_CALL_BS,
        S_CALL_K,
        S_CALL_MN,
        S_CALL_NI,
        S_CALL_TF,
        S_CB_A,
        S_CB_C,
        S_CB_L,
        S_CB_N,
        S_CB_V,
        S_CELLS,
        S_CELL_A,
        S_CELL_I,
        S_CF,
        S_CF1,
        S_CF2,
        S_CF3,
        S_CF4,
        S_CF_ARGS,
        S_CF_C,
        S_CF_CHK,
        S_CF_CLI,
        S_CF_CLN,
        S_CF_CLP,
        S_CF_MD,
        S_CF_PC,
        S_CF_Q,
        S_CF_SIG,
        S_CF_SIG2,
        S_CF_SW,
        S_CNS,
        S_CONT,
        S_CVK_E,
        S_CVK_I,
        S_CVK_L,
        S_CVK_N,
        S_CVK_P,
        S_CVK_V,
        S_DADDR,
        S_DADDR_M,
        S_DADDR_R,
        S_DEC,
        S_DELDEREF,
        S_DELIVER,
        S_DEREF,
        S_DN_R,
        S_EQ,
        S_EQ_S,
        S_EXEC,
        S_EXM,
        S_EXM_R,
        S_EXM_T,
        S_EXM_TI,
        S_EXM_TL,
        S_EXM_TN,
        S_EXM_TR,
        S_FETCH,
        S_FILL,
        S_FI_AT,
        S_FI_DONE,
        S_FI_LD,
        S_FI_LD2,
        S_FI_R,
        S_FI_W1,
        S_FL_H,
        S_FL_R,
        S_FL_X,
        S_FL_X0,
        S_FW,
        S_GC,
        S_GC_1,
        S_GC_AB,
        S_GC_T,
        S_GC_W,
        S_GI,
        S_GI_AT,
        S_GI_FB,
        S_GI_K,
        S_GI_R0,
        S_GI_R1,
        S_GI_R2,
        S_GI_S,
        S_GI_V0,
        S_GI_V1,
        S_HASH,
        S_HASH_I64,
        S_HASH_OBJ,
        S_HASH_W16,
        S_HC1,
        S_HC2,
        S_HCALL,
        S_HOOK,
        S_HOOK1,
        S_IN,
        S_IN_R,
        S_ISSUB,
        S_IS_C,
        S_IS_L,
        S_IS_M,
        S_IS_N,
        S_IT,
        S_IT_BB,
        S_IT_BL,
        S_IT_DA,
        S_IT_DI,
        S_IT_DK,
        S_IT_DL,
        S_IT_DT,
        S_IT_DV,
        S_IT_LI,
        S_IT_SC,
        S_IT_SL,
        S_IT_V,
        S_JT,
        S_KEYEQ,
        S_KE_A0,
        S_KE_A1,
        S_KE_B0,
        S_KE_B1,
        S_KE_OBJ,
        S_KE_S,
        S_LA,
        S_LA_A,
        S_LA_BM,
        S_LA_CP,
        S_LA_CP2,
        S_LA_G,
        S_LA_G2,
        S_LA_G3,
        S_LA_G4,
        S_LA_I,
        S_LA_INC,
        S_LA_N,
        S_LA_R,
        S_LA_RET,
        S_LCO,
        S_LCS,
        S_LK,
        S_LK_AL,
        S_LK_DEC,
        S_LK_FL,
        S_LK_H,
        S_LK_HIT,
        S_LK_INC,
        S_LK_INS,
        S_LK_INS2,
        S_LK_INS3,
        S_LK_K,
        S_LK_KE,
        S_LK_NX,
        S_LK_P,
        S_LK_RET,
        S_LK_RH,
        S_LK_RM,
        S_LK_RM2,
        S_LK_RM3,
        S_LK_RM4,
        S_LK_RV,
        S_LK_TB,
        S_LK_V,
        S_LN_L,
        S_LN_R,
        S_LSUB,
        S_LS_D,
        S_LS_FB,
        S_LS_IT,
        S_LS_LEN,
        S_LS_PUT,
        S_LS_S,
        S_LS_SB,
        S_LS_SC,
        S_MF_A,
        S_MF_C,
        S_MF_CL,
        S_MF_R,
        S_NAT,
        S_NAT_FB,
        S_NAT_FB1,
        S_NAT_FB2,
        S_NEW,
        S_NEW_I,
        S_NEW_INIT,
        S_NEW_IR,
        S_NEW_X,
        S_NEW_XA,
        S_NUM,
        S_NUM_AH,
        S_NUM_AL,
        S_NUM_B,
        S_NUM_BH,
        S_NUM_BL,
        S_NUM_BOX,
        S_NUM_GO,
        S_NUM_PUT,
        S_NUM_W,
        S_N_ALLOC,
        S_N_BC,
        S_N_BC1,
        S_N_BC2,
        S_N_BC3,
        S_N_BCA,
        S_N_BCB,
        S_N_BCL,
        S_N_BCMP1,
        S_N_BCMP2,
        S_N_BEI,
        S_N_DATA,
        S_N_FTOI,
        S_N_FTOI_B,
        S_N_FTOI_W,
        S_N_HASH,
        S_N_IN_D,
        S_N_IN_LD,
        S_N_IN_LD2,
        S_N_IN_R,
        S_N_IN_W,
        S_N_ISI,
        S_N_ISI2,
        S_N_ISI3,
        S_N_LEN_S,
        S_N_LOOKUP,
        S_N_NONE,
        S_N_OBJ,
        S_N_PEEK8,
        S_N_RANGE,
        S_N_RINT,
        S_N_RV,
        S_N_SF0,
        S_N_SF1,
        S_N_SF2,
        S_N_SFB,
        S_N_SFL,
        S_N_STRNEW,
        S_N_STRNEW2,
        S_N_TYPEOF,
        S_N_WC,
        S_N_WC2,
        S_N_WR,
        S_N_WRB,
        S_N_WRL,
        S_QOP,
        S_RAISE,
        S_RET,
        S_RET_D,
        S_RH,
        S_RH_A,
        S_RH_A2,
        S_RH_A3,
        S_RH_F1,
        S_RH_F2,
        S_RH_F3,
        S_RH_H,
        S_RH_K,
        S_RH_L,
        S_RH_NX,
        S_RH_P,
        S_RH_PK,
        S_RH_V,
        S_RH_V2,
        S_RMSG,
        S_RMSG1,
        S_RMSG2,
        S_RMSG3,
        S_RMSG4,
        S_ROBJ,
        S_ROBJ_K,
        S_ROBJ_T,
        S_RX_H,
        S_RX_POP,
        S_RX_SI,
        S_RX_SI2,
        S_RX_TB,
        S_RX_TB1,
        S_RX_TB2,
        S_RX_TBA,
        S_RX_TBB,
        S_RX_TBC,
        S_RX_TBL,
        S_RX_TBN,
        S_SA,
        S_SA_D,
        S_SA_FB,
        S_SA_K,
        S_SA_ND,
        S_SA_NL,
        S_SA_NL2,
        S_SA_R,
        S_SA_TF,
        S_SA_TY,
        S_SC_D,
        S_SC_L,
        S_SC_S,
        S_SE1,
        S_SE2,
        S_SEA,
        S_SEB,
        S_SEL,
        S_SINFO,
        S_SI_Q0,
        S_SI_Q1,
        S_SI_S0,
        S_SI_S1,
        S_SI_S2,
        S_SLICE_A,
        S_SN_R,
        S_SPILL,
        S_SP_H,
        S_SP_R,
        S_SP_X,
        S_SSUB,
        S_SS_D,
        S_SS_FB,
        S_SS_IT,
        S_SS_LEN,
        S_STM_R,
        S_STREQ,
        S_SW_E,
        S_SW_X,
        S_TR,
        S_TR_F,
        S_TR_LEN,
        S_TR_T,
        S_TUP,
        S_TUP_A,
        S_TUP_L,
        S_TYPEOF,
        S_TYPEOF_SET,
        S_TYPEOF_TT,
        S_UJ,
        S_UJ_L,
        S_UN,
        S_UPK_L,
        S_UPK_N,
        S_UPK_V,
        S_UPS_L,
        S_UPS_N,
        S_UPS_P,
        S_UPS_V,
        S_UR,
        S_WB,
        S_WC,
        S_WC_T,
        S_WC_TR
    } state_e;

    state_e st, wret;
    state_e rstk [0:RSTK_DEPTH-1];
    logic [4:0] rsp;

    // memory port
    logic        m_req, m_we, m_tag_we;
    logic [3:0]  m_be, m_wtag;
    logic [31:0] m_addr, m_wdata;
    logic [31:0] md;
    logic [3:0]  mt;
    val_t mv;
    assign mv = {mt, md};

    // image constants
    logic [31:0] h_qdesc, h_builtins, h_hooks, h_msgs, h_chars, h_empty;
    val_t ty_fun, ty_bm, ty_cell, ty_obj, ty_stop, ty_mem, ty_slice;

    // live frame
    logic [31:0] fbase, fprev, rc, pc, op_pc, qbase, cbase;
    logic [6:0]  sp, nst;
    logic [4:0]  xsp, nexc;
    logic [7:0]  fflags, fcont;
    logic [3:0]  frk;
    val_t glb, loc, fun, aux, aux2, aux3;
    val_t rf [0:63];
    logic [31:0] xh [0:15];
    logic [6:0]  xv [0:15];
    logic        xf [0:15];
    val_t        xp [0:15];
    logic        noframe;

    // current instruction
    logic [7:0]  op, ext;
    logic [31:0] arg, jt;
    logic [1:0]  ovr;

    // call staging: ab[0] is the callable, args from ab_lo, kw pairs from ab_pe
    val_t ab [0:255];
    logic [7:0] ab_lo, ab_pe, ab_nkw;
    logic [3:0] crk, d_rk, r_rk;
    val_t cl_loc;
    logic [7:0] hk_id, nid;

    // GC-visible temporaries
    val_t t [0:7];
    val_t xc;

    // halting / counters
    logic        halted;
    logic [3:0]  hcode;
    logic [31:0] hval, cyc, nops;
    logic        trace;

    // fetch window
    logic [95:0] fwin;
    logic [31:0] fw_base;
    logic        fw_ok;
    logic [1:0]  fw_i;

    // scratch
    logic [31:0] x0, x1, x2, x3, x4;
    logic [7:0]  i0, i1, i2;
    logic [6:0]  s0, s1;
    logic        b0, b1;

    // subroutine registers
    val_t        ty_v, ty_t;                       // TYPEOF
    val_t        hk; logic [31:0] hh; logic hok;   // HASH
    val_t        si_v; logic [31:0] si_len, si_hash, si_addr; logic si_na;  // SINFO
    val_t        se_a, se_b; logic se_eq; logic [31:0] se_len, se_hash, se_pa, se_pb, se_i, se_w;
    val_t        ke_a, ke_b; logic ke_eq, ke_cx; logic [31:0] ke_w0, ke_w1;
    logic [1:0]  lk_mode; logic lk_set, lk_found, lk_cx, lk_ro;
    val_t        lk_res;
    logic [31:0] lk_alloc, lk_tab, lk_pos, lk_start, lk_avail, lk_slot;
    logic        lk_hasav;
    logic [31:0] rh_alloc, rh_tab, rh_i, rh_p, rh_used;
    val_t        rh_k;
    logic [31:0] al_n, al_a; logic al_ok, al_soft, al_gc;
    logic [31:0] la_len, la_alloc, la_items, la_new, la_i;
    logic [31:0] sw_i; logic [1:0] sw_k;
    logic [31:0] fl_base, fl_i; logic [1:0] fl_k;
    logic [31:0] gi;
    val_t        is_t, is_c; logic is_r; logic [31:0] is_m, is_n, is_i;
    logic [31:0] at_q, at_m, at_n, at_i; logic [1:0] at_kind; logic at_ty, at_objd;
    val_t        at_v, at_t; logic [31:0] at_k;
    val_t        tr_v; logic tr_r, tr_x;
    logic        tb_src, tb_nz; logic [7:0] tb_from, tb_n, tb_i; logic [31:0] tb_a; val_t tb_v;
    val_t        wb_v [0:7]; logic [31:0] wb_a; logic [3:0] wb_n, wb_i;
    val_t        iv [0:3]; logic it_stop, it_py, it_h; val_t it_val; logic [31:0] it_i, it_alloc, it_tab;
    logic [31:0] c_rc, c_md, c_cells, c_tflags;
    val_t        c_clos, c_defs, c_glob;
    logic [7:0]  c_nst, c_nexc, c_scope, c_rcf, c_npos, c_nkwo, c_ndef, c_ncell, c_cn;
    logic        c_fast, c_ismod;
    logic [31:0] c_ci;
    logic        rx_from; logic [3:0] rx_crk; logic [31:0] rx_off;
    logic [7:0]  rm_id;
    logic [31:0] uj;
    logic [7:0]  cv_i, cv_n, cv_j; logic [31:0] cv_bm, cv_items; logic [6:0] cv_base, cv_fidx;

    // ALU
    logic        alu_start, alu_done;
    logic [5:0]  alu_op;
    logic        na_f, nb_f, n_small, n_un;
    logic [63:0] na, nb, alu_res;
    logic [1:0]  alu_kind;
    logic [2:0]  alu_err;
    logic [7:0]  n_o;

    mpy_alu u_alu (
        .clk_i, .rst_n_i, .start_i(alu_start), .op_i(alu_op),
        .a_flt_i(na_f), .b_flt_i(nb_f), .a_i(na), .b_i(nb), .small_i(n_small),
        .done_o(alu_done), .res_o(alu_res), .rkind_o(alu_kind), .err_o(alu_err)
    );

    // decoder over the fetch window
    logic [31:0] f_off;
    logic [63:0] d_bytes;
    logic [3:0]  d_n;
    logic        d_valid, d_illegal, d_trunc, d_ovf, d_argv, d_extv;
    logic [3:0]  d_len;
    logic [7:0]  d_op, d_ext;
    logic [1:0]  d_fmt;
    entry_e      d_entry;
    logic signed [31:0] d_arg;
    logic        in_win;
    assign f_off = pc - fw_base;
    assign in_win = fw_ok && (pc >= fw_base) && (f_off < 32'd12);
    assign d_bytes = 64'(fwin >> {f_off[3:0], 3'b000});
    assign d_n = (f_off[3:0] > 4'd4) ? 4'(4'd12 - f_off[3:0]) : 4'd8;

    mpy_decode u_dec (
        .instr_valid_i(1'b1), .bytes_i(d_bytes), .nbytes_i(d_n),
        .decoded_valid_o(d_valid), .illegal_o(d_illegal), .truncated_o(d_trunc),
        .arg_overflow_o(d_ovf), .len_o(d_len), .opcode_o(d_op), .format_o(d_fmt),
        .entry_o(d_entry), .arg_valid_o(d_argv), .arg_o(d_arg),
        .extra_valid_o(d_extv), .extra_o(d_ext)
    );

    // frame geometry
    logic [31:0] ftop;
    assign ftop = fbase + ((32'd16 + nst + 32'd3 * nexc) << 2);
`define LI(n) (6'(nst - 7'd1 - 7'(n)))

    function automatic val_t hdr_word(input logic [31:0] i);
        case (i[3:0])
            4'd0: hdr_word = {4'd0, fprev};
            4'd1: hdr_word = {4'd0, rc};
            4'd2: hdr_word = {4'd0, pc};
            4'd3: hdr_word = {4'd0, op_pc};
            4'd4: hdr_word = {4'd0, fflags, 1'b0, nst, 3'b000, xsp, 1'b0, sp};
            4'd5: hdr_word = {4'd0, 11'd0, nexc, fcont, 4'd0, frk};
            4'd6: hdr_word = glb;
            4'd7: hdr_word = loc;
            4'd8: hdr_word = fun;
            4'd9: hdr_word = aux;
            4'd10: hdr_word = aux2;
            4'd11: hdr_word = aux3;
            4'd12: hdr_word = {4'd0, qbase};
            4'd13: hdr_word = {4'd0, cbase};
            default: hdr_word = VNULL;
        endcase
    endfunction

    assign m_req_o = m_req;
    assign m_we_o = m_we;
    assign m_tag_we_o = m_tag_we;
    assign m_be_o = m_be;
    assign m_addr_o = m_addr;
    assign m_wdata_o = m_wdata;
    assign m_wtag_o = m_wtag;
    assign gc_alloc_nbytes_o = al_n << 2;
    assign gc_root0_lo_o = ABI_FRAME_BASE;
    assign gc_root0_hi_o = noframe ? ABI_FRAME_BASE : ftop;
    assign gc_root1_lo_o = ABI_SCHED_BASE;
    assign gc_root1_hi_o = ABI_GC_POOL_BASE;
    assign halted_o = halted;
    assign halt_code_o = hcode;
    assign halt_value_o = hval;
    assign cycles_o = cyc;
    assign ops_o = nops;
    assign trace_o = trace;
    assign trace_pc_o = op_pc;
    assign trace_op_o = op;
    assign trace_sp_o = sp;

    logic gc_alloc_req, gc_collect_req;
    assign gc_alloc_req_o = gc_alloc_req;
    assign gc_collect_req_o = gc_collect_req;

    // ------------------------------------------------------------------
    // Microcode helpers
    // ------------------------------------------------------------------
    task automatic rd(input logic [31:0] a, input state_e nxt);
        m_addr <= a; m_we <= 1'b0; m_tag_we <= 1'b0; m_be <= 4'hF; m_req <= 1'b1;
        wret <= nxt; st <= S_MWAIT;
    endtask
    task automatic wr(input logic [31:0] a, input val_t v, input state_e nxt);
        m_addr <= a; m_wdata <= v[31:0]; m_wtag <= v[35:32];
        m_we <= 1'b1; m_tag_we <= 1'b1; m_be <= 4'hF; m_req <= 1'b1;
        wret <= nxt; st <= S_MWAIT;
    endtask
    task automatic wrb(input logic [31:0] a, input logic [7:0] b, input state_e nxt);
        m_addr <= {a[31:2], 2'b00}; m_wdata <= {4{b}}; m_wtag <= 4'd0;
        m_we <= 1'b1; m_tag_we <= 1'b0; m_be <= 4'b0001 << a[1:0]; m_req <= 1'b1;
        wret <= nxt; st <= S_MWAIT;
    endtask
    task automatic gosub(input state_e target, input state_e back);
        rstk[rsp] <= back; rsp <= rsp + 5'd1; st <= target;
    endtask
    task automatic ret();
        st <= rstk[rsp - 5'd1]; rsp <= rsp - 5'd1;
    endtask
    task automatic halt(input logic [3:0] code, input logic [31:0] value);
        halted <= 1'b1; hcode <= code; hval <= value; st <= S_HALT;
    endtask
    task automatic push(input val_t v);
        rf[sp[5:0]] <= v; sp <= sp + 7'd1;
    endtask
    task automatic raise_msg(input logic [7:0] id);
        rm_id <= id; rsp <= 5'd0; st <= S_RMSG;
    endtask
    task automatic raise_val(input val_t v);
        xc <= v; rx_from <= 1'b0; rsp <= 5'd0; st <= S_RAISE;
    endtask
    task automatic raise_err(input logic [7:0] code, input val_t a, input val_t b);
        ab[32] <= vint({24'd0, code}); ab[33] <= a; ab[34] <= b;
        ab_lo <= 8'd32; ab_pe <= 8'd35; ab_nkw <= 8'd0; crk <= ABI_RK_PUSH;
        hk_id <= ABI_HOOK_RAISE; rsp <= 5'd0; st <= S_HOOK;
    endtask
    // Call hook `id` with n positional args; the result is delivered by rk.
    task automatic hook(input logic [7:0] id, input logic [3:0] rk, input logic [7:0] n,
                        input val_t a, input val_t b, input val_t c, input val_t d);
        ab[32] <= a; ab[33] <= b; ab[34] <= c; ab[35] <= d;
        ab_lo <= 8'd32; ab_pe <= 8'd32 + n; ab_nkw <= 8'd0; crk <= rk;
        hk_id <= id; st <= S_HOOK;
    endtask
    // Call ab[0] with ab args prepared; result by rk.
    task automatic deliver(input val_t v, input logic [3:0] rk);
        t[7] <= v; d_rk <= rk; st <= S_DELIVER;
    endtask
    task automatic wblock(input logic [31:0] a, input logic [3:0] n, input state_e back);
        wb_a <= a; wb_n <= n; wb_i <= 4'd0; gosub(S_WB, back);
    endtask
    task automatic lookup(input val_t d, input val_t key, input val_t val, input logic [1:0] mode,
                          input logic set, input state_e back);
        t[4] <= d; t[5] <= key; t[6] <= val; lk_mode <= mode; lk_set <= set;
        gosub(S_LK, back);
    endtask
    task automatic alloc(input logic [31:0] n, input state_e back);
        al_n <= (n == 32'd0) ? 32'd1 : n; gosub(S_AL, back);
    endtask
    task automatic exc_push(input logic [31:0] handler, input logic fin, input logic [6:0] vsp);
        xh[xsp[3:0]] <= handler; xv[xsp[3:0]] <= vsp; xf[xsp[3:0]] <= fin; xp[xsp[3:0]] <= VNULL;
        xsp <= xsp + 5'd1;
    endtask

    // ------------------------------------------------------------------
    // Main sequencer
    // ------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_n_i) begin : seq
        logic [31:0] v0, v1, v2, v3;
        logic [7:0]  vi;
        logic [6:0]  vs0, vs1;
        logic        vb;
        if (!rst_n_i) begin
            st <= S_BOOT;
            rsp <= 5'd0;
            m_req <= 1'b0; m_we <= 1'b0; m_tag_we <= 1'b0; m_be <= 4'hF;
            m_addr <= 32'd0; m_wdata <= 32'd0; m_wtag <= 4'd0;
            gc_alloc_req <= 1'b0; gc_collect_req <= 1'b0;
            alu_start <= 1'b0;
            halted <= 1'b0; hcode <= 4'd0; hval <= 32'd0;
            cyc <= 32'd0; nops <= 32'd0; trace <= 1'b0;
            fw_ok <= 1'b0; fw_base <= 32'd0;
            sp <= 7'd0; nst <= 7'd0; xsp <= 5'd0; nexc <= 5'd0;
            noframe <= 1'b1; ovr <= ABI_OVR_NONE;
            cl_loc <= VNULL; al_soft <= 1'b0;
            fflags <= 8'd0; fcont <= 8'd0; frk <= ABI_RK_HALT;
            fbase <= ABI_FRAME_BASE; fprev <= 32'd0;
            for (int k = 0; k < 8; k++) t[k] <= VNULL;
            xc <= VNULL;
            for (int k = 0; k < 64; k++) rf[k] <= VNULL;
        end else begin
            m_req <= 1'b0;
            gc_alloc_req <= 1'b0;
            gc_collect_req <= 1'b0;
            alu_start <= 1'b0;
            trace <= 1'b0;
            if (!halted) cyc <= cyc + 32'd1;

            case (st)
            S_HALT: ;

            S_MWAIT: if (m_ack_i) begin
                md <= m_rdata_i; mt <= m_rtag_i;
                if (m_fault_i) begin
                    case (m_fault_reason_i)
                        MPY_FAULT_UNALIGNED: halt(ABI_HALT_UNALIGNED, m_addr);
                        MPY_FAULT_FLASH_STORE: halt(ABI_HALT_FLASH_STORE, m_addr);
                        default: halt(ABI_HALT_BUS, m_addr);
                    endcase
                end else st <= wret;
            end

            // ---------------- boot ----------------
            S_BOOT: rd(32'd0, S_BOOT1);
            S_BOOT1: if (md != ABI_IMAGE_MAGIC) halt(ABI_HALT_BAD_IMAGE, md);
                     else rd(4 * ABI_HDR_QSTR_DESC, S_BOOT2);
            S_BOOT2: begin h_qdesc <= md; rd(4 * ABI_HDR_BUILTINS, S_BOOT3); end
            S_BOOT3: begin h_builtins <= md; rd(4 * ABI_HDR_HOOKS, S_BOOT4); end
            S_BOOT4: begin h_hooks <= md; rd(4 * ABI_HDR_MSGS, S_BOOT5); end
            S_BOOT5: begin h_msgs <= md; rd(4 * ABI_HDR_CHARS, S_BOOT6); end
            S_BOOT6: begin h_chars <= md; rd(4 * ABI_HDR_EMPTY_TUPLE, S_BOOT7); end
            S_BOOT7: begin h_empty <= md; rd(TT + 4 * ABI_T_FUNCTION, S_BOOT8); end
            S_BOOT8: begin ty_fun <= mv; rd(TT + 4 * ABI_T_BOUND_METHOD, S_BOOT9); end
            S_BOOT9: begin ty_bm <= mv; rd(TT + 4 * ABI_T_CELL, S_BOOT10); end
            S_BOOT10: begin ty_cell <= mv; rd(TT + 4 * ABI_T_OBJECT, S_BOOT11); end
            S_BOOT11: begin ty_obj <= mv; rd(TT + 4 * ABI_T_STOPITERATION, S_BOOT12); end
            S_BOOT12: begin ty_stop <= mv; rd(TT + 4 * ABI_T_MEMORYERROR, S_BOOT13); end
            S_BOOT13: begin ty_mem <= mv; rd(TT + 4 * ABI_T_SLICE, S_BOOT14); end
            S_BOOT14: begin ty_slice <= mv; rd(h_msgs + 4 * ABI_MSG_MEMORY, S_BOOT15); end
            S_BOOT15: begin
                wb_v[0] <= vint(ABI_OB_EXCEPTION); wb_v[1] <= ty_mem; wb_v[2] <= mv;
                wb_v[3] <= VNULL; wb_v[4] <= VNULL;
                wblock(EMERG_ADDR, 4'd5, S_BOOT16);
            end
            S_BOOT16: begin
                ab_lo <= 8'd32; ab_pe <= 8'd32; ab_nkw <= 8'd0; crk <= ABI_RK_HALT;
                hk_id <= ABI_HOOK_BOOT; st <= S_HOOK;
            end

            // ---------------- hooks and calls ----------------
            S_HOOK: rd(h_hooks + 4 * hk_id, S_HOOK1);
            S_HOOK1: if (mv == VNULL) halt(ABI_HALT_INTERNAL, {24'd0, hk_id});
                     else begin ab[0] <= mv; st <= S_CALL; end

            S_CALL: if (tg(ab[0]) != ABI_TAG_OBJECT) st <= S_HCALL;
                    else rd(adr(ab[0]), S_CALL_K);
            S_CALL_K: begin
                case (md)
                    ABI_OB_FUNCTION: begin c_ismod <= 1'b0; st <= S_CF; end
                    ABI_OB_BOUND_METHOD: rd(adr(ab[0]) + 12, S_CALL_BS);
                    ABI_OB_BUILTIN: rd(adr(ab[0]) + 8, S_CALL_NI);
                    ABI_OB_TYPE: rd(adr(ab[0]) + 28, S_CALL_TF);
                    default: st <= S_HCALL;
                endcase
            end
            S_CALL_BS: if (ab_lo <= 8'd2) raise_err(ABI_ERR_STAR_ARGS, VNULL, VNULL);
                       else begin
                           ab[ab_lo - 8'd1] <= mv; ab_lo <= ab_lo - 8'd1;
                           rd(adr(ab[0]) + 8, S_CALL_BF);
                       end
            S_CALL_BF: begin ab[0] <= mv; st <= S_CALL; end
            S_CALL_NI: begin nid <= md[7:0]; st <= S_NAT; end
            S_CALL_TF: begin
                c_tflags <= md;
                if (md & ABI_TF_INST) st <= S_NEW;
                else rd(adr(ab[0]) + 32, S_CALL_MN);
            end
            S_CALL_MN: if (mv == VNULL) raise_err(ABI_ERR_CANT_CREATE, ab[0], VNULL);
                       else if (ab_lo <= 8'd2) raise_err(ABI_ERR_STAR_ARGS, VNULL, VNULL);
                       else begin
                           ab[ab_lo - 8'd1] <= ab[0]; ab_lo <= ab_lo - 8'd1;
                           ab[0] <= mv; st <= S_CALL;
                       end

            // Anything else callable goes through _call(obj, args, kw).
            S_HCALL: begin
                tb_src <= 1'b0; tb_nz <= 1'b0; tb_from <= ab_lo; tb_n <= ab_pe - ab_lo;
                gosub(S_TUP, S_HC1);
            end
            S_HC1: begin
                t[0] <= tb_v; tb_src <= 1'b0; tb_nz <= 1'b1; tb_from <= ab_pe; tb_n <= {ab_nkw[6:0], 1'b0};
                gosub(S_TUP, S_HC2);
            end
            S_HC2: hook(ABI_HOOK_CALL, crk, 8'd3, ab[0], t[0], tb_v, VNULL);

            // Instance of a class with TF_INST.
            S_NEW: if (c_tflags & ABI_TF_EXC) begin
                       tb_src <= 1'b0; tb_nz <= 1'b0; tb_from <= ab_lo; tb_n <= ab_pe - ab_lo;
                       gosub(S_TUP, S_NEW_X);
                   end else alloc(32'd3, S_NEW_I);
            S_NEW_X: begin t[0] <= tb_v; alloc(32'd5, S_NEW_XA); end
            S_NEW_XA: begin
                wb_v[0] <= vint(ABI_OB_EXCEPTION); wb_v[1] <= ab[0]; wb_v[2] <= t[0];
                wb_v[3] <= VNULL; wb_v[4] <= VNULL;
                t[1] <= vobj(al_a);
                wblock(al_a, 4'd5, S_NEW_INIT);
            end
            S_NEW_I: begin
                wb_v[0] <= vint(ABI_OB_INSTANCE); wb_v[1] <= ab[0]; wb_v[2] <= VNULL;
                t[1] <= vobj(al_a);
                wblock(al_a, 4'd3, S_NEW_INIT);
            end
            S_NEW_INIT: begin
                at_t <= ab[0]; at_ty <= 1'b1; at_objd <= 1'b0; at_q <= ABI_Q_INIT_D;
                gosub(S_AT_MRO, S_NEW_IR);
            end
            S_NEW_IR: if (at_kind == 2'd1) begin
                    ab[ab_lo - 8'd1] <= t[1]; ab_lo <= ab_lo - 8'd1; ab[0] <= at_v;
                    aux <= t[1]; aux2 <= vint({28'd0, crk}); aux3 <= vint({24'd0, fcont});
                    fcont <= ABI_CONT_INIT; crk <= ABI_RK_CONT; st <= S_CALL;
                end else deliver(t[1], crk);

            // ---- bytecode function call ----
            S_CF: rd(adr(ab[0]) + 8, S_CF1);
            S_CF1: begin c_rc <= md; rd(adr(ab[0]) + 12, S_CF2); end
            S_CF2: begin c_clos <= mv; rd(adr(ab[0]) + 16, S_CF3); end
            S_CF3: begin c_defs <= mv; rd(adr(ab[0]) + 24, S_CF4); end
            S_CF4: begin
                c_glob <= mv;
                if (c_clos != VNULL) rd(adr(c_clos), S_CF_CLN);
                else st <= S_CF_SIG;
            end
            S_CF_CLN: begin c_cn <= md[7:0]; st <= S_CF_CLI; end
            S_CF_CLI: if (c_cn == 8'd0) st <= S_CF_SIG;
                      else if (ab_lo <= 8'd2) raise_err(ABI_ERR_STAR_ARGS, VNULL, VNULL);
                      else rd(adr(c_clos) + 4 * c_cn, S_CF_CLP);
            S_CF_CLP: begin
                ab[ab_lo - 8'd1] <= mv; ab_lo <= ab_lo - 8'd1; c_cn <= c_cn - 8'd1;
                st <= S_CF_CLI;
            end
            S_CF_SIG: rd(c_rc + 4 * ABI_RC_SIG, S_CF_SIG2);
            S_CF_SIG2: begin
                c_nst <= md[7:0]; c_nexc <= md[15:8]; c_scope <= md[23:16]; c_rcf <= md[31:24];
                rd(c_rc + 4 * ABI_RC_ARGS, S_CF_ARGS);
            end
            S_CF_ARGS: begin
                c_npos <= md[7:0]; c_nkwo <= md[15:8]; c_ndef <= md[23:16]; c_ncell <= md[31:24];
                rd(c_rc + 4 * ABI_RC_CELLS, S_CF_CHK);
            end
            S_CF_CHK: begin
                c_cells <= md;
                v0 = noframe ? ABI_FRAME_BASE : ftop;
                v1 = v0 + ((32'd16 + c_nst + 32'd3 * c_nexc) << 2);
                v2 = ab_pe - ab_lo;
                c_fast <= (ab_nkw == 8'd0) && (c_nkwo == 8'd0) && !(c_scope & ABI_SCOPE_VARKEYWORDS) &&
                          (v2 + c_ndef >= c_npos) &&
                          ((v2 <= c_npos) || (c_scope & ABI_SCOPE_VARARGS));
                x3 <= v0;
                if (c_rcf & ABI_RC_FLAG_GENERATOR)
                    raise_err(ABI_ERR_GENERATOR, ab[0], VNULL);
                else if (v1 > ABI_FRAME_END)
                    raise_msg(ABI_MSG_RECURSION);
                else if (noframe) st <= S_CF_SW;
                else gosub(S_SPILL, S_CF_SW);
            end
            S_CF_SW: begin
                fprev <= noframe ? 32'd0 : fbase;
                fbase <= x3; noframe <= 1'b0;
                rc <= c_rc; nst <= c_nst[6:0]; nexc <= c_nexc[4:0];
                sp <= 7'd0; xsp <= 5'd0;
                fflags <= (c_rcf & ABI_RC_FLAG_FIRMWARE) ? FF_FW : 8'd0;
                frk <= crk; fcont <= 8'd0;
                glb <= c_ismod ? cl_loc : c_glob;
                loc <= cl_loc; cl_loc <= VNULL;
                fun <= c_ismod ? VNULL : ab[0];
                aux <= VNULL; aux2 <= VNULL; aux3 <= VNULL;
                for (int k = 0; k < 64; k++) rf[k] <= VNULL;
                rd(c_rc + 4 * ABI_RC_OP_START, S_CF_PC);
            end
            S_CF_PC: begin pc <= md; op_pc <= md; rd(c_rc + 4 * ABI_RC_MODULE, S_CF_MD); end
            S_CF_MD: begin c_md <= md; rd(md + 4 * ABI_MD_QSTRS, S_CF_Q); end
            S_CF_Q: begin qbase <= md; rd(c_md + 4 * ABI_MD_CONSTS, S_CF_C); end
            S_CF_C: begin
                cbase <= md;
                if (c_fast) st <= S_BF;
                else st <= S_BS;
            end
            // fast positional binding
            S_BF: begin
                v2 = ab_pe - ab_lo;
                for (int k = 0; k < 64; k++)
                    if (k < v2 && k < c_npos) rf[6'(nst - 7'd1 - 7'(k))] <= ab[8'(ab_lo + 8'(k))];
                i0 <= v2[7:0];
                st <= S_BF_DEF;
            end
            S_BF_DEF: if (i0 >= c_npos) st <= S_BF_VA;
                      else rd(adr(c_defs) + 4 + 4 * (i0 - (c_npos - c_ndef)), S_BF_DEF2);
            S_BF_DEF2: begin rf[`LI(i0)] <= mv; i0 <= i0 + 8'd1; st <= S_BF_DEF; end
            S_BF_VA: if (c_scope & ABI_SCOPE_VARARGS) begin
                    tb_src <= 1'b0; tb_nz <= 1'b0;
                    tb_from <= ab_lo + c_npos;
                    tb_n <= (ab_pe - ab_lo > c_npos) ? (ab_pe - ab_lo - c_npos) : 8'd0;
                    gosub(S_TUP, S_BF_VA2);
                end else begin c_ci <= 32'd0; st <= S_CELLS; end
            S_BF_VA2: begin rf[`LI(c_npos + c_nkwo)] <= tb_v; c_ci <= 32'd0; st <= S_CELLS; end
            S_CELLS: if (c_ci == c_ncell) begin
                    fflags <= fflags & ~FF_NOTB; st <= S_FETCH;
                end else rd(c_cells + 4 * c_ci, S_CELL_I);
            S_CELL_I: begin i1 <= md[7:0]; alloc(32'd3, S_CELL_A); end
            S_CELL_A: begin
                wb_v[0] <= vint(ABI_OB_CELL); wb_v[1] <= ty_cell; wb_v[2] <= rf[`LI(i1)];
                rf[`LI(i1)] <= vobj(al_a);
                c_ci <= c_ci + 32'd1;
                wblock(al_a, 4'd3, S_CELLS);
            end
            // firmware binding: _bind(fun, args, kw) returns the locals
            S_BS: begin
                fflags <= fflags | FF_NOTB; fcont <= ABI_CONT_BIND;
                t[2] <= ab[0];
                tb_src <= 1'b0; tb_nz <= 1'b0; tb_from <= ab_lo; tb_n <= ab_pe - ab_lo;
                gosub(S_TUP, S_BS1);
            end
            S_BS1: begin
                t[0] <= tb_v; tb_src <= 1'b0; tb_nz <= 1'b1; tb_from <= ab_pe; tb_n <= {ab_nkw[6:0], 1'b0};
                gosub(S_TUP, S_BS2);
            end
            S_BS2: hook(ABI_HOOK_BIND, ABI_RK_CONT, 8'd3, t[2], t[0], tb_v, VNULL);

            // _callns(code, ns) when code is a module descriptor
            S_CNS: begin c_rc <= md; c_defs <= VNULL; c_clos <= VNULL; st <= S_CF_SIG; end

            // ---------------- frames ----------------
            S_SPILL: begin sw_i <= 32'd0; st <= S_SP_H; end
            S_SP_H: if (sw_i == 32'd14) begin sw_i <= 32'd0; st <= S_SP_R; end
                    else begin wr(fbase + (sw_i << 2), hdr_word(sw_i), S_SP_H); sw_i <= sw_i + 32'd1; end
            S_SP_R: if (sw_i == nst) begin sw_i <= 32'd0; sw_k <= 2'd0; st <= S_SP_X; end
                    else begin wr(fbase + 64 + (sw_i << 2), rf[sw_i[5:0]], S_SP_R); sw_i <= sw_i + 32'd1; end
            S_SP_X: if (sw_i == xsp) ret();
                    else begin
                        v0 = fbase + 64 + (nst << 2) + 12 * sw_i + (sw_k << 2);
                        case (sw_k)
                            2'd0: wr(v0, {4'd0, xh[sw_i[3:0]]}, S_SP_X);
                            2'd1: wr(v0, {4'd0, xf[sw_i[3:0]], 24'd0, xv[sw_i[3:0]]}, S_SP_X);
                            default: wr(v0, xp[sw_i[3:0]], S_SP_X);
                        endcase
                        if (sw_k == 2'd2) begin sw_k <= 2'd0; sw_i <= sw_i + 32'd1; end
                        else sw_k <= sw_k + 2'd1;
                    end

            S_FILL: begin fl_i <= 32'd0; fbase <= fl_base; rd(fl_base, S_FL_H); end
            S_FL_H: begin
                case (fl_i[3:0])
                    4'd0: fprev <= md;
                    4'd1: rc <= md;
                    4'd2: pc <= md;
                    4'd3: op_pc <= md;
                    4'd4: begin sp <= md[6:0]; xsp <= md[12:8]; nst <= md[22:16]; fflags <= md[31:24]; end
                    4'd5: begin frk <= md[3:0]; fcont <= md[15:8]; nexc <= md[20:16]; end
                    4'd6: glb <= mv;
                    4'd7: loc <= mv;
                    4'd8: fun <= mv;
                    4'd9: aux <= mv;
                    4'd10: aux2 <= mv;
                    4'd11: aux3 <= mv;
                    4'd12: qbase <= md;
                    4'd13: cbase <= md;
                endcase
                if (fl_i == 32'd13) begin
                    fl_i <= 32'd0;
                    if (nst == 7'd0) begin fl_k <= 2'd0; st <= S_FL_X0; end
                    else rd(fl_base + 64, S_FL_R);
                end else begin
                    fl_i <= fl_i + 32'd1;
                    rd(fl_base + ((fl_i + 32'd1) << 2), S_FL_H);
                end
            end
            S_FL_R: begin
                rf[fl_i[5:0]] <= mv;
                if (fl_i + 32'd1 == nst) begin fl_i <= 32'd0; fl_k <= 2'd0; st <= S_FL_X0; end
                else begin fl_i <= fl_i + 32'd1; rd(fl_base + 64 + ((fl_i + 32'd1) << 2), S_FL_R); end
            end
            S_FL_X0: if (fl_i == xsp) ret();
                     else rd(fl_base + 64 + (nst << 2) + 12 * fl_i + (fl_k << 2), S_FL_X);
            S_FL_X: begin
                case (fl_k)
                    2'd0: xh[fl_i[3:0]] <= md;
                    2'd1: begin xv[fl_i[3:0]] <= md[6:0]; xf[fl_i[3:0]] <= md[31]; end
                    default: xp[fl_i[3:0]] <= mv;
                endcase
                if (fl_k == 2'd2) begin fl_k <= 2'd0; fl_i <= fl_i + 32'd1; end
                else fl_k <= fl_k + 2'd1;
                st <= S_FL_X0;
            end

            S_RET: if (frk == ABI_RK_HALT) halt(ABI_HALT_CLEAN, 32'd0);
                   else begin r_rk <= frk; fl_base <= fprev; gosub(S_FILL, S_RET_D); end
            S_RET_D: begin d_rk <= r_rk; st <= S_DELIVER; end

            S_DELIVER: case (d_rk)
                ABI_RK_PUSH: begin push(t[7]); st <= S_FETCH; end
                ABI_RK_DISCARD: st <= S_FETCH;
                ABI_RK_PUSH_NULL: begin
                    rf[sp[5:0]] <= t[7]; rf[6'(sp + 7'd1)] <= VNULL; sp <= sp + 7'd2; st <= S_FETCH;
                end
                ABI_RK_CONT: st <= S_CONT;
                default: halt(ABI_HALT_CLEAN, 32'd0);
            endcase

            S_CONT: case (fcont)
                ABI_CONT_REDISPATCH: begin op <= aux[7:0]; st <= S_EXEC; end
                ABI_CONT_REPLACE: begin rf[aux[5:0]] <= t[7]; pc <= op_pc; st <= S_FETCH; end
                ABI_CONT_INIT: if (t[7] != VNONE) raise_err(ABI_ERR_INIT_NONE, t[7], VNULL);
                               else begin fcont <= aux3[7:0]; deliver(aux, aux2[3:0]); end
                ABI_CONT_WITH_ENTER: begin
                    exc_push(aux[31:0], 1'b1, sp);
                    push(t[7]); st <= S_FETCH;
                end
                ABI_CONT_WITH_NONE: begin push(VNONE); st <= S_FETCH; end
                ABI_CONT_WITH_UNWIND: begin
                    rf[sp[5:0]] <= aux; rf[6'(sp + 7'd1)] <= aux2; sp <= sp + 7'd2; st <= S_FETCH;
                end
                ABI_CONT_WITH_EXC: begin tr_v <= t[7]; gosub(S_TR, S_WC_TR); end
                ABI_CONT_UNPACK: rd(adr(t[7]), S_UPK_N);
                ABI_CONT_RAISE: raise_val(t[7]);
                ABI_CONT_TRUTH: begin
                    ovr <= (t[7] == VTRUE) ? ABI_OVR_TRUE : ABI_OVR_FALSE;
                    pc <= op_pc; st <= S_FETCH;
                end
                ABI_CONT_FOR_NEXT: if (t[7] == VSTOP) begin sp <= sp - 7'd4; pc <= aux[31:0]; st <= S_FETCH; end
                                   else begin push(t[7]); st <= S_FETCH; end
                ABI_CONT_GETITER: begin
                    rf[6'(sp - 7'd1)] <= t[7]; ovr <= ABI_OVR_PYOBJ; pc <= op_pc; st <= S_FETCH;
                end
                ABI_CONT_BIND: rd(adr(t[7]), S_CB_N);
                default: halt(ABI_HALT_INTERNAL, {24'd0, fcont});
            endcase
            S_WC_TR: begin
                push((tr_x || tr_r) ? VNONE : aux);
                st <= S_FETCH;
            end
            S_UPK_N: begin x1 <= md; i0 <= 8'd0; st <= S_UPK_L; end
            S_UPK_L: if (i0 == x1[7:0]) begin sp <= sp + x1[6:0]; st <= S_FETCH; end
                     else rd(adr(t[7]) + 4 + 4 * i0, S_UPK_V);
            S_UPK_V: begin
                rf[6'(sp + x1[6:0] - 7'd1 - i0[6:0])] <= mv; i0 <= i0 + 8'd1; st <= S_UPK_L;
            end
            S_CB_N: begin x1 <= md; i0 <= 8'd0; st <= S_CB_L; end
            S_CB_L: if (i0 == x1[7:0]) rd(rc + 4 * ABI_RC_ARGS, S_CB_A);
                    else rd(adr(t[7]) + 4 + 4 * i0, S_CB_V);
            S_CB_V: begin rf[`LI(i0)] <= mv; i0 <= i0 + 8'd1; st <= S_CB_L; end
            S_CB_A: begin c_ncell <= md[31:24]; rd(rc + 4 * ABI_RC_CELLS, S_CB_C); end
            S_CB_C: begin c_cells <= md; c_ci <= 32'd0; fcont <= 8'd0; st <= S_CELLS; end

            // ---------------- exceptions ----------------
            S_RMSG: alloc(32'd5, S_RMSG1);
            S_RMSG1: rd(h_msgs + 4 * rm_id, S_RMSG2);
            S_RMSG2: begin t[0] <= mv; rd(TT + 4 * msg_type(rm_id), S_RMSG3); end
            S_RMSG3: begin
                wb_v[0] <= vint(ABI_OB_EXCEPTION); wb_v[1] <= mv; wb_v[2] <= t[0];
                wb_v[3] <= VNULL; wb_v[4] <= VNULL;
                xc <= vobj(al_a);
                wblock(al_a, 4'd5, S_RMSG4);
            end
            S_RMSG4: begin rx_from <= 1'b0; rsp <= 5'd0; st <= S_RAISE; end

            S_RAISE: if ((rx_from && rx_crk == ABI_RK_CONT && fcont == ABI_CONT_FOR_NEXT) ||
                         (!rx_from && op == 8'h4b))
                         rd(adr(xc) + 4, S_RX_SI);
                     else st <= S_RX_TB;
            S_RX_SI: begin is_t <= mv; is_c <= ty_stop; gosub(S_ISSUB, S_RX_SI2); end
            S_RX_SI2: if (is_r) begin sp <= sp - 7'd4; pc <= aux[31:0]; st <= S_FETCH; end
                      else st <= S_RX_TB;
            S_RX_TB: if ((fflags & (FF_NOTB | FF_FW)) || adr(xc) == EMERG_ADDR ||
                         (!rx_from && (op == 8'h5d || op == 8'h64)))
                         st <= S_RX_H;
                     else rd(rc + 4 * ABI_RC_OP_START, S_RX_TB1);
            S_RX_TB1: begin rx_off <= op_pc - md; rd(adr(xc) + 12, S_RX_TB2); end
            S_RX_TB2: if (mv == VNULL) begin al_soft <= 1'b1; alloc(32'd7, S_RX_TBN); end
                      else begin t[2] <= mv; st <= S_RX_TBA; end
            S_RX_TBN: if (!al_ok) begin al_soft <= 1'b0; st <= S_RX_H; end
                      else begin
                          wb_v[0] <= vint(32'd0); wb_v[1] <= vint(32'd4); wb_v[2] <= {ABI_TAG_CONT, al_a + 32'd12};
                          t[2] <= vmut(al_a, ABI_MUT_LIST);
                          wblock(al_a, 4'd3, S_RX_TBL);
                      end
            S_RX_TBL: wr(adr(xc) + 12, t[2], S_RX_TBA);
            S_RX_TBA: begin t[3] <= vint(rc); al_soft <= 1'b1; gosub(S_LA, S_RX_TBB); end
            S_RX_TBB: begin t[3] <= vint(rx_off); gosub(S_LA, S_RX_TBC); end
            S_RX_TBC: begin al_soft <= 1'b0; st <= S_RX_H; end
            S_RX_H: if (xsp != 5'd0 && xh[xsp - 5'd1] <= op_pc) xsp <= xsp - 5'd1;
                    else if (xsp != 5'd0) begin
                        pc <= xh[xsp - 5'd1];
                        rf[xv[xsp - 5'd1][5:0]] <= xc;
                        sp <= xv[xsp - 5'd1] + 7'd1;
                        xp[xsp - 5'd1] <= xc;
                        st <= S_FETCH;
                    end else if (fprev == 32'd0) begin
                        halt(ABI_HALT_UNCAUGHT, xc[31:0]);
                    end else begin
                        rx_crk <= frk; fl_base <= fprev; gosub(S_FILL, S_RX_POP);
                    end
            S_RX_POP: begin rx_from <= 1'b1; st <= S_RAISE; end

            // ---------------- fetch / decode ----------------
            S_FETCH: if (in_win) st <= S_DEC;
                     else begin
                         fw_base <= {pc[31:2], 2'b00}; fw_i <= 2'd0; fw_ok <= 1'b0;
                         rd({pc[31:2], 2'b00}, S_FW);
                     end
            S_FW: begin
                fwin[32 * fw_i +: 32] <= md;
                if (fw_i == 2'd2) begin fw_ok <= 1'b1; st <= S_DEC; end
                else begin fw_i <= fw_i + 2'd1; rd(fw_base + 4 * (fw_i + 2'd1), S_FW); end
            end
            S_DEC: if (d_trunc) begin
                       if (fw_base == {pc[31:2], 2'b00}) halt(ABI_HALT_BAD_OPCODE, pc);
                       else begin fw_ok <= 1'b0; st <= S_FETCH; end
                   end else if (d_illegal || !d_valid) halt(ABI_HALT_BAD_OPCODE, pc);
                   else begin
                       op <= d_op; arg <= d_arg; ext <= d_ext;
                       op_pc <= pc; pc <= pc + d_len;
                       jt <= pc + d_len - (d_extv ? 32'd1 : 32'd0) + d_arg;
                       nops <= nops + 32'd1; trace <= 1'b1;
                       st <= S_EXEC;
                   end

            // ---------------- execute ----------------
            S_EXEC: begin
                if (op >= 8'h70 && op < 8'hb0) begin push(vint(32'(op) - 32'h80)); st <= S_FETCH; end
                else if (op >= 8'hb0 && op < 8'hc0) begin
                    if (rf[`LI(op - 8'hb0)] == VNULL) raise_msg(ABI_MSG_LOCAL_UNBOUND);
                    else begin push(rf[`LI(op - 8'hb0)]); st <= S_FETCH; end
                end else if (op >= 8'hc0 && op < 8'hd0) begin
                    rf[`LI(op - 8'hc0)] <= rf[6'(sp - 7'd1)]; sp <= sp - 7'd1; st <= S_FETCH;
                end else if (op >= 8'hd0 && op < 8'hd7) begin
                    n_o <= op - 8'hd0; st <= S_UN;
                end else if (op >= 8'hd7 && op < 8'hfa) begin
                    n_o <= op - 8'hd7; st <= S_BIN;
                end else case (op)
                8'h10: rd(qbase + 4 * arg, S_LCS);
                8'h22: begin push(vint(arg)); st <= S_FETCH; end
                8'h23: rd(cbase + 4 * arg, S_LCO);
                8'h50: begin push(VFALSE); st <= S_FETCH; end
                8'h51: begin push(VNONE); st <= S_FETCH; end
                8'h52: begin push(VTRUE); st <= S_FETCH; end
                8'h53: begin push(VNULL); st <= S_FETCH; end
                8'h24: if (rf[`LI(arg)] == VNULL) raise_msg(ABI_MSG_LOCAL_UNBOUND);
                       else begin push(rf[`LI(arg)]); st <= S_FETCH; end
                8'h26: begin rf[`LI(arg)] <= rf[6'(sp - 7'd1)]; sp <= sp - 7'd1; st <= S_FETCH; end
                8'h28: if (rf[`LI(arg)] == VNULL) raise_msg(ABI_MSG_LOCAL_UNBOUND);
                       else begin rf[`LI(arg)] <= VNULL; st <= S_FETCH; end
                8'h25: rd(adr(rf[`LI(arg)]) + 8, S_DEREF);
                8'h27: begin wr(adr(rf[`LI(arg)]) + 8, rf[6'(sp - 7'd1)], S_FETCH); sp <= sp - 7'd1; end
                8'h29: rd(adr(rf[`LI(arg)]) + 8, S_DELDEREF);
                8'h11, 8'h12, 8'h16, 8'h17, 8'h19, 8'h1a, 8'h13, 8'h14, 8'h18, 8'h15,
                8'h1b, 8'h1c:
                    rd(qbase + 4 * arg, S_QOP);
                8'h54: rd(h_hooks + 4 * ABI_HOOK_BUILD_CLASS, S_LCO);
                8'h55: begin t[0] <= rf[6'(sp - 7'd2)]; t[1] <= rf[6'(sp - 7'd1)]; st <= S_LSUB; end
                8'h56: begin
                    t[0] <= rf[6'(sp - 7'd2)]; t[1] <= rf[6'(sp - 7'd1)]; t[6] <= rf[6'(sp - 7'd3)];
                    st <= S_SSUB;
                end
                8'h57: begin push(rf[6'(sp - 7'd1)]); st <= S_FETCH; end
                8'h58: begin
                    rf[sp[5:0]] <= rf[6'(sp - 7'd2)]; rf[6'(sp + 7'd1)] <= rf[6'(sp - 7'd1)];
                    sp <= sp + 7'd2; st <= S_FETCH;
                end
                8'h59: begin sp <= sp - 7'd1; st <= S_FETCH; end
                8'h5a: begin
                    rf[6'(sp - 7'd1)] <= rf[6'(sp - 7'd2)]; rf[6'(sp - 7'd2)] <= rf[6'(sp - 7'd1)];
                    st <= S_FETCH;
                end
                8'h5b: begin
                    rf[6'(sp - 7'd3)] <= rf[6'(sp - 7'd1)];
                    rf[6'(sp - 7'd2)] <= rf[6'(sp - 7'd3)];
                    rf[6'(sp - 7'd1)] <= rf[6'(sp - 7'd2)];
                    st <= S_FETCH;
                end
                8'h42: begin pc <= jt; st <= S_FETCH; end
                8'h43, 8'h44, 8'h45, 8'h46: begin tr_v <= rf[6'(sp - 7'd1)]; gosub(S_TR, S_JT); end
                8'h47: begin t[0] <= rf[6'(sp - 7'd1)]; at_q <= ABI_Q_EXIT_D; gosub(S_AT, S_SW_X); end
                8'h48, 8'h49: begin
                    if (xsp >= nexc) halt(ABI_HALT_INTERNAL, op_pc);
                    else begin exc_push(jt, op == 8'h49, sp); st <= S_FETCH; end
                end
                8'h4a: begin xsp <= xsp - 5'd1; pc <= jt; st <= S_FETCH; end
                8'h40: begin
                    rf[sp[5:0]] <= vint(jt); rf[6'(sp + 7'd1)] <= vint({24'd0, ext});
                    sp <= sp + 7'd2; st <= S_UJ;
                end
                8'h5c: st <= S_WC;
                8'h5d: begin
                    xsp <= xsp - 5'd1;
                    if (rf[6'(sp - 7'd1)] == VNONE) begin sp <= sp - 7'd1; st <= S_FETCH; end
                    else if (tg(rf[6'(sp - 7'd1)]) == ABI_TAG_INT) begin
                        if (rf[6'(sp - 7'd1)][31]) begin sp <= sp - 7'd1; st <= S_UR; end
                        else st <= S_UJ;
                    end else raise_val(rf[6'(sp - 7'd1)]);
                end
                8'h63: st <= S_UR;
                8'h64: begin
                    vb = 1'b0;
                    for (int k = 0; k < 16; k++)
                        if (k < xsp && xp[k] != VNULL) begin vb = 1'b1; xc <= xp[k]; end
                    if (!vb) raise_msg(ABI_MSG_NO_ACTIVE_EXC);
                    else begin rx_from <= 1'b0; rsp <= 5'd0; st <= S_RAISE; end
                end
                8'h65: begin t[0] <= rf[6'(sp - 7'd1)]; sp <= sp - 7'd1; st <= S_ROBJ; end
                8'h66: if (rf[6'(sp - 7'd1)] != VNONE) begin
                           sp <= sp - 7'd1; aux <= vint(32'h65); fcont <= ABI_CONT_REDISPATCH;
                           hook(ABI_HOOK_WARN, ABI_RK_CONT, 8'd1, vint(32'd0), VNULL, VNULL, VNULL);
                       end else begin op <= 8'h65; sp <= sp - 7'd1; end
                8'h5e: begin sp <= sp - 7'd1; hook(ABI_HOOK_GETITER, ABI_RK_PUSH, 8'd1, rf[6'(sp - 7'd1)], VNULL, VNULL, VNULL); end
                8'h5f: begin t[0] <= rf[6'(sp - 7'd1)]; b1 <= (ovr == ABI_OVR_PYOBJ); ovr <= ABI_OVR_NONE; st <= S_GI; end
                8'h4b: begin
                    for (int k = 0; k < 4; k++) iv[k] <= rf[6'(sp - 7'd4 + 7'(k))];
                    if (rf[6'(sp - 7'd1)] == vint(ABI_IT_HEAPITER)) begin
                        it_h <= 1'b1; t[3] <= rf[6'(sp - 7'd4)]; i0 <= 8'd0; st <= S_FI_LD;
                    end else begin it_h <= 1'b0; gosub(S_IT, S_FI_R); end
                end
                8'h2a: begin
                    tb_src <= 1'b1; tb_nz <= 1'b0; tb_from <= 8'(sp - 7'(arg)); tb_n <= arg[7:0];
                    gosub(S_TUP, S_BT_R);
                end
                8'h2b: alloc(32'd3 + ((arg < 32'd4) ? 32'd4 : arg), S_BL_A);
                8'h2c: alloc(32'd4 + 2 * arg, S_BM_A);
                8'h2d: begin
                    tb_src <= 1'b1; tb_nz <= 1'b0; tb_from <= 8'(sp - 7'(arg)); tb_n <= arg[7:0];
                    gosub(S_TUP, S_BSET_R);
                end
                8'h2e: alloc(32'd5, S_SLICE_A);
                8'h2f: begin
                    vs0 = 7'(sp - 7'd1 - 7'(arg >> 2));
                    case (arg[1:0])
                        2'd0: begin t[2] <= rf[vs0[5:0]]; t[3] <= rf[6'(sp - 7'd1)]; gosub(S_LA, S_SC_L); end
                        2'd1: lookup(rf[vs0[5:0]], rf[6'(sp - 7'd1)], rf[6'(sp - 7'd2)], LK_ADD, 1'b0, S_SC_D);
                        default: lookup(rf[vs0[5:0]], rf[6'(sp - 7'd1)], VNULL, LK_ADD, 1'b1, S_SC_S);
                    endcase
                end
                8'h62: lookup(rf[6'(sp - 7'd3)], rf[6'(sp - 7'd1)], rf[6'(sp - 7'd2)], LK_ADD, 1'b0, S_STM_R);
                8'h30: begin
                    t[0] <= rf[6'(sp - 7'd1)];
                    if (tg(rf[6'(sp - 7'd1)]) == ABI_TAG_TUPLE || is_mut(rf[6'(sp - 7'd1)], ABI_MUT_LIST))
                        rd(adr(rf[6'(sp - 7'd1)]), S_UPS_N);
                    else begin
                        sp <= sp - 7'd1; fcont <= ABI_CONT_UNPACK;
                        hook(ABI_HOOK_UNPACK, ABI_RK_CONT, 8'd3, rf[6'(sp - 7'd1)], vint(arg), vint(32'd0), VNULL);
                    end
                end
                8'h31: begin
                    sp <= sp - 7'd1; fcont <= ABI_CONT_UNPACK;
                    hook(ABI_HOOK_UNPACK, ABI_RK_CONT, 8'd3, rf[6'(sp - 7'd1)], vint(arg), vint(32'd1), VNULL);
                end
                8'h32, 8'h33, 8'h20, 8'h21: rd(rc + 4 * ABI_RC_CHILDREN, S_MF_C);
                8'h34, 8'h36: begin
                    v0 = {24'd0, arg[7:0]};
                    v1 = {24'd0, arg[15:8]};
                    vs0 = 7'(sp - 7'(v0) - 7'(2 * v1));      // first argument
                    vs1 = 7'(vs0 - ((op == 8'h36) ? 7'd2 : 7'd1));  // callable
                    ab[0] <= rf[vs1[5:0]];
                    for (int k = 0; k < 64; k++)
                        if (k < v0 + 2 * v1) ab[32 + k] <= rf[6'(vs0 + 7'(k))];
                    if (op == 8'h36 && rf[6'(vs1 + 7'd1)] != VNULL) begin
                        ab[31] <= rf[6'(vs1 + 7'd1)]; ab_lo <= 8'd31;
                    end else ab_lo <= 8'd32;
                    ab_pe <= 8'd32 + v0[7:0]; ab_nkw <= v1[7:0];
                    sp <= vs1; crk <= ABI_RK_PUSH;
                    st <= S_CALL;
                end
                8'h35, 8'h37: begin
                    v0 = {24'd0, arg[7:0]};
                    v1 = {24'd0, arg[15:8]};
                    cv_base <= 7'(sp - 7'd1 - 7'(v0) - 7'(2 * v1));
                    cv_fidx <= 7'(sp - 7'd1 - 7'(v0) - 7'(2 * v1) - ((op == 8'h37) ? 7'd2 : 7'd1));
                    cv_bm <= rf[6'(sp - 7'd1)][31:0];
                    cv_n <= v0[7:0]; cv_j <= v1[7:0]; cv_i <= 8'd0;
                    st <= S_CVK_P;
                end
                8'h67, 8'h68: raise_err(ABI_ERR_GENERATOR, VNULL, VNULL);
                8'h69: begin
                    sp <= sp - 7'd1;
                    hook(ABI_HOOK_IMPORT_STAR, ABI_RK_DISCARD, 8'd2, rf[6'(sp - 7'd1)],
                         (loc == VNULL) ? glb : loc, VNULL, VNULL);
                end
                default: halt(ABI_HALT_BAD_OPCODE, op_pc);
                endcase
            end

            S_LCS: begin push({ABI_TAG_QSTR, md}); st <= S_FETCH; end
            S_LCO: begin push(mv); st <= S_FETCH; end
            S_DEREF: if (mv == VNULL) raise_msg(ABI_MSG_LOCAL_UNBOUND);
                     else begin push(mv); st <= S_FETCH; end
            S_DELDEREF: if (mv == VNULL) raise_msg(ABI_MSG_LOCAL_UNBOUND);
                        else wr(m_addr, VNULL, S_FETCH);

            // ---- qstr-operand opcodes ----
            S_QOP: begin
                at_q <= md;
                case (op)
                    8'h11, 8'h12: begin
                        b0 <= (op == 8'h11 && loc != VNULL) ? 1'b0 : 1'b1;
                        i2 <= (op == 8'h11 && loc != VNULL) ? 8'd0 : 8'd1;
                        st <= S_LN_L;
                    end
                    8'h16, 8'h17:
                        lookup((op == 8'h16 && loc != VNULL) ? loc : glb, {ABI_TAG_QSTR, md},
                               rf[6'(sp - 7'd1)], LK_ADD, 1'b0, S_SN_R);
                    8'h19, 8'h1a:
                        lookup((op == 8'h19 && loc != VNULL) ? loc : glb, {ABI_TAG_QSTR, md},
                               VNULL, LK_REMOVE, 1'b0, S_DN_R);
                    8'h13, 8'h14: begin t[0] <= rf[6'(sp - 7'd1)]; gosub(S_AT, S_LA_R); end
                    8'h18: begin t[0] <= rf[6'(sp - 7'd1)]; t[6] <= rf[6'(sp - 7'd2)]; st <= S_SA; end
                    8'h15: begin
                        sp <= sp - 7'd3;
                        hook(ABI_HOOK_SUPER_METHOD, ABI_RK_PUSH_NULL, 8'd3, rf[6'(sp - 7'd2)], rf[6'(sp - 7'd1)],
                             {ABI_TAG_QSTR, md}, VNULL);
                    end
                    8'h1b: begin
                        sp <= sp - 7'd2;
                        hook(ABI_HOOK_IMPORT, ABI_RK_PUSH, 8'd4, {ABI_TAG_QSTR, md}, rf[6'(sp - 7'd1)],
                             rf[6'(sp - 7'd2)], glb);
                    end
                    8'h1c: hook(ABI_HOOK_IMPORT_FROM, ABI_RK_PUSH, 8'd2, rf[6'(sp - 7'd1)], {ABI_TAG_QSTR, md},
                                VNULL, VNULL);
                    default: halt(ABI_HALT_BAD_OPCODE, op_pc);
                endcase
            end
            S_LN_L: lookup((i2 == 8'd0) ? loc : (i2 == 8'd1) ? glb : vmut(h_builtins, ABI_MUT_DICT),
                           {ABI_TAG_QSTR, at_q}, VNULL, LK_FIND, 1'b0, S_LN_R);
            S_LN_R: if (lk_found) begin push(lk_res); st <= S_FETCH; end
                    else if (i2 == 8'd2) raise_err(ABI_ERR_NAME, {ABI_TAG_QSTR, at_q}, VNULL);
                    else begin i2 <= i2 + 8'd1; st <= S_LN_L; end
            S_SN_R: if (lk_ro || lk_cx) raise_err(ABI_ERR_INTERNAL, t[4], VNULL);
                    else begin sp <= sp - 7'd1; st <= S_FETCH; end
            S_DN_R: if (!lk_found) raise_err(ABI_ERR_NAME, {ABI_TAG_QSTR, at_q}, VNULL);
                    else st <= S_FETCH;

            // ---- LOAD_ATTR / LOAD_METHOD ----
            S_LA_R: case (at_kind)
                2'd1: begin
                    rf[6'(sp - 7'd1)] <= at_v;
                    if (op == 8'h14) push(VNULL);
                    st <= S_FETCH;
                end
                2'd2: if (op == 8'h14) begin
                        rf[6'(sp - 7'd1)] <= at_v; push(t[0]); st <= S_FETCH;
                    end else begin t[1] <= at_v; alloc(32'd4, S_LA_BM); end
                default: begin
                    sp <= sp - 7'd1;
                    hook(ABI_HOOK_GETATTR, (op == 8'h14) ? ABI_RK_PUSH_NULL : ABI_RK_PUSH, 8'd2,
                         t[0], {ABI_TAG_QSTR, at_q}, VNULL, VNULL);
                end
            endcase
            S_LA_BM: begin
                wb_v[0] <= vint(ABI_OB_BOUND_METHOD); wb_v[1] <= ty_bm; wb_v[2] <= t[1]; wb_v[3] <= t[0];
                rf[6'(sp - 7'd1)] <= vobj(al_a);
                wblock(al_a, 4'd4, S_FETCH);
            end

            // ---- STORE_ATTR ----
            S_SA: if (tg(t[0]) == ABI_TAG_OBJECT) rd(adr(t[0]), S_SA_K);
                  else st <= S_SA_FB;
            S_SA_K: begin
                at_k <= md;
                if (md == ABI_OB_INSTANCE || md == ABI_OB_EXCEPTION) rd(adr(t[0]) + 4, S_SA_TY);
                else if (md == ABI_OB_TYPE || md == ABI_OB_MODULE) rd(adr(t[0]) + 8, S_SA_D);
                else st <= S_SA_FB;
            end
            S_SA_TY: rd(adr(mv) + 28, S_SA_TF);
            S_SA_TF: if (md & (ABI_TF_SETATTR | ABI_TF_DESC)) st <= S_SA_FB;
                     else rd(adr(t[0]) + ((at_k == ABI_OB_EXCEPTION) ? 16 : 8), S_SA_D);
            S_SA_D: if (mv == VNULL) begin
                        if (t[6] == VNULL || !(at_k == ABI_OB_INSTANCE || at_k == ABI_OB_EXCEPTION)) st <= S_SA_FB;
                        else alloc(32'd4, S_SA_ND);
                    end else lookup(mv, {ABI_TAG_QSTR, at_q}, t[6], (t[6] == VNULL) ? LK_REMOVE : LK_ADD, 1'b0, S_SA_R);
            S_SA_ND: begin
                wb_v[0] <= vint(32'd0); wb_v[1] <= vint(32'd0); wb_v[2] <= VNULL; wb_v[3] <= vint(32'd0);
                t[4] <= vmut(al_a, ABI_MUT_DICT);
                wblock(al_a, 4'd4, S_SA_NL);
            end
            S_SA_NL: wr(adr(t[0]) + ((at_k == ABI_OB_EXCEPTION) ? 16 : 8), t[4], S_SA_NL2);
            S_SA_NL2: lookup(t[4], {ABI_TAG_QSTR, at_q}, t[6], LK_ADD, 1'b0, S_SA_R);
            S_SA_R: if (lk_ro || lk_cx || (lk_mode == LK_REMOVE && !lk_found)) st <= S_SA_FB;
                    else begin sp <= sp - 7'd2; st <= S_FETCH; end
            S_SA_FB: begin
                sp <= sp - 7'd2;
                hook(ABI_HOOK_SETATTR, ABI_RK_DISCARD, 8'd3, t[0], {ABI_TAG_QSTR, at_q}, t[6], VNULL);
            end

            // ---- LOAD_SUBSCR ----
            S_LSUB: if ((is_mut(t[0], ABI_MUT_LIST) || tg(t[0]) == ABI_TAG_TUPLE) && intlike(t[1]))
                        rd(adr(t[0]), S_LS_LEN);
                    else if (is_mut(t[0], ABI_MUT_DICT))
                        lookup(t[0], t[1], VNULL, LK_FIND, 1'b0, S_LS_D);
                    else if ((strlike(t[0]) || tg(t[0]) == ABI_TAG_BYTES) && intlike(t[1])) begin
                        si_v <= t[0]; gosub(S_SINFO, S_LS_S);
                    end else st <= S_LS_FB;
            S_LS_LEN: begin
                v0 = ival(t[1]);
                if (v0[31]) v0 = v0 + md;
                x1 <= v0;
                if (v0[31] || v0 >= md)
                    raise_msg((tg(t[0]) == ABI_TAG_TUPLE) ? ABI_MSG_TUPLE_INDEX : ABI_MSG_LIST_INDEX);
                else if (tg(t[0]) == ABI_TAG_TUPLE) rd(adr(t[0]) + 4 + (v0 << 2), S_LS_PUT);
                else rd(adr(t[0]) + 8, S_LS_IT);
            end
            S_LS_IT: rd(md + (x1 << 2), S_LS_PUT);
            S_LS_PUT: begin rf[6'(sp - 7'd2)] <= mv; sp <= sp - 7'd1; st <= S_FETCH; end
            S_LS_D: if (lk_cx) st <= S_LS_FB;
                    else if (lk_found) begin rf[6'(sp - 7'd2)] <= lk_res; sp <= sp - 7'd1; st <= S_FETCH; end
                    else raise_err(ABI_ERR_KEY, t[1], VNULL);
            S_LS_S: begin
                v0 = ival(t[1]);
                if (v0[31]) v0 = v0 + si_len;
                x1 <= v0;
                if (si_na) st <= S_LS_FB;
                else if (v0[31] || v0 >= si_len)
                    raise_msg((tg(t[0]) == ABI_TAG_BYTES) ? ABI_MSG_BYTES_INDEX : ABI_MSG_STR_INDEX);
                else rd(si_addr + {v0[31:2], 2'b00}, S_LS_SB);
            end
            S_LS_SB: if (tg(t[0]) == ABI_TAG_BYTES) begin
                         rf[6'(sp - 7'd2)] <= vint({24'd0, byte_of(md, x1[1:0])}); sp <= sp - 7'd1; st <= S_FETCH;
                     end else rd(h_chars + 4 * byte_of(md, x1[1:0]), S_LS_SC);
            S_LS_SC: begin rf[6'(sp - 7'd2)] <= {ABI_TAG_QSTR, md}; sp <= sp - 7'd1; st <= S_FETCH; end
            S_LS_FB: begin
                sp <= sp - 7'd2;
                hook(ABI_HOOK_SUBSCR, ABI_RK_PUSH, 8'd2, t[0], t[1], VNULL, VNULL);
            end

            // ---- STORE_SUBSCR ----
            S_SSUB: if (t[6] == VNULL) st <= S_SS_FB;
                    else if (is_mut(t[0], ABI_MUT_LIST) && intlike(t[1])) rd(adr(t[0]), S_SS_LEN);
                    else if (is_mut(t[0], ABI_MUT_DICT)) lookup(t[0], t[1], t[6], LK_ADD, 1'b0, S_SS_D);
                    else st <= S_SS_FB;
            S_SS_LEN: begin
                v0 = ival(t[1]);
                if (v0[31]) v0 = v0 + md;
                x1 <= v0;
                if (v0[31] || v0 >= md) raise_msg(ABI_MSG_LIST_INDEX);
                else rd(adr(t[0]) + 8, S_SS_IT);
            end
            S_SS_IT: begin wr(md + (x1 << 2), t[6], S_FETCH); sp <= sp - 7'd3; end
            S_SS_D: if (lk_cx || lk_ro) st <= S_SS_FB;
                    else begin sp <= sp - 7'd3; st <= S_FETCH; end
            S_SS_FB: begin
                sp <= sp - 7'd3;
                hook(ABI_HOOK_SETSUBSCR, ABI_RK_DISCARD, 8'd3, t[0], t[1], t[6], VNULL);
            end

            // ---- conditional jumps ----
            S_JT: if (tr_x) begin
                    fcont <= ABI_CONT_TRUTH; pc <= op_pc;
                    hook(ABI_HOOK_TRUTH, ABI_RK_CONT, 8'd1, rf[6'(sp - 7'd1)], VNULL, VNULL, VNULL);
                end else begin
                    case (op)
                        8'h43: begin sp <= sp - 7'd1; if (tr_r) pc <= jt; end
                        8'h44: begin sp <= sp - 7'd1; if (!tr_r) pc <= jt; end
                        8'h45: if (tr_r) pc <= jt; else sp <= sp - 7'd1;
                        8'h46: if (!tr_r) pc <= jt; else sp <= sp - 7'd1;
                        default: rf[6'(sp - 7'd1)] <= vbool(!tr_r);   // UNARY_OP NOT
                    endcase
                    st <= S_FETCH;
                end

            // ---- with ----
            S_SW_X: begin
                if (at_kind == 2'd2) begin rf[6'(sp - 7'd1)] <= at_v; rf[sp[5:0]] <= t[0]; sp <= sp + 7'd1; end
                else if (at_kind == 2'd1) begin rf[6'(sp - 7'd1)] <= at_v; rf[sp[5:0]] <= VNULL; sp <= sp + 7'd1; end
                if (at_kind == 2'd1 || at_kind == 2'd2) begin
                    at_q <= ABI_Q_ENTER_D; gosub(S_AT, S_SW_E);
                end else raise_err(ABI_ERR_ATTR, t[0], {ABI_TAG_QSTR, ABI_Q_EXIT_D});
            end
            S_SW_E: if (at_kind == 2'd2 || at_kind == 2'd1) begin
                    ab[0] <= at_v; ab[31] <= t[0];
                    ab_lo <= (at_kind == 2'd2) ? 8'd31 : 8'd32; ab_pe <= 8'd32; ab_nkw <= 8'd0;
                    crk <= ABI_RK_CONT; fcont <= ABI_CONT_WITH_ENTER; aux <= vint(jt);
                    st <= S_CALL;
                end else raise_err(ABI_ERR_ATTR, t[0], {ABI_TAG_QSTR, ABI_Q_ENTER_D});
            S_WC: begin
                ab_nkw <= 8'd0; crk <= ABI_RK_CONT;
                ab[32] <= VNONE; ab[33] <= VNONE; ab[34] <= VNONE; ab_pe <= 8'd35;
                if (rf[6'(sp - 7'd1)] == VNONE) begin
                    ab[0] <= rf[6'(sp - 7'd3)]; ab[31] <= rf[6'(sp - 7'd2)];
                    ab_lo <= (rf[6'(sp - 7'd2)] != VNULL) ? 8'd31 : 8'd32;
                    sp <= sp - 7'd3; fcont <= ABI_CONT_WITH_NONE; st <= S_CALL;
                end else if (tg(rf[6'(sp - 7'd1)]) == ABI_TAG_INT) begin
                    ab[0] <= rf[6'(sp - 7'd4)]; ab[31] <= rf[6'(sp - 7'd3)];
                    ab_lo <= (rf[6'(sp - 7'd3)] != VNULL) ? 8'd31 : 8'd32;
                    aux <= rf[6'(sp - 7'd2)]; aux2 <= rf[6'(sp - 7'd1)];
                    sp <= sp - 7'd4; fcont <= ABI_CONT_WITH_UNWIND; st <= S_CALL;
                end else begin
                    ab[0] <= rf[6'(sp - 7'd3)]; ab[31] <= rf[6'(sp - 7'd2)];
                    ab_lo <= (rf[6'(sp - 7'd2)] != VNULL) ? 8'd31 : 8'd32;
                    aux <= rf[6'(sp - 7'd1)]; ab[33] <= rf[6'(sp - 7'd1)];
                    sp <= sp - 7'd3; fcont <= ABI_CONT_WITH_EXC;
                    rd(adr(rf[6'(sp - 7'd1)]) + 4, S_WC_T);
                end
            end
            S_WC_T: begin ab[32] <= mv; st <= S_CALL; end

            // ---- unwinding for return and jumps out of finally/with/for ----
            S_UR: if (xsp == 5'd0) begin t[7] <= rf[6'(sp - 7'd1)]; st <= S_RET; end
                  else begin
                      vi = 8'(xsp - 5'd1);
                      if (xf[vi[3:0]] && xh[vi[3:0]] >= pc) begin
                          rf[xv[vi[3:0]][5:0]] <= rf[6'(sp - 7'd1)];
                          rf[6'(xv[vi[3:0]] + 7'd1)] <= vint(32'hFFFF_FFFF);
                          sp <= xv[vi[3:0]] + 7'd2;
                          pc <= xh[vi[3:0]];
                          st <= S_FETCH;
                      end else begin
                          if (xf[vi[3:0]]) begin
                              if (tg(rf[6'(sp - 7'd2)]) == ABI_TAG_INT) begin
                                  rf[6'(sp - 7'd3)] <= rf[6'(sp - 7'd1)]; sp <= sp - 7'd2;
                              end else begin
                                  rf[6'(sp - 7'd2)] <= rf[6'(sp - 7'd1)]; sp <= sp - 7'd1;
                              end
                          end
                          xsp <= xsp - 5'd1;
                      end
                  end
            S_UJ: begin uj <= rf[6'(sp - 7'd1)][31:0]; sp <= sp - 7'd1; st <= S_UJ_L; end
            S_UJ_L: if (uj[6:0] == 7'd0) begin
                        pc <= rf[6'(sp - 7'd1)][31:0];
                        sp <= sp - 7'd1 - (uj[7] ? 7'd4 : 7'd0);
                        st <= S_FETCH;
                    end else begin
                        vi = 8'(xsp - 5'd1);
                        uj <= uj - 32'd1;
                        if (xf[vi[3:0]] && xh[vi[3:0]] >= pc) begin
                            push(vint(uj - 32'd1)); pc <= xh[vi[3:0]]; st <= S_FETCH;
                        end else begin
                            if (xf[vi[3:0]]) begin
                                if (tg(rf[6'(sp - 7'd2)]) == ABI_TAG_INT) begin
                                    rf[6'(sp - 7'd3)] <= rf[6'(sp - 7'd1)]; sp <= sp - 7'd2;
                                end else begin
                                    rf[6'(sp - 7'd2)] <= rf[6'(sp - 7'd1)]; sp <= sp - 7'd1;
                                end
                            end
                            xsp <= xsp - 5'd1;
                        end
                    end

            // ---- RAISE_OBJ ----
            S_ROBJ: if (tg(t[0]) != ABI_TAG_OBJECT) raise_err(ABI_ERR_NOT_EXC, t[0], VNULL);
                    else rd(adr(t[0]), S_ROBJ_K);
            S_ROBJ_K: if (md == ABI_OB_EXCEPTION) raise_val(t[0]);
                      else if (md == ABI_OB_TYPE) rd(adr(t[0]) + 28, S_ROBJ_T);
                      else raise_err(ABI_ERR_NOT_EXC, t[0], VNULL);
            S_ROBJ_T: if (md & ABI_TF_EXC) begin
                          ab[0] <= t[0]; ab_lo <= 8'd32; ab_pe <= 8'd32; ab_nkw <= 8'd0;
                          crk <= ABI_RK_CONT; fcont <= ABI_CONT_RAISE; st <= S_CALL;
                      end else raise_err(ABI_ERR_NOT_EXC, t[0], VNULL);

            // ---- GET_ITER_STACK ----
            S_GI: begin
                vs0 = 7'(sp - 7'd1);
                if (tg(t[0]) == ABI_TAG_TUPLE || tg(t[0]) == ABI_TAG_BYTES || is_mut(t[0], ABI_MUT_LIST) ||
                    is_mut(t[0], ABI_MUT_DICT) || is_mut(t[0], ABI_MUT_SET) || tg(t[0]) == ABI_TAG_ITER ||
                    (tg(t[0]) == ABI_TAG_OBJECT && b1)) begin
                    rf[6'(vs0 + 7'd1)] <= vint(32'd0); rf[6'(vs0 + 7'd2)] <= vint(32'd0);
                    rf[6'(vs0 + 7'd3)] <= vint(
                        (tg(t[0]) == ABI_TAG_ITER) ? ABI_IT_HEAPITER :
                        (tg(t[0]) == ABI_TAG_OBJECT) ? ABI_IT_PYOBJ :
                        is_mut(t[0], ABI_MUT_DICT) ? ABI_IT_DICT :
                        is_mut(t[0], ABI_MUT_SET) ? ABI_IT_SET : ABI_IT_SEQ);
                    sp <= sp + 7'd3; st <= S_FETCH;
                end else if (tg(t[0]) == ABI_TAG_RANGE) rd(adr(t[0]), S_GI_R0);
                else if (strlike(t[0])) begin si_v <= t[0]; gosub(S_SINFO, S_GI_S); end
                else if (tg(t[0]) == ABI_TAG_OBJECT) rd(adr(t[0]), S_GI_K);
                else st <= S_GI_FB;
            end
            S_GI_R0: begin rf[6'(sp - 7'd1)] <= mv; rd(adr(t[0]) + 4, S_GI_R1); end
            S_GI_R1: begin rf[sp[5:0]] <= mv; rd(adr(t[0]) + 8, S_GI_R2); end
            S_GI_R2: begin
                rf[6'(sp + 7'd1)] <= mv; rf[6'(sp + 7'd2)] <= vint(ABI_IT_RANGE);
                sp <= sp + 7'd3; st <= S_FETCH;
            end
            S_GI_S: if (si_na) st <= S_GI_FB;
                    else begin
                        rf[sp[5:0]] <= vint(32'd0); rf[6'(sp + 7'd1)] <= vint(32'd0);
                        rf[6'(sp + 7'd2)] <= vint(ABI_IT_STR);
                        sp <= sp + 7'd3; st <= S_FETCH;
                    end
            S_GI_K: if (md == ABI_OB_DICT_VIEW) rd(adr(t[0]) + 8, S_GI_V0);
                    else begin at_q <= ABI_Q_ITER_D; gosub(S_AT, S_GI_AT); end
            S_GI_V0: begin rf[6'(sp - 7'd1)] <= mv; rd(adr(t[0]) + 12, S_GI_V1); end
            S_GI_V1: begin
                rf[sp[5:0]] <= vint(32'd0); rf[6'(sp + 7'd1)] <= mv; rf[6'(sp + 7'd2)] <= vint(ABI_IT_DICT);
                sp <= sp + 7'd3; st <= S_FETCH;
            end
            S_GI_AT: if (at_kind == 2'd2 || at_kind == 2'd1) begin
                    ab[0] <= at_v; ab[31] <= t[0];
                    ab_lo <= (at_kind == 2'd2) ? 8'd31 : 8'd32; ab_pe <= 8'd32; ab_nkw <= 8'd0;
                    crk <= ABI_RK_CONT; fcont <= ABI_CONT_GETITER; pc <= op_pc;
                    st <= S_CALL;
                end else st <= S_GI_FB;
            S_GI_FB: begin
                fcont <= ABI_CONT_GETITER; pc <= op_pc;
                hook(ABI_HOOK_GETITER, ABI_RK_CONT, 8'd1, t[0], VNULL, VNULL, VNULL);
            end

            // ---- FOR_ITER ----
            S_FI_LD: if (i0 == 8'd4) gosub(S_IT, S_FI_R);
                     else rd(adr(t[3]) + 4 * i0, S_FI_LD2);
            S_FI_LD2: begin iv[i0[1:0]] <= mv; i0 <= i0 + 8'd1; st <= S_FI_LD; end
            S_FI_R: if (it_py) begin
                    t[0] <= iv[0]; at_q <= ABI_Q_NEXT_D; gosub(S_AT, S_FI_AT);
                end else if (it_h) wr(adr(t[3]), iv[0], S_FI_W1);
                else begin
                    rf[6'(sp - 7'd4)] <= iv[0]; rf[6'(sp - 7'd3)] <= iv[1];
                    st <= S_FI_DONE;
                end
            S_FI_W1: wr(adr(t[3]) + 4, iv[1], S_FI_DONE);
            S_FI_DONE: begin
                if (it_stop) begin sp <= sp - 7'd4; pc <= jt; end
                else push(it_val);
                st <= S_FETCH;
            end
            S_FI_AT: if (at_kind == 2'd2 || at_kind == 2'd1) begin
                    ab[0] <= at_v; ab[31] <= t[0];
                    ab_lo <= (at_kind == 2'd2) ? 8'd31 : 8'd32; ab_pe <= 8'd32; ab_nkw <= 8'd0;
                    crk <= ABI_RK_CONT; fcont <= ABI_CONT_FOR_NEXT; aux <= vint(jt);
                    st <= S_CALL;
                end else raise_err(ABI_ERR_NOT_ITERATOR, t[0], VNULL);

            // ---- containers ----
            S_BT_R: begin
                rf[6'(sp - 7'(tb_n))] <= tb_v; sp <= sp - 7'(tb_n) + 7'd1; st <= S_FETCH;
            end
            S_BL_A: begin
                v0 = (arg < 32'd4) ? 32'd4 : arg;
                wb_v[0] <= vint(arg); wb_v[1] <= vint(v0); wb_v[2] <= {ABI_TAG_CONT, al_a + 32'd12};
                t[0] <= vmut(al_a, ABI_MUT_LIST);
                i0 <= 8'd0;
                wblock(al_a, 4'd3, S_BL_L);
            end
            S_BL_L: if (i0 == arg[7:0]) begin
                        rf[6'(sp - 7'(arg))] <= t[0]; sp <= sp - 7'(arg) + 7'd1; st <= S_FETCH;
                    end else begin
                        wr(adr(t[0]) + 12 + 4 * i0, rf[6'(sp - 7'(arg) + 7'(i0))], S_BL_L);
                        i0 <= i0 + 8'd1;
                    end
            S_BM_A: begin
                wb_v[0] <= vint(32'd0); wb_v[1] <= vint(arg);
                wb_v[2] <= (arg == 32'd0) ? VNULL : {ABI_TAG_CONT, al_a + 32'd16};
                wb_v[3] <= vint(32'd0);
                rf[sp[5:0]] <= vmut(al_a, ABI_MUT_DICT); sp <= sp + 7'd1;
                wblock(al_a, 4'd4, S_FETCH);
            end
            S_BSET_R: begin
                sp <= sp - 7'(tb_n);
                hook(ABI_HOOK_DICTOP, ABI_RK_PUSH, 8'd4, vint(32'd0), tb_v, VNULL, VNULL);
            end
            S_SLICE_A: begin
                wb_v[0] <= vint(ABI_OB_SLICE); wb_v[1] <= ty_slice;
                if (arg == 32'd3) begin
                    wb_v[2] <= rf[6'(sp - 7'd3)]; wb_v[3] <= rf[6'(sp - 7'd2)]; wb_v[4] <= rf[6'(sp - 7'd1)];
                end else begin
                    wb_v[2] <= rf[6'(sp - 7'd2)]; wb_v[3] <= rf[6'(sp - 7'd1)]; wb_v[4] <= VNONE;
                end
                rf[6'(sp - 7'(arg))] <= vobj(al_a); sp <= sp - 7'(arg) + 7'd1;
                wblock(al_a, 4'd5, S_FETCH);
            end
            S_SC_L: begin sp <= sp - 7'd1; st <= S_FETCH; end
            S_SC_D: if (lk_cx || lk_ro) begin
                        sp <= sp - 7'd2;
                        hook(ABI_HOOK_DICTOP, ABI_RK_DISCARD, 8'd4, vint(32'd1), t[4], t[5], t[6]);
                    end else begin sp <= sp - 7'd2; st <= S_FETCH; end
            S_SC_S: if (lk_cx || lk_ro) begin
                        sp <= sp - 7'd1;
                        hook(ABI_HOOK_DICTOP, ABI_RK_DISCARD, 8'd4, vint(32'd2), t[4], t[5], VNULL);
                    end else begin sp <= sp - 7'd1; st <= S_FETCH; end
            S_STM_R: if (lk_cx || lk_ro) begin
                        sp <= sp - 7'd2;
                        hook(ABI_HOOK_DICTOP, ABI_RK_DISCARD, 8'd4, vint(32'd1), t[4], t[5], t[6]);
                    end else begin sp <= sp - 7'd2; st <= S_FETCH; end
            S_UPS_N: if (md != arg) begin
                        sp <= sp - 7'd1; fcont <= ABI_CONT_UNPACK;
                        hook(ABI_HOOK_UNPACK, ABI_RK_CONT, 8'd3, t[0], vint(arg), vint(32'd0), VNULL);
                    end else if (tg(t[0]) == ABI_TAG_TUPLE) begin
                        x2 <= adr(t[0]) + 4; i0 <= 8'd0; sp <= sp - 7'd1; st <= S_UPS_L;
                    end else rd(adr(t[0]) + 8, S_UPS_P);
            S_UPS_P: begin x2 <= md; i0 <= 8'd0; sp <= sp - 7'd1; st <= S_UPS_L; end
            S_UPS_L: if (i0 == arg[7:0]) begin sp <= sp + 7'(arg); st <= S_FETCH; end
                     else rd(x2 + 4 * i0, S_UPS_V);
            S_UPS_V: begin
                rf[6'(sp + 7'(arg) - 7'd1 - 7'(i0))] <= mv; i0 <= i0 + 8'd1; st <= S_UPS_L;
            end

            // ---- MAKE_FUNCTION / MAKE_CLOSURE ----
            S_MF_C: rd(md + 4 * arg, S_MF_R);
            S_MF_R: begin
                c_rc <= md;
                if (op == 8'h20 || op == 8'h21) begin
                    tb_src <= 1'b1; tb_nz <= 1'b0; tb_from <= 8'(sp - 7'(ext)); tb_n <= ext;
                    gosub(S_TUP, S_MF_CL);
                end else begin t[0] <= VNULL; alloc(32'd7, S_MF_A); end
            end
            S_MF_CL: begin t[0] <= tb_v; alloc(32'd7, S_MF_A); end
            S_MF_A: begin
                v0 = (op == 8'h20 || op == 8'h21) ? {24'd0, ext} : 32'd0;
                wb_v[0] <= vint(ABI_OB_FUNCTION); wb_v[1] <= ty_fun; wb_v[2] <= vint(c_rc);
                wb_v[3] <= t[0]; wb_v[6] <= glb;
                if (op == 8'h33 || op == 8'h21) begin
                    wb_v[4] <= rf[6'(sp - 7'(v0) - 7'd2)]; wb_v[5] <= rf[6'(sp - 7'(v0) - 7'd1)];
                    v0 = v0 + 32'd2;
                end else begin wb_v[4] <= VNULL; wb_v[5] <= VNULL; end
                rf[6'(sp - 7'(v0))] <= vobj(al_a); sp <= sp - 7'(v0) + 7'd1;
                wblock(al_a, 4'd7, S_FETCH);
            end

            // ---- CALL_*_VAR_KW: star-arg expansion ----
            S_CVK_P: if (cv_i == cv_n) begin
                    ab[0] <= rf[cv_fidx[5:0]];
                    if (op == 8'h37 && rf[6'(cv_fidx + 7'd1)] != VNULL) begin
                        ab[31] <= rf[6'(cv_fidx + 7'd1)]; ab_lo <= 8'd31;
                    end else ab_lo <= 8'd32;
                    ab_pe <= 8'd32; cv_i <= 8'd0;
                    st <= S_CVK_E;
                end else begin
                    t[0] <= rf[6'(cv_base + 7'(cv_i))];
                    if (cv_bm[cv_i[4:0]] && !(tg(rf[6'(cv_base + 7'(cv_i))]) == ABI_TAG_TUPLE ||
                                             is_mut(rf[6'(cv_base + 7'(cv_i))], ABI_MUT_LIST))) begin
                        aux <= vint({25'd0, 7'(cv_base + 7'(cv_i))}); fcont <= ABI_CONT_REPLACE; pc <= op_pc;
                        hook(ABI_HOOK_TUPLE, ABI_RK_CONT, 8'd1, rf[6'(cv_base + 7'(cv_i))], VNULL, VNULL, VNULL);
                    end else cv_i <= cv_i + 8'd1;
                end
            S_CVK_E: if (cv_i == cv_n) begin
                    for (int k = 0; k < 64; k++)
                        if (k < 2 * cv_j) ab[8'(ab_pe + 8'(k))] <= rf[6'(cv_base + 7'(cv_n) + 7'(k))];
                    ab_nkw <= cv_j; sp <= cv_fidx; crk <= ABI_RK_PUSH;
                    st <= S_CALL;
                end else if (!cv_bm[cv_i[4:0]]) begin
                    ab[ab_pe] <= rf[6'(cv_base + 7'(cv_i))]; ab_pe <= ab_pe + 8'd1; cv_i <= cv_i + 8'd1;
                end else begin
                    t[0] <= rf[6'(cv_base + 7'(cv_i))];
                    rd(adr(rf[6'(cv_base + 7'(cv_i))]), S_CVK_N);
                end
            S_CVK_N: begin
                x4 <= md; gi <= 32'd0;
                if (tg(t[0]) == ABI_TAG_TUPLE) begin cv_items <= adr(t[0]) + 4; st <= S_CVK_L; end
                else rd(adr(t[0]) + 8, S_CVK_I);
            end
            S_CVK_I: begin cv_items <= md; st <= S_CVK_L; end
            S_CVK_L: if (gi == x4) begin cv_i <= cv_i + 8'd1; st <= S_CVK_E; end
                     else if (ab_pe >= 8'd200) raise_err(ABI_ERR_STAR_ARGS, VNULL, VNULL);
                     else rd(cv_items + (gi << 2), S_CVK_V);
            S_CVK_V: begin ab[ab_pe] <= mv; ab_pe <= ab_pe + 8'd1; gi <= gi + 32'd1; st <= S_CVK_L; end

            // ---------------- unary / binary ----------------
            S_UN: begin
                v0 = 32'(n_o);
                if (v0 == ABI_UNOP_NOT) begin tr_v <= rf[6'(sp - 7'd1)]; gosub(S_TR, S_JT); end
                else if (numlike(rf[6'(sp - 7'd1)]) && v0 <= ABI_UNOP_INVERT) begin
                    n_un <= 1'b1;
                    alu_op <= (v0 == ABI_UNOP_POSITIVE) ? ALU_POS : (v0 == ABI_UNOP_NEGATIVE) ? ALU_NEG : ALU_INVERT;
                    t[0] <= rf[6'(sp - 7'd1)]; t[1] <= vint(32'd0);
                    st <= S_NUM;
                end else begin
                    sp <= sp - 7'd1;
                    hook(ABI_HOOK_UNOP, ABI_RK_PUSH, 8'd2, vint(v0), rf[6'(sp - 7'd1)], VNULL, VNULL);
                end
            end
            S_BIN: begin
                v0 = 32'(n_o);
                t[0] <= rf[6'(sp - 7'd2)]; t[1] <= rf[6'(sp - 7'd1)];
                n_un <= 1'b0;
                if (v0 == ABI_BINOP_IS) begin
                    rf[6'(sp - 7'd2)] <= vbool(rf[6'(sp - 7'd2)] == rf[6'(sp - 7'd1)]);
                    sp <= sp - 7'd1; st <= S_FETCH;
                end else if (v0 == ABI_BINOP_EXCEPTION_MATCH) st <= S_EXM;
                else if (v0 == ABI_BINOP_IN) st <= S_IN;
                else if (numlike(rf[6'(sp - 7'd2)]) && numlike(rf[6'(sp - 7'd1)]) &&
                         (v0 <= ABI_BINOP_NOT_EQUAL || (v0 >= ABI_BINOP_INPLACE_OR && v0 <= ABI_BINOP_POWER))) begin
                    alu_op <= (v0 >= ABI_BINOP_INPLACE_OR && v0 < ABI_BINOP_OR) ? 6'(v0 + 32'd13) : 6'(v0);
                    st <= S_NUM;
                end else if (v0 == ABI_BINOP_EQUAL || v0 == ABI_BINOP_NOT_EQUAL) st <= S_EQ;
                else st <= S_BIN_FB;
            end
            S_BIN_FB: begin
                sp <= sp - 7'd2;
                hook(ABI_HOOK_BINOP, ABI_RK_PUSH, 8'd3, vint(32'(n_o)), t[0], t[1], VNULL);
            end
            S_EQ: begin
                vb = (32'(n_o) == ABI_BINOP_NOT_EQUAL);
                if (t[0] == t[1] && tg(t[0]) != ABI_TAG_OBJECT) begin
                    rf[6'(sp - 7'd2)] <= vbool(!vb); sp <= sp - 7'd1; st <= S_FETCH;
                end else if (strlike(t[0]) && strlike(t[1])) begin
                    se_a <= t[0]; se_b <= t[1]; gosub(S_STREQ, S_EQ_S);
                end else if (strlike(t[0]) || strlike(t[1]) ||
                             (tg(t[0]) == ABI_TAG_CONTROL && tg(t[1]) != ABI_TAG_OBJECT) ||
                             (tg(t[1]) == ABI_TAG_CONTROL && tg(t[0]) != ABI_TAG_OBJECT)) begin
                    rf[6'(sp - 7'd2)] <= vbool(vb); sp <= sp - 7'd1; st <= S_FETCH;
                end else st <= S_BIN_FB;
            end
            S_EQ_S: begin
                rf[6'(sp - 7'd2)] <= vbool(se_eq ^ (32'(n_o) == ABI_BINOP_NOT_EQUAL));
                sp <= sp - 7'd1; st <= S_FETCH;
            end
            S_IN: if ((is_mut(t[1], ABI_MUT_DICT) || is_mut(t[1], ABI_MUT_SET)))
                      lookup(t[1], t[0], VNULL, LK_FIND, is_mut(t[1], ABI_MUT_SET), S_IN_R);
                  else st <= S_BIN_FB;
            S_IN_R: if (lk_cx) st <= S_BIN_FB;
                    else begin rf[6'(sp - 7'd2)] <= vbool(lk_found); sp <= sp - 7'd1; st <= S_FETCH; end

            S_EXM: if (tg(t[0]) != ABI_TAG_OBJECT) st <= S_BIN_FB;
                   else rd(adr(t[0]) + 4, S_EXM_T);
            S_EXM_T: begin
                is_t <= mv;
                if (tg(t[1]) == ABI_TAG_OBJECT) begin is_c <= t[1]; gosub(S_ISSUB, S_EXM_R); end
                else if (tg(t[1]) == ABI_TAG_TUPLE) rd(adr(t[1]), S_EXM_TN);
                else st <= S_BIN_FB;
            end
            S_EXM_R: begin rf[6'(sp - 7'd2)] <= vbool(is_r); sp <= sp - 7'd1; st <= S_FETCH; end
            S_EXM_TN: begin x4 <= md; gi <= 32'd0; st <= S_EXM_TL; end
            S_EXM_TL: if (gi == x4) begin rf[6'(sp - 7'd2)] <= VFALSE; sp <= sp - 7'd1; st <= S_FETCH; end
                      else rd(adr(t[1]) + 4 + (gi << 2), S_EXM_TI);
            S_EXM_TI: begin is_c <= mv; gosub(S_ISSUB, S_EXM_TR); end
            S_EXM_TR: if (is_r) begin rf[6'(sp - 7'd2)] <= VTRUE; sp <= sp - 7'd1; st <= S_FETCH; end
                      else begin gi <= gi + 32'd1; st <= S_EXM_TL; end

            // numeric datapath: t[0] op t[1]
            S_NUM: begin
                na_f <= (tg(t[0]) == ABI_TAG_FLOAT);
                if (tg(t[0]) == ABI_TAG_INT64) rd(adr(t[0]), S_NUM_AL);
                else begin na <= {{32{ival(t[0])[31]}}, ival(t[0])}; st <= S_NUM_B; end
            end
            S_NUM_AL: begin na[31:0] <= md; rd(adr(t[0]) + 4, S_NUM_AH); end
            S_NUM_AH: begin na[63:32] <= md; st <= S_NUM_B; end
            S_NUM_B: begin
                nb_f <= (tg(t[1]) == ABI_TAG_FLOAT);
                if (tg(t[1]) == ABI_TAG_INT64) rd(adr(t[1]), S_NUM_BL);
                else begin nb <= {{32{ival(t[1])[31]}}, ival(t[1])}; st <= S_NUM_GO; end
            end
            S_NUM_BL: begin nb[31:0] <= md; rd(adr(t[1]) + 4, S_NUM_BH); end
            S_NUM_BH: begin nb[63:32] <= md; st <= S_NUM_GO; end
            S_NUM_GO: begin
                n_small <= !na_f && !nb_f && fits31(na) && fits31(nb);
                alu_start <= 1'b1; st <= S_NUM_W;
            end
            S_NUM_W: if (alu_done) begin
                case (alu_err)
                    AE_NONE: begin
                        if (alu_kind == AK_BOOL) begin t[2] <= vbool(alu_res[0]); st <= S_NUM_PUT; end
                        else if (alu_kind == AK_FLOAT) begin t[2] <= {ABI_TAG_FLOAT, alu_res[31:0]}; st <= S_NUM_PUT; end
                        else if (fits32(alu_res)) begin t[2] <= vint(alu_res[31:0]); st <= S_NUM_PUT; end
                        else alloc(32'd2, S_NUM_BOX);
                    end
                    AE_ZERO_DIV: raise_msg(ABI_MSG_DIV_ZERO);
                    AE_OVERFLOW: raise_msg(ABI_MSG_OVERFLOW);
                    AE_NEG_SHIFT: raise_msg(ABI_MSG_NEG_SHIFT);
                    default: if (n_un) begin
                                 sp <= sp - 7'd1;
                                 hook(ABI_HOOK_UNOP, ABI_RK_PUSH, 8'd2, vint(32'(n_o)), t[0], VNULL, VNULL);
                             end else st <= S_BIN_FB;
                endcase
            end
            S_NUM_BOX: begin
                wb_v[0] <= vint(alu_res[31:0]); wb_v[1] <= vint(alu_res[63:32]);
                t[2] <= {ABI_TAG_INT64, al_a};
                wblock(al_a, 4'd2, S_NUM_PUT);
            end
            S_NUM_PUT: begin
                if (n_un) rf[6'(sp - 7'd1)] <= t[2];
                else begin rf[6'(sp - 7'd2)] <= t[2]; sp <= sp - 7'd1; end
                st <= S_FETCH;
            end

            // =================================================================
            // Natives. Args are ab[ab_lo .. ab_pe); the result goes by crk.
            // =================================================================
            S_NAT: begin
                v0 = 32'(ab_pe - ab_lo);
                v1 = ab[ab_lo][31:0];
                if (ab_nkw != 8'd0) st <= S_NAT_FB;
                else case (nid)
                    ABI_N_LEN: if (v0 != 32'd1) st <= S_NAT_FB;
                        else if (strlike(ab[ab_lo]) || tg(ab[ab_lo]) == ABI_TAG_BYTES) begin
                            si_v <= ab[ab_lo]; gosub(S_SINFO, S_N_LEN_S);
                        end else if (tg(ab[ab_lo]) == ABI_TAG_TUPLE || is_mut(ab[ab_lo], ABI_MUT_LIST) ||
                                     is_mut(ab[ab_lo], ABI_MUT_DICT) || is_mut(ab[ab_lo], ABI_MUT_SET))
                            rd(adr(ab[ab_lo]), S_N_RINT);
                        else st <= S_NAT_FB;
                    ABI_N_ISINSTANCE: if (v0 != 32'd2 || tg(ab[ab_lo + 8'd1]) != ABI_TAG_OBJECT) st <= S_NAT_FB;
                        else rd(adr(ab[ab_lo + 8'd1]), S_N_ISI);
                    ABI_N_ID: deliver(vint(ab[ab_lo][31:0]), crk);
                    ABI_N_WR, ABI_N_WE: begin
                        x4 <= ABI_SIM_BASE + 4 * ((nid == ABI_N_WR) ? ABI_SIM_STDOUT : ABI_SIM_STDERR);
                        if (tg(ab[ab_lo]) == ABI_TAG_INT) wr(ABI_SIM_BASE + 4 * ((nid == ABI_N_WR) ? ABI_SIM_STDOUT : ABI_SIM_STDERR),
                                                             ab[ab_lo], S_N_NONE);
                        else begin si_v <= ab[ab_lo]; gosub(S_SINFO, S_N_WR); end
                    end
                    ABI_N_HALT: halt(ab[ab_lo][31:0] == 32'd0 ? ABI_HALT_CLEAN : ABI_HALT_SYSEXIT, ab[ab_lo][31:0]);
                    ABI_N_TAG: deliver(vint({28'd0, tg(ab[ab_lo])}), crk);
                    ABI_N_PAY: deliver(vint(ab[ab_lo][31:0]), crk);
                    ABI_N_MK: deliver({ab[ab_lo][3:0], ab[ab_lo + 8'd1][31:0]}, crk);
                    ABI_N_LD: rd(padr(ab[ab_lo]) + (ab[ab_lo + 8'd1][31:0] << 2), S_N_RV);
                    ABI_N_ST: wr(padr(ab[ab_lo]) + (ab[ab_lo + 8'd1][31:0] << 2), ab[ab_lo + 8'd2], S_N_NONE);
                    ABI_N_PEEK8: begin
                        v2 = padr(ab[ab_lo]) + ab[ab_lo + 8'd1][31:0];
                        x3 <= v2; rd({v2[31:2], 2'b00}, S_N_PEEK8);
                    end
                    ABI_N_POKE8: wrb(padr(ab[ab_lo]) + ab[ab_lo + 8'd1][31:0], ab[ab_lo + 8'd2][7:0], S_N_NONE);
                    ABI_N_PEEK32: rd(ab[ab_lo][31:0], S_N_RINT);
                    ABI_N_ALLOC: alloc(ab[ab_lo][31:0], S_N_ALLOC);
                    ABI_N_TYPEOF: begin ty_v <= ab[ab_lo]; gosub(S_TYPEOF, S_N_TYPEOF); end
                    ABI_N_CALLNS: if (tg(ab[ab_lo]) == ABI_TAG_INT) begin
                            c_ismod <= 1'b1; c_md <= v1; cl_loc <= ab[ab_lo + 8'd1];
                            ab_lo <= 8'd32; ab_pe <= 8'd32;
                            rd(v1 + 4 * ABI_MD_RAW, S_CNS);
                        end else begin
                            cl_loc <= ab[ab_lo + 8'd1]; ab[0] <= ab[ab_lo];
                            ab_lo <= 8'd32; ab_pe <= 8'd32; st <= S_CALL;
                        end
                    ABI_N_WCOPY: begin
                        v2 = padr(ab[ab_lo]) + (ab[ab_lo + 8'd1][31:0] << 2);        // dst
                        v3 = padr(ab[ab_lo + 8'd2]) + (ab[ab_lo + 8'd3][31:0] << 2); // src
                        la_new <= v2; la_items <= v3; la_len <= ab[ab_lo + 8'd4][31:0];
                        b1 <= (v2 > v3);
                        la_i <= 32'd0; st <= S_N_WC;
                    end
                    ABI_N_BCOPY: begin si_v <= ab[ab_lo + 8'd2]; gosub(S_DADDR, S_N_BC1); end
                    ABI_N_STRNEW: alloc(32'd3 + ((v1 + 32'd3) >> 2), S_N_STRNEW);
                    ABI_N_STRFIN: rd(adr(ab[ab_lo]), S_N_SF0);
                    ABI_N_LOOKUP: lookup(ab[ab_lo], ab[ab_lo + 8'd1], VNULL, LK_FIND, is_mut(ab[ab_lo], ABI_MUT_SET), S_N_LOOKUP);
                    ABI_N_TICKS: deliver(vint({2'b00, cyc[29:0]}), crk);
                    ABI_N_GC: gosub(S_GC, S_N_NONE);
                    ABI_N_GCINFO: deliver(vint((v1 == 32'd0) ? (gc_free_i << 4) : (v1 == 32'd1) ? (gc_total_i << 4) : gc_collections_i), crk);
                    ABI_N_FTOI: begin
                        t[0] <= ab[ab_lo]; t[1] <= vint(32'd0); n_un <= 1'b1; alu_op <= ALU_F2I;
                        st <= S_N_FTOI;
                    end
                    ABI_N_INEXT: if (tg(ab[ab_lo]) != ABI_TAG_ITER) deliver(VNULL, crk);
                        else begin t[3] <= ab[ab_lo]; i0 <= 8'd0; st <= S_N_IN_LD; end
                    ABI_N_BCMP: begin si_v <= ab[ab_lo]; gosub(S_SINFO, S_N_BCMP1); end
                    ABI_N_HASH: begin hk <= ab[ab_lo]; gosub(S_HASH, S_N_HASH); end
                    ABI_N_DATA: begin si_v <= ab[ab_lo]; gosub(S_DADDR, S_N_DATA); end
                    ABI_N_SLEN: if (tg(ab[ab_lo]) == ABI_TAG_MUT || tg(ab[ab_lo]) == ABI_TAG_TUPLE) rd(adr(ab[ab_lo]), S_N_RINT);
                        else begin si_v <= ab[ab_lo]; gosub(S_SINFO, S_N_LEN_S); end
                    ABI_N_LIST_APPEND: if (v0 != 32'd2 || !is_mut(ab[ab_lo], ABI_MUT_LIST)) st <= S_NAT_FB;
                        else begin t[2] <= ab[ab_lo]; t[3] <= ab[ab_lo + 8'd1]; gosub(S_LA, S_N_NONE); end
                    ABI_N_OBJECT_INIT: if (v0 != 32'd1) st <= S_NAT_FB; else deliver(VNONE, crk);
                    ABI_N_BASEEXCEPTION_INIT: if (v0 < 32'd1 || tg(ab[ab_lo]) != ABI_TAG_OBJECT) st <= S_NAT_FB;
                        else begin
                            t[0] <= ab[ab_lo];
                            tb_src <= 1'b0; tb_nz <= 1'b0; tb_from <= ab_lo + 8'd1; tb_n <= ab_pe - ab_lo - 8'd1;
                            gosub(S_TUP, S_N_BEI);
                        end
                    ABI_N_NEW_RANGE: begin
                        vb = (v0 >= 32'd2) && (v0 <= 32'd4) && intlike(ab[ab_lo + 8'd1]) &&
                             (v0 < 32'd3 || intlike(ab[ab_lo + 8'd2])) && (v0 < 32'd4 || intlike(ab[ab_lo + 8'd3]));
                        if (!vb) st <= S_NAT_FB;
                        else begin
                            wb_v[0] <= vint((v0 == 32'd2) ? 32'd0 : ival(ab[ab_lo + 8'd1]));
                            wb_v[1] <= vint((v0 == 32'd2) ? ival(ab[ab_lo + 8'd1]) : ival(ab[ab_lo + 8'd2]));
                            wb_v[2] <= vint((v0 == 32'd4) ? ival(ab[ab_lo + 8'd3]) : 32'd1);
                            if (v0 == 32'd4 && ival(ab[ab_lo + 8'd3]) == 32'd0) raise_msg(ABI_MSG_ZERO_STEP);
                            else alloc(32'd3, S_N_RANGE);
                        end
                    end
                    ABI_N_NEW_OBJECT: if (v0 != 32'd1) st <= S_NAT_FB;
                        else begin t[0] <= ab[ab_lo]; alloc(32'd3, S_N_OBJ); end
                    default: st <= S_NAT_FB;
                endcase
            end
            S_NAT_FB: rd(adr(ab[0]) + 12, S_NAT_FB1);
            S_NAT_FB1: if (mv == VNULL) rd(adr(ab[0]) + 16, S_NAT_FB2);
                       else begin ab[0] <= mv; st <= S_CALL; end
            S_NAT_FB2: raise_err(ABI_ERR_BUILTIN_ARGS, mv, vint(32'(ab_pe - ab_lo)));
            S_N_NONE: deliver(VNONE, crk);
            S_N_RINT: deliver(vint(md), crk);
            S_N_RV: deliver(mv, crk);
            S_N_LEN_S: if (si_na && tg(si_v) != ABI_TAG_BYTES && nid == ABI_N_LEN) st <= S_NAT_FB;
                       else deliver(vint(si_len), crk);
            S_N_ISI: if (md != ABI_OB_TYPE) st <= S_NAT_FB;
                     else begin ty_v <= ab[ab_lo]; gosub(S_TYPEOF, S_N_ISI2); end
            S_N_ISI2: begin is_t <= ty_t; is_c <= ab[ab_lo + 8'd1]; gosub(S_ISSUB, S_N_ISI3); end
            S_N_ISI3: deliver(vbool(is_r), crk);
            S_N_WR: begin x2 <= si_addr; x1 <= 32'd0; st <= S_N_WRL; end
            S_N_WRL: if (x1 == si_len) deliver(VNONE, crk);
                     else rd(x2 + {x1[31:2], 2'b00}, S_N_WRB);
            S_N_WRB: begin wr(x4, vint({24'd0, byte_of(md, x1[1:0])}), S_N_WRL); x1 <= x1 + 32'd1; end
            S_N_PEEK8: deliver(vint({24'd0, byte_of(md, x3[1:0])}), crk);
            S_N_ALLOC: deliver({ab[ab_lo + 8'd1][3:0], al_a | ab[ab_lo + 8'd2][31:0]}, crk);
            S_N_TYPEOF: deliver(ty_t, crk);
            S_N_WC: if (la_i == la_len) deliver(VNONE, crk);
                    else rd(b1 ? (la_items + ((la_len - 32'd1 - la_i) << 2)) : (la_items + (la_i << 2)), S_N_WC2);
            S_N_WC2: begin
                wr(b1 ? (la_new + ((la_len - 32'd1 - la_i) << 2)) : (la_new + (la_i << 2)), mv, S_N_WC);
                la_i <= la_i + 32'd1;
            end
            S_N_BC1: begin la_items <= si_addr + ab[ab_lo + 8'd3][31:0]; si_v <= ab[ab_lo]; gosub(S_DADDR, S_N_BC2); end
            S_N_BC2: begin
                la_new <= si_addr + ab[ab_lo + 8'd1][31:0];
                la_len <= ab[ab_lo + 8'd4][31:0];
                b1 <= (si_addr + ab[ab_lo + 8'd1][31:0] > la_items);
                la_i <= 32'd0; st <= S_N_BC;
            end
            S_N_BC: if (la_i == la_len) deliver(VNONE, crk);
                    else begin
                        v2 = b1 ? (la_items + la_len - 32'd1 - la_i) : (la_items + la_i);
                        x3 <= v2; rd({v2[31:2], 2'b00}, S_N_BC3);
                    end
            S_N_BC3: begin
                wrb(b1 ? (la_new + la_len - 32'd1 - la_i) : (la_new + la_i), byte_of(md, x3[1:0]), S_N_BC);
                la_i <= la_i + 32'd1;
            end
            S_N_STRNEW: begin
                wb_v[0] <= vint(ab[ab_lo][31:0]); wb_v[1] <= vint(32'd0); wb_v[2] <= {ABI_TAG_CONT, al_a + 32'd12};
                t[0] <= {ab[ab_lo + 8'd1][3:0], al_a};
                wblock(al_a, 4'd3, S_N_STRNEW2);
            end
            S_N_STRNEW2: deliver(t[0], crk);
            // _strfin(s): hash and ASCII flag over the bytes
            S_N_SF0: begin la_len <= md; rd(adr(ab[ab_lo]) + 8, S_N_SF1); end
            S_N_SF1: begin la_items <= md; la_i <= 32'd0; x2 <= 32'd5381; b1 <= 1'b0; st <= S_N_SFL; end
            S_N_SFL: if (la_i == la_len) begin
                         v3 = {16'd0, x2[15:0]};
                         if (v3 == 32'd0) v3 = 32'd1;
                         wr(adr(ab[ab_lo]) + 4, vint(v3 | (b1 ? ABI_STR_NONASCII : 32'd0)), S_N_SF2);
                     end else rd(la_items + {la_i[31:2], 2'b00}, S_N_SFB);
            S_N_SFB: begin
                v3 = {24'd0, byte_of(md, la_i[1:0])};
                x2 <= (x2 * 32'd33) ^ v3;
                if (v3[7]) b1 <= 1'b1;
                la_i <= la_i + 32'd1;
                st <= S_N_SFL;
            end
            S_N_SF2: deliver(ab[ab_lo], crk);
            S_N_LOOKUP: deliver(lk_cx ? VSTOP : lk_found ? lk_res : VNULL, crk);
            S_N_FTOI: begin
                na_f <= 1'b1; na <= {32'd0, t[0][31:0]}; nb_f <= 1'b0; nb <= 64'd0; n_small <= 1'b0;
                alu_start <= 1'b1; st <= S_N_FTOI_W;
            end
            S_N_FTOI_W: if (alu_done) begin
                if (alu_err != AE_NONE) deliver(VSTOP, crk);
                else if (fits32(alu_res)) deliver(vint(alu_res[31:0]), crk);
                else alloc(32'd2, S_N_FTOI_B);
            end
            S_N_FTOI_B: begin
                wb_v[0] <= vint(alu_res[31:0]); wb_v[1] <= vint(alu_res[63:32]);
                t[0] <= {ABI_TAG_INT64, al_a};
                wblock(al_a, 4'd2, S_N_STRNEW2);
            end
            S_N_IN_LD: if (i0 == 8'd4) begin it_h <= 1'b1; gosub(S_IT, S_N_IN_R); end
                       else rd(adr(t[3]) + 4 * i0, S_N_IN_LD2);
            S_N_IN_LD2: begin iv[i0[1:0]] <= mv; i0 <= i0 + 8'd1; st <= S_N_IN_LD; end
            S_N_IN_R: if (it_py) deliver(VNULL, crk);
                      else wr(adr(t[3]), iv[0], S_N_IN_W);
            S_N_IN_W: wr(adr(t[3]) + 4, iv[1], S_N_IN_D);
            S_N_IN_D: deliver(it_stop ? VSTOP : it_val, crk);
            S_N_BCMP1: begin se_len <= si_len; se_pa <= si_addr; si_v <= ab[ab_lo + 8'd1]; gosub(S_SINFO, S_N_BCMP2); end
            S_N_BCMP2: begin se_pb <= si_addr; la_len <= si_len; la_i <= 32'd0; st <= S_N_BCL; end
            S_N_BCL: if (la_i == se_len || la_i == la_len) deliver(vint(se_len - la_len), crk);
                     else rd(se_pa + {la_i[31:2], 2'b00}, S_N_BCA);
            S_N_BCA: begin se_w <= md; rd(se_pb + {la_i[31:2], 2'b00}, S_N_BCB); end
            S_N_BCB: if (byte_of(se_w, la_i[1:0]) != byte_of(md, la_i[1:0]))
                         deliver(vint({24'd0, byte_of(se_w, la_i[1:0])} - {24'd0, byte_of(md, la_i[1:0])}), crk);
                     else begin la_i <= la_i + 32'd1; st <= S_N_BCL; end
            S_N_HASH: deliver(hok ? vint(hh) : VSTOP, crk);
            S_N_DATA: deliver(vint(si_addr), crk);
            S_N_BEI: wr(adr(t[0]) + 8, tb_v, S_N_NONE);
            S_N_RANGE: begin
                t[0] <= {ABI_TAG_RANGE, al_a};
                wblock(al_a, 4'd3, S_N_STRNEW2);
            end
            S_N_OBJ: begin
                wb_v[0] <= vint(ABI_OB_INSTANCE); wb_v[1] <= t[0]; wb_v[2] <= VNULL;
                t[0] <= vobj(al_a);
                wblock(al_a, 4'd3, S_N_STRNEW2);
            end

            // =================================================================
            // Subroutines
            // =================================================================
            S_WB: if (wb_i == wb_n) ret();
                  else begin wr(wb_a + 4 * wb_i, wb_v[wb_i[2:0]], S_WB); wb_i <= wb_i + 4'd1; end

            // allocate al_n words -> al_a (zeroed); GC once on failure
            S_AL: begin gc_alloc_req <= 1'b1; al_gc <= 1'b0; st <= S_AL_W; end
            S_AL_W: if (gc_alloc_done_i) begin
                if (gc_alloc_ok_i) begin al_a <= gc_alloc_addr_i; al_ok <= 1'b1; ret(); end
                else if (!al_gc) begin al_gc <= 1'b1; gosub(S_GC, S_AL_RT); end
                else if (al_soft) begin al_ok <= 1'b0; al_a <= 32'd0; ret(); end
                else begin
                    al_soft <= 1'b0;
                    wr(EMERG_ADDR + 16, vint(al_n << 2), S_AL_OOM);
                end
            end
            S_AL_RT: begin gc_alloc_req <= 1'b1; st <= S_AL_W; end
            S_AL_OOM: wr(EMERG_ADDR + 12, VNULL, S_AL_OOM2);
            S_AL_OOM2: raise_val(vobj(EMERG_ADDR));

            // collect: spill every root holder, then run the collector
            S_GC: if (noframe) begin gi <= 32'd0; st <= S_GC_AB; end
                  else gosub(S_SPILL, S_GC_1);
            S_GC_1: begin gi <= 32'd0; st <= S_GC_AB; end
            S_GC_AB: if (gi == 32'(ab_pe) + 32'(2 * ab_nkw)) begin gi <= 32'd0; st <= S_GC_T; end
                     else begin wr(ABI_ARGBUF_BASE + (gi << 2), ab[gi[7:0]], S_GC_AB); gi <= gi + 32'd1; end
            S_GC_T: if (gi == 32'd9) begin gc_collect_req <= 1'b1; st <= S_GC_W; end
                    else begin
                        case (gi[3:0])
                            4'd0: wr(ABI_SYSROOT_BASE + 4 * ABI_SR_CUR_EXC, xc, S_GC_T);
                            4'd1: wr(ABI_SYSROOT_BASE + 4 * ABI_SR_T0, t[0], S_GC_T);
                            4'd2: wr(ABI_SYSROOT_BASE + 4 * ABI_SR_T1, t[1], S_GC_T);
                            4'd3: wr(ABI_SYSROOT_BASE + 4 * ABI_SR_T2, t[2], S_GC_T);
                            4'd4: wr(ABI_SYSROOT_BASE + 4 * ABI_SR_T3, t[3], S_GC_T);
                            4'd5: wr(ABI_SYSROOT_BASE + 4 * ABI_SR_T4, t[4], S_GC_T);
                            4'd6: wr(ABI_SYSROOT_BASE + 4 * ABI_SR_T5, t[5], S_GC_T);
                            4'd7: wr(ABI_SYSROOT_BASE + 4 * ABI_SR_T6, t[6], S_GC_T);
                            default: wr(ABI_SYSROOT_BASE + 4 * ABI_SR_T7, t[7], S_GC_T);
                        endcase
                        gi <= gi + 32'd1;
                    end
            S_GC_W: if (gc_collect_done_i) ret();

            // type of ty_v -> ty_t
            S_TYPEOF: begin
                case (tg(ty_v))
                    ABI_TAG_CONTROL: rd(TT + 4 * (is_bool(ty_v) ? ABI_T_BOOL : ABI_T_NONETYPE), S_TYPEOF_TT);
                    ABI_TAG_INT, ABI_TAG_INT64: rd(TT + 4 * ABI_T_INT, S_TYPEOF_TT);
                    ABI_TAG_FLOAT: rd(TT + 4 * ABI_T_FLOAT, S_TYPEOF_TT);
                    ABI_TAG_COMPLEX: rd(TT + 4 * ABI_T_COMPLEX, S_TYPEOF_TT);
                    ABI_TAG_QSTR, ABI_TAG_STR: rd(TT + 4 * ABI_T_STR, S_TYPEOF_TT);
                    ABI_TAG_BYTES: rd(TT + 4 * ABI_T_BYTES, S_TYPEOF_TT);
                    ABI_TAG_TUPLE: rd(TT + 4 * ABI_T_TUPLE, S_TYPEOF_TT);
                    ABI_TAG_RANGE: rd(TT + 4 * ABI_T_RANGE, S_TYPEOF_TT);
                    ABI_TAG_ITER: rd(TT + 4 * ABI_T_ITERATOR, S_TYPEOF_TT);
                    ABI_TAG_OBJECT: rd(adr(ty_v) + 4, S_TYPEOF_TT);
                    ABI_TAG_MUT: case (ty_v[1:0])
                        ABI_MUT_LIST: rd(TT + 4 * ABI_T_LIST, S_TYPEOF_TT);
                        ABI_MUT_DICT: rd(TT + 4 * ABI_T_DICT, S_TYPEOF_TT);
                        ABI_MUT_SET: rd(adr(ty_v) + 12, S_TYPEOF_SET);
                        default: rd(TT + 4 * ABI_T_BYTEARRAY, S_TYPEOF_TT);
                    endcase
                    default: rd(TT + 4 * ABI_T_OBJECT, S_TYPEOF_TT);
                endcase
            end
            S_TYPEOF_SET: rd(TT + 4 * ((md & ABI_SET_FLAG_FROZEN) ? ABI_T_FROZENSET : ABI_T_SET), S_TYPEOF_TT);
            S_TYPEOF_TT: begin ty_t <= mv; ret(); end

            // hash of a simple key: hk -> hh, hok
            S_HASH: begin
                hok <= 1'b1;
                case (tg(hk))
                    ABI_TAG_INT: begin hh <= sx31(hk[31:0]); ret(); end
                    ABI_TAG_CONTROL: begin
                        if (hk == VTRUE) hh <= 32'd1;
                        else if (hk == VFALSE) hh <= 32'd0;
                        else if (hk == VNONE) hh <= HASH_NONE;
                        else hok <= 1'b0;
                        ret();
                    end
                    ABI_TAG_QSTR: rd(h_qdesc + (hk[31:0] << 3), S_HASH_W16);
                    ABI_TAG_STR, ABI_TAG_BYTES: rd(adr(hk) + 4, S_HASH_W16);
                    ABI_TAG_INT64: rd(adr(hk), S_HASH_I64);
                    ABI_TAG_OBJECT: rd(adr(hk), S_HASH_OBJ);
                    default: begin hok <= 1'b0; ret(); end
                endcase
            end
            S_HASH_W16: begin hh <= {16'd0, md[15:0]}; ret(); end
            S_HASH_I64: begin hh <= sx31(md); ret(); end
            S_HASH_OBJ: begin
                if (md == ABI_OB_INSTANCE || md == ABI_OB_EXCEPTION) hok <= 1'b0;
                else hh <= {1'b0, hk[31:1]};
                ret();
            end

            // str/qstr/bytes info: si_v -> si_len, si_hash, si_addr, si_na
            S_SINFO: if (tg(si_v) == ABI_TAG_QSTR) rd(h_qdesc + (si_v[31:0] << 3), S_SI_Q0);
                     else rd(adr(si_v), S_SI_S0);
            S_SI_Q0: begin si_hash <= {16'd0, md[15:0]}; si_len <= {16'd0, md[31:16]}; rd(m_addr + 4, S_SI_Q1); end
            S_SI_Q1: begin si_addr <= {1'b0, md[30:0]}; si_na <= md[31]; ret(); end
            S_SI_S0: begin si_len <= md; rd(adr(si_v) + 4, S_SI_S1); end
            S_SI_S1: begin si_hash <= {16'd0, md[15:0]}; si_na <= md[30]; rd(adr(si_v) + 8, S_SI_S2); end
            S_SI_S2: begin si_addr <= md; ret(); end

            // data address of a str/bytes/bytearray/list: si_v -> si_addr
            S_DADDR: if (tg(si_v) == ABI_TAG_QSTR) begin gosub(S_SINFO, S_DADDR_R); end
                     else if (tg(si_v) == ABI_TAG_INT) begin si_addr <= si_v[31:0]; ret(); end
                     else rd(adr(si_v) + 8, S_DADDR_M);
            S_DADDR_M: begin si_addr <= md; ret(); end
            S_DADDR_R: ret();

            // string equality: se_a, se_b -> se_eq
            S_STREQ: if (se_a == se_b) begin se_eq <= 1'b1; ret(); end
                     else begin si_v <= se_a; gosub(S_SINFO, S_SE1); end
            S_SE1: begin se_len <= si_len; se_hash <= si_hash; se_pa <= si_addr; si_v <= se_b; gosub(S_SINFO, S_SE2); end
            S_SE2: if (si_len != se_len || si_hash != se_hash) begin se_eq <= 1'b0; ret(); end
                   else begin se_pb <= si_addr; se_i <= 32'd0; st <= S_SEL; end
            S_SEL: if (se_i >= se_len) begin se_eq <= 1'b1; ret(); end
                   else rd(se_pa + se_i, S_SEA);
            S_SEA: begin se_w <= md; rd(se_pb + se_i, S_SEB); end
            S_SEB: begin
                v0 = se_len - se_i;
                v1 = (v0 >= 32'd4) ? 32'hFFFF_FFFF : ((32'd1 << (v0 << 3)) - 32'd1);
                if (((se_w ^ md) & v1) != 32'd0) begin se_eq <= 1'b0; ret(); end
                else begin se_i <= se_i + 32'd4; st <= S_SEL; end
            end

            // key equality for dict probing: ke_a (slot) vs ke_b (lookup key)
            S_KEYEQ: begin
                ke_cx <= 1'b0;
                if (ke_a == ke_b) begin ke_eq <= 1'b1; ret(); end
                else if (strlike(ke_a) && strlike(ke_b)) begin se_a <= ke_a; se_b <= ke_b; gosub(S_STREQ, S_KE_S); end
                else if (tg(ke_a) == ABI_TAG_BYTES && tg(ke_b) == ABI_TAG_BYTES) begin
                    se_a <= ke_a; se_b <= ke_b; gosub(S_STREQ, S_KE_S);
                end else if (strlike(ke_a) || strlike(ke_b)) begin ke_eq <= 1'b0; ret(); end
                else if (intlike(ke_a) && intlike(ke_b)) begin ke_eq <= (ival(ke_a) == ival(ke_b)); ret(); end
                else if (tg(ke_a) == ABI_TAG_INT64 && tg(ke_b) == ABI_TAG_INT64) rd(adr(ke_a), S_KE_A0);
                else if (tg(ke_a) == ABI_TAG_FLOAT || tg(ke_a) == ABI_TAG_COMPLEX) begin
                    ke_eq <= 1'b0; ke_cx <= numlike(ke_b); ret();
                end else if (tg(ke_a) == ABI_TAG_OBJECT || tg(ke_a) == ABI_TAG_TUPLE) rd(adr(ke_a), S_KE_OBJ);
                else begin ke_eq <= 1'b0; ret(); end
            end
            S_KE_S: begin ke_eq <= se_eq; ret(); end
            S_KE_A0: begin ke_w0 <= md; rd(adr(ke_a) + 4, S_KE_A1); end
            S_KE_A1: begin ke_w1 <= md; rd(adr(ke_b), S_KE_B0); end
            S_KE_B0: if (md != ke_w0) begin ke_eq <= 1'b0; ret(); end
                     else rd(adr(ke_b) + 4, S_KE_B1);
            S_KE_B1: begin ke_eq <= (md == ke_w1); ret(); end
            S_KE_OBJ: begin
                ke_eq <= 1'b0;
                ke_cx <= (tg(ke_a) == ABI_TAG_TUPLE) ? (tg(ke_b) == ABI_TAG_TUPLE)
                                                      : (md == ABI_OB_INSTANCE || md == ABI_OB_EXCEPTION);
                ret();
            end

            // dict/set probe: t4 container, t5 key, t6 value; lk_mode, lk_set
            S_LK: begin lk_found <= 1'b0; lk_cx <= 1'b0; lk_ro <= 1'b0; lk_res <= VNULL; rd(adr(t[4]) + 12, S_LK_FL); end
            S_LK_FL: if (lk_mode != LK_FIND && (md & ABI_DICT_FLAG_ROM)) begin lk_ro <= 1'b1; ret(); end
                     else rd(adr(t[4]) + 4, S_LK_AL);
            S_LK_AL: begin lk_alloc <= md; rd(adr(t[4]) + 8, S_LK_TB); end
            S_LK_TB: begin
                lk_tab <= md;
                if (lk_alloc == 32'd0) begin
                    if (lk_mode == LK_ADD) gosub(S_RH, S_LK_RH);
                    else ret();
                end else begin hk <= t[5]; gosub(S_HASH, S_LK_H); end
            end
            S_LK_RH: if (lk_cx) ret(); else st <= S_LK;
            S_LK_H: if (!hok) begin lk_cx <= 1'b1; ret(); end
                    else begin
                        lk_pos <= hh % lk_alloc; lk_start <= hh % lk_alloc; lk_hasav <= 1'b0;
                        st <= S_LK_P;
                    end
            S_LK_P: begin
                lk_slot <= lk_tab + (lk_set ? (lk_pos << 2) : (lk_pos << 3));
                rd(lk_tab + (lk_set ? (lk_pos << 2) : (lk_pos << 3)), S_LK_K);
            end
            S_LK_K: if (mv == VNULL) begin
                        if (lk_mode == LK_ADD) begin
                            if (lk_hasav) lk_slot <= lk_avail;
                            st <= S_LK_INS;
                        end else ret();
                    end else if (mv == VTOMB) begin
                        if (!lk_hasav) begin lk_hasav <= 1'b1; lk_avail <= lk_slot; end
                        st <= S_LK_NX;
                    end else if (mv == t[5]) st <= S_LK_HIT;
                    else begin ke_a <= mv; ke_b <= t[5]; gosub(S_KEYEQ, S_LK_KE); end
            S_LK_KE: if (ke_cx) begin lk_cx <= 1'b1; ret(); end
                     else if (ke_eq) st <= S_LK_HIT;
                     else st <= S_LK_NX;
            S_LK_NX: begin
                v0 = (lk_pos + 32'd1 == lk_alloc) ? 32'd0 : lk_pos + 32'd1;
                if (v0 == lk_start) begin
                    if (lk_mode == LK_ADD) begin
                        if (lk_hasav) begin lk_slot <= lk_avail; st <= S_LK_INS; end
                        else gosub(S_RH, S_LK_RH);
                    end else ret();
                end else begin lk_pos <= v0; st <= S_LK_P; end
            end
            S_LK_HIT: begin
                lk_found <= 1'b1;
                case (lk_mode)
                    LK_FIND: if (lk_set) begin lk_res <= t[5]; ret(); end
                             else rd(lk_slot + 4, S_LK_V);
                    LK_ADD: if (lk_set) ret();
                            else wr(lk_slot + 4, t[6], S_LK_RET);
                    default: if (lk_set) st <= S_LK_RM;
                             else rd(lk_slot + 4, S_LK_RV);
                endcase
            end
            S_LK_V: begin lk_res <= mv; ret(); end
            S_LK_RET: ret();
            S_LK_RV: begin lk_res <= mv; st <= S_LK_RM; end
            S_LK_RM: begin
                v0 = (lk_pos + 32'd1 == lk_alloc) ? 32'd0 : lk_pos + 32'd1;
                rd(lk_tab + (lk_set ? (v0 << 2) : (v0 << 3)), S_LK_RM2);
            end
            S_LK_RM2: begin
                wr(lk_slot, (mv == VNULL) ? VNULL : VTOMB, S_LK_RM3);
            end
            S_LK_RM3: if (lk_set) rd(adr(t[4]), S_LK_DEC);
                      else wr(lk_slot + 4, VNULL, S_LK_RM4);
            S_LK_RM4: rd(adr(t[4]), S_LK_DEC);
            S_LK_DEC: wr(adr(t[4]), vint(md - 32'd1), S_LK_RET);
            S_LK_INS: wr(lk_slot, t[5], lk_set ? S_LK_INS3 : S_LK_INS2);
            S_LK_INS2: wr(lk_slot + 4, t[6], S_LK_INS3);
            S_LK_INS3: rd(adr(t[4]), S_LK_INC);
            S_LK_INC: wr(adr(t[4]), vint(md + 32'd1), S_LK_RET);

            // grow the table of t4 (lk_alloc/lk_tab current)
            S_RH: begin
                rh_alloc <= next_alloc(lk_alloc + 32'd1);
                alloc(next_alloc(lk_alloc + 32'd1) << (lk_set ? 0 : 1), S_RH_A);
            end
            S_RH_A: begin rh_tab <= al_a; rh_i <= 32'd0; rh_used <= 32'd0; rd(adr(t[4]) + 4, S_RH_A2); end
            // a collection during the allocation may not move anything, but re-read for clarity
            S_RH_A2: begin lk_alloc <= md; rd(adr(t[4]) + 8, S_RH_A3); end
            S_RH_A3: begin lk_tab <= md; st <= S_RH_L; end
            S_RH_L: if (rh_i == lk_alloc) wr(adr(t[4]) + 4, vint(rh_alloc), S_RH_F1);
                    else rd(lk_tab + (lk_set ? (rh_i << 2) : (rh_i << 3)), S_RH_K);
            S_RH_K: if (mv == VNULL || mv == VTOMB) begin rh_i <= rh_i + 32'd1; st <= S_RH_L; end
                    else begin rh_k <= mv; hk <= mv; gosub(S_HASH, S_RH_H); end
            S_RH_H: if (!hok) begin lk_cx <= 1'b1; ret(); end
                    else begin rh_p <= hh % rh_alloc; st <= S_RH_P; end
            S_RH_P: rd(rh_tab + (lk_set ? (rh_p << 2) : (rh_p << 3)), S_RH_PK);
            S_RH_PK: if (mv != VNULL) begin
                         rh_p <= (rh_p + 32'd1 == rh_alloc) ? 32'd0 : rh_p + 32'd1; st <= S_RH_P;
                     end else wr(rh_tab + (lk_set ? (rh_p << 2) : (rh_p << 3)), rh_k, lk_set ? S_RH_NX : S_RH_V);
            S_RH_V: rd(lk_tab + (rh_i << 3) + 4, S_RH_V2);
            S_RH_V2: wr(rh_tab + (rh_p << 3) + 4, mv, S_RH_NX);
            S_RH_NX: begin rh_used <= rh_used + 32'd1; rh_i <= rh_i + 32'd1; st <= S_RH_L; end
            S_RH_F1: wr(adr(t[4]) + 8, {ABI_TAG_CONT, rh_tab}, S_RH_F2);
            S_RH_F2: wr(adr(t[4]), vint(rh_used), S_RH_F3);
            S_RH_F3: begin lk_alloc <= rh_alloc; lk_tab <= rh_tab; ret(); end

            // list append: t2 list, t3 value
            S_LA: rd(adr(t[2]), S_LA_N);
            S_LA_N: begin la_len <= md; rd(adr(t[2]) + 4, S_LA_A); end
            S_LA_A: begin la_alloc <= md; rd(adr(t[2]) + 8, S_LA_I); end
            S_LA_I: begin
                la_items <= md;
                if (la_len < la_alloc) wr(md + (la_len << 2), t[3], S_LA_INC);
                else alloc((la_alloc == 32'd0) ? 32'd4 : (la_alloc << 1), S_LA_G);
            end
            S_LA_G: if (!al_ok) ret();
                    else begin la_new <= al_a; la_i <= 32'd0; rd(adr(t[2]) + 8, S_LA_G2); end
            S_LA_G2: begin la_items <= md; st <= S_LA_CP; end
            S_LA_CP: if (la_i == la_len) wr(adr(t[2]) + 4, vint((la_alloc == 32'd0) ? 32'd4 : (la_alloc << 1)), S_LA_G3);
                     else rd(la_items + (la_i << 2), S_LA_CP2);
            S_LA_CP2: begin wr(la_new + (la_i << 2), mv, S_LA_CP); la_i <= la_i + 32'd1; end
            S_LA_G3: wr(adr(t[2]) + 8, {ABI_TAG_CONT, la_new}, S_LA_G4);
            S_LA_G4: wr(la_new + (la_len << 2), t[3], S_LA_INC);
            S_LA_INC: wr(adr(t[2]), vint(la_len + 32'd1), S_LA_RET);
            S_LA_RET: ret();

            // tuple from ab (tb_src=0) or rf (tb_src=1)
            S_TUP: if (tb_n == 8'd0) begin tb_v <= {ABI_TAG_TUPLE, h_empty}; ret(); end
                   else alloc(32'd1 + tb_n, S_TUP_A);
            S_TUP_A: begin tb_a <= al_a; tb_i <= 8'd0; wr(al_a, vint(32'(tb_n)), S_TUP_L); end
            S_TUP_L: if (tb_i == tb_n) begin tb_v <= {ABI_TAG_TUPLE, tb_a}; ret(); end
                     else begin
                         if (tb_src) wr(tb_a + 4 + 4 * tb_i, rf[6'(tb_from + tb_i)], S_TUP_L);
                         else if (tb_nz && ab[8'(tb_from + tb_i)] == VNULL) wr(tb_a + 4 + 4 * tb_i, vint(32'd0), S_TUP_L);
                         else wr(tb_a + 4 + 4 * tb_i, ab[8'(tb_from + tb_i)], S_TUP_L);
                         tb_i <= tb_i + 8'd1;
                     end

            // is_t a subclass of is_c?
            S_ISSUB: if (is_c == ty_obj || is_c == is_t) begin is_r <= 1'b1; ret(); end
                     else rd(adr(is_t) + 20, S_IS_M);
            S_IS_M: begin is_m <= adr(mv); rd(adr(mv), S_IS_N); end
            S_IS_N: begin is_n <= md; is_i <= 32'd0; st <= S_IS_L; end
            S_IS_L: if (is_i == is_n) begin is_r <= 1'b0; ret(); end
                    else rd(is_m + 4 + (is_i << 2), S_IS_C);
            S_IS_C: if (mv == is_c) begin is_r <= 1'b1; ret(); end
                    else begin is_i <= is_i + 32'd1; st <= S_IS_L; end

            // truth of tr_v -> tr_r, or tr_x when it needs __bool__/__len__
            S_TR: begin
                tr_x <= 1'b0;
                if (ovr == ABI_OVR_TRUE || ovr == ABI_OVR_FALSE) begin
                    tr_r <= (ovr == ABI_OVR_TRUE); ovr <= ABI_OVR_NONE; ret();
                end else case (tg(tr_v))
                    ABI_TAG_CONTROL: begin tr_r <= (tr_v == VTRUE); ret(); end
                    ABI_TAG_INT: begin tr_r <= (tr_v[31:0] != 32'd0); ret(); end
                    ABI_TAG_FLOAT: begin tr_r <= (tr_v[30:0] != 31'd0); ret(); end
                    ABI_TAG_INT64, ABI_TAG_ITER: begin tr_r <= 1'b1; ret(); end
                    ABI_TAG_QSTR: begin tr_r <= (tr_v[31:0] != ABI_Q_EMPTY); ret(); end
                    ABI_TAG_STR, ABI_TAG_BYTES, ABI_TAG_TUPLE, ABI_TAG_MUT: rd(adr(tr_v), S_TR_LEN);
                    ABI_TAG_OBJECT: rd(adr(tr_v) + 4, S_TR_T);
                    default: begin tr_x <= 1'b1; ret(); end
                endcase
            end
            S_TR_LEN: begin tr_r <= (md != 32'd0); ret(); end
            S_TR_T: rd(adr(mv) + 28, S_TR_F);
            S_TR_F: begin
                if (md & ABI_TF_TRUTH) tr_x <= 1'b1;
                else tr_r <= 1'b1;
                ret();
            end

            // attribute lookup: t0 object, at_q name -> at_kind (0 miss, 1 value, 2 method, 3 descriptor), at_v
            S_AT: begin
                at_ty <= 1'b0; at_objd <= 1'b0;
                if (tg(t[0]) == ABI_TAG_OBJECT) rd(adr(t[0]), S_AT_K);
                else begin ty_v <= t[0]; gosub(S_TYPEOF, S_AT_NT); end
            end
            S_AT_K: if (md == ABI_OB_INSTANCE) rd(adr(t[0]) + 8, S_AT_ID);
                    else if (md == ABI_OB_EXCEPTION) rd(adr(t[0]) + 16, S_AT_ID);
                    else if (md == ABI_OB_TYPE) begin at_t <= t[0]; at_ty <= 1'b1; st <= S_AT_MRO; end
                    else if (md == ABI_OB_MODULE) rd(adr(t[0]) + 8, S_AT_MOD);
                    else rd(adr(t[0]) + 4, S_AT_T1);
            S_AT_ID: if (mv == VNULL) rd(adr(t[0]) + 4, S_AT_T1);
                     else lookup(mv, {ABI_TAG_QSTR, at_q}, VNULL, LK_FIND, 1'b0, S_AT_IDR);
            S_AT_IDR: if (lk_found) begin at_kind <= 2'd1; at_v <= lk_res; ret(); end
                      else rd(adr(t[0]) + 4, S_AT_T1);
            S_AT_MOD: lookup(mv, {ABI_TAG_QSTR, at_q}, VNULL, LK_FIND, 1'b0, S_AT_MODR);
            S_AT_MODR: begin at_kind <= lk_found ? 2'd1 : 2'd0; at_v <= lk_res; ret(); end
            S_AT_T1: begin at_t <= mv; st <= S_AT_MRO; end
            S_AT_NT: begin at_t <= ty_t; st <= S_AT_MRO; end
            S_AT_MRO: rd(adr(at_t) + 20, S_AT_M1);
            S_AT_M1: begin at_m <= adr(mv); rd(adr(mv), S_AT_M2); end
            S_AT_M2: begin at_n <= md; at_i <= 32'd0; st <= S_AT_ML; end
            S_AT_ML: if (at_i == at_n) begin
                         if (!at_objd) begin at_objd <= 1'b1; rd(adr(ty_obj) + 8, S_AT_MD2); end
                         else begin at_kind <= 2'd0; ret(); end
                     end else rd(at_m + 4 + (at_i << 2), S_AT_MT);
            S_AT_MT: rd(adr(mv) + 8, S_AT_MD2);
            S_AT_MD2: lookup(mv, {ABI_TAG_QSTR, at_q}, VNULL, LK_FIND, 1'b0, S_AT_MR);
            S_AT_MR: if (!lk_found) begin
                         if (at_objd) begin at_kind <= 2'd0; ret(); end
                         else begin at_i <= at_i + 32'd1; st <= S_AT_ML; end
                     end else begin
                         at_v <= lk_res;
                         if (tg(lk_res) == ABI_TAG_OBJECT) rd(adr(lk_res), S_AT_VK);
                         else begin at_kind <= 2'd1; ret(); end
                     end
            S_AT_VK: begin
                if (md == ABI_OB_FUNCTION || md == ABI_OB_BUILTIN) at_kind <= at_ty ? 2'd1 : 2'd2;
                else if (md == ABI_OB_STATICMETHOD || md == ABI_OB_CLASSMETHOD || md == ABI_OB_PROPERTY) at_kind <= 2'd3;
                else at_kind <= 2'd1;
                ret();
            end

            // one step of an iterator in iv[0..3] -> it_val / it_stop, or it_py
            S_IT: begin
                it_stop <= 1'b0; it_py <= 1'b0; it_i <= iv[1][31:0];
                case (iv[3][31:0])
                    ABI_IT_RANGE: begin
                        if (iv[2][31] ? ($signed(iv[0][31:0]) <= $signed(iv[1][31:0]))
                                      : ($signed(iv[0][31:0]) >= $signed(iv[1][31:0]))) it_stop <= 1'b1;
                        else begin it_val <= iv[0]; iv[0] <= vint(iv[0][31:0] + iv[2][31:0]); end
                        ret();
                    end
                    ABI_IT_SEQ: if (tg(iv[0]) == ABI_TAG_TUPLE || is_mut(iv[0], ABI_MUT_LIST)) rd(adr(iv[0]), S_IT_SL);
                                else begin si_v <= iv[0]; gosub(S_SINFO, S_IT_BL); end
                    ABI_IT_DICT, ABI_IT_SET: rd(adr(iv[0]) + 4, S_IT_DA);
                    ABI_IT_STR: begin si_v <= iv[0]; gosub(S_SINFO, S_IT_BL); end
                    ABI_IT_PYOBJ: begin it_py <= 1'b1; ret(); end
                    default: begin it_stop <= 1'b1; ret(); end
                endcase
            end
            S_IT_SL: if (it_i >= md) begin it_stop <= 1'b1; ret(); end
                     else if (tg(iv[0]) == ABI_TAG_TUPLE) rd(adr(iv[0]) + 4 + (it_i << 2), S_IT_V);
                     else rd(adr(iv[0]) + 8, S_IT_LI);
            S_IT_LI: rd(md + (it_i << 2), S_IT_V);
            S_IT_V: begin it_val <= mv; iv[1] <= vint(it_i + 32'd1); ret(); end
            S_IT_BL: if (it_i >= si_len) begin it_stop <= 1'b1; ret(); end
                     else rd(si_addr + {it_i[31:2], 2'b00}, S_IT_BB);
            S_IT_BB: if (tg(iv[0]) == ABI_TAG_BYTES) begin
                         it_val <= vint({24'd0, byte_of(md, it_i[1:0])}); iv[1] <= vint(it_i + 32'd1); ret();
                     end else rd(h_chars + 4 * byte_of(md, it_i[1:0]), S_IT_SC);
            S_IT_SC: begin it_val <= {ABI_TAG_QSTR, md}; iv[1] <= vint(it_i + 32'd1); ret(); end
            S_IT_DA: begin it_alloc <= md; rd(adr(iv[0]) + 8, S_IT_DT); end
            S_IT_DT: begin it_tab <= md; st <= S_IT_DL; end
            S_IT_DL: if (it_i >= it_alloc) begin it_stop <= 1'b1; iv[1] <= vint(it_i); ret(); end
                     else rd(it_tab + ((iv[3][31:0] == ABI_IT_SET) ? (it_i << 2) : (it_i << 3)), S_IT_DK);
            S_IT_DK: if (mv == VNULL || mv == VTOMB) begin it_i <= it_i + 32'd1; st <= S_IT_DL; end
                     else if (iv[3][31:0] == ABI_IT_SET || iv[2][31:0] == 32'd0) begin
                         it_val <= mv; iv[1] <= vint(it_i + 32'd1); ret();
                     end else if (iv[2][31:0] == 32'd1) rd(m_addr + 4, S_IT_V);
                     else begin t[2] <= mv; rd(m_addr + 4, S_IT_DV); end
            S_IT_DV: begin t[1] <= mv; alloc(32'd3, S_IT_DI); end
            S_IT_DI: begin
                wb_v[0] <= vint(32'd2); wb_v[1] <= t[2]; wb_v[2] <= t[1];
                it_val <= {ABI_TAG_TUPLE, al_a}; iv[1] <= vint(it_i + 32'd1);
                wblock(al_a, 4'd3, S_LA_RET);
            end

            default: halt(ABI_HALT_INTERNAL, 32'hDEAD_0000 | 32'(st));
            endcase
        end
    end
endmodule
/* verilator lint_on BLKSEQ */
/* verilator lint_on CASEINCOMPLETE */
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on WIDTH */
`undef LI
