`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// jrp_rqa_extractor_k2.v
//   Streaming RQA counters for K = 2: two cells per beat. Same algorithm and counter
//   definitions as the released RQA_extractor_nobitmap.v (Li, Lai and Oberst 2026, Zenodo
//   10.5281/zenodo.20406392, MIT) and as jrp_rqa_extractor.v (K = 1); restructured so that
//   two cells of the same row, (i, j0) and (i, j0 + 1) with j0 even, are processed per cycle.
//
//   Beat format: {i, j0, f1, f0, v1}. v1 = 0 on the last beat of a row of odd length.
//
//   Why two adjacent cells never conflict: the vertical state is indexed by column and the
//   diagonal state by diagonal, and the two cells of a beat have different columns and different
//   diagonals. The state memories are therefore banked by parity:
//     vertical state : bank A = even columns, bank B = odd columns, address j >> 1
//                      (lane 0 always hits A, lane 1 always hits B)
//     diagonal state : d = j - i - 1 (upper triangle, d >= 0), bank = d[0], address d >> 1
//                      (the two cells hit different banks; which cell goes to which bank
//                      alternates with the parity of j0 - i, handled by `swap`)
//   Each bank has one read and one write per cycle, so the beat is a single read-modify-write.
//   The DET and LAM histograms are held twice (one RAM per lane, `jrp_hist_unit`); the
//   host-visible bin is the sum of the two copies.
//
//   Dependent beats must be at least 2 apart: the scan engine issues one beat every 2 cycles
//   when n <= 2 (see jrp_pair_gen_k2).
//   Differences from the K = 1 extractor: finalisation sweeps are pipelined (one state word per
//   cycle instead of about four), the histograms are cleared in parallel, and every counter is
//   accumulated one cycle after the cell logic (events are registered first) for timing.
// -----------------------------------------------------------------------------
module jrp_rqa_extractor_k2 #(
    parameter integer N_MAX       = 8192,
    parameter integer N_BITS      = 14,
    parameter integer RUNW        = 16,
    parameter integer ENABLE_HIST = 1,     // histograms are always built; kept for port compatibility
    parameter integer HIST_W      = 32,
    parameter integer HIST_K      = 8192
)(
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         frame_start,
    input  wire [31:0]                  cells_target,

    input  wire [2*N_BITS+2:0]          s_axis_tdata,    // {i, j0, f1, f0, v1}
    input  wire                         s_axis_tvalid,
    output wire                         s_axis_tready,

    input  wire [31:0]                  n_actual,

    output reg  [63:0]                  rr_count,
    output reg  [63:0]                  det_points,
    output reg  [31:0]                  det_lines,
    output reg  [RUNW-1:0]              l_max,
    output reg  [63:0]                  lam_points,
    output reg  [31:0]                  lam_lines,
    output reg  [RUNW-1:0]              v_max,
    output wire                         metrics_valid,   // 1-cycle pulse

    input  wire                         hist_rd_en,
    input  wire                         hist_sel,        // 0 = DET, 1 = LAM
    input  wire [$clog2(HIST_K)-1:0]    hist_idx,
    output wire [31:0]                  hist_rd_data,
    output wire                         hist_ready,

    input  wire [31:0]                  l_min,
    input  wire [31:0]                  v_min,

    output wire [31:0]                  cells_accepted_dbg
);
    localparam integer IW     = N_BITS;
    localparam integer AW_J   = $clog2(N_MAX);
    localparam integer AWB    = AW_J - 1;              // bank address bits
    localparam integer STATEW = 2 + IW + RUNW;
    localparam integer AW_H   = $clog2(HIST_K);

    localparam [1:0] ST_RUN = 2'd0, ST_SWEEP = 2'd1, ST_HIST_CLR = 2'd2;
    reg [1:0] st_main;
    assign s_axis_tready = (st_main == ST_RUN);

    // ---------------- beat unpack and per-beat precompute ----------------
    wire          in_v1 = s_axis_tdata[0];
    wire          in_f0 = s_axis_tdata[1];
    wire          in_f1 = s_axis_tdata[2];
    wire [IW-1:0] in_j0 = s_axis_tdata[IW+2:3];
    wire [IW-1:0] in_i  = s_axis_tdata[2*IW+2:IW+3];

    wire [IW-1:0] in_im1  = in_i - 1'b1;
    wire [IW-1:0] in_j1   = in_j0 + 1'b1;
    wire [IW-1:0] in_d1   = in_j0 - in_i;              // j0 - i: diagonal index (+1) of the second cell
    wire [IW-1:0] in_d1m1 = in_d1 - 1'b1;              // j0 - i - 1: diagonal index of the first cell
    wire          loi0    = (in_i == in_j0);
    wire          loi1    = (in_i == in_j1);
    wire          fe0     = in_f0 & ~loi0;                // flag with the main diagonal removed
    wire          fe1     = in_f1 & in_v1 & ~loi1;
    wire          use0    = (in_i <  in_j0);              // strict upper triangle
    wire          use1    = in_v1 & (in_i <= in_j0);

    // ---------------- state memories ----------------
    reg  [AWB-1:0]   lam_raddr, detE_raddr, detO_raddr;
    wire [STATEW-1:0] lamA_rd, lamB_rd, detE_rd, detO_rd;
    reg              lamA_we, lamB_we, detE_we, detO_we;
    reg  [AWB-1:0]   lamA_wa, lamB_wa, detE_wa, detO_wa;
    reg  [STATEW-1:0] lamA_wd, lamB_wd, detE_wd, detO_wd;

    jrp_tdp_bram_fw #(.W(STATEW), .AW(AWB)) u_lamA (.clk(clk), .wea(lamA_we), .addra(lamA_wa), .dina(lamA_wd), .douta(),
        .web(1'b0), .addrb(lam_raddr), .dinb({STATEW{1'b0}}), .doutb(lamA_rd));
    jrp_tdp_bram_fw #(.W(STATEW), .AW(AWB)) u_lamB (.clk(clk), .wea(lamB_we), .addra(lamB_wa), .dina(lamB_wd), .douta(),
        .web(1'b0), .addrb(lam_raddr), .dinb({STATEW{1'b0}}), .doutb(lamB_rd));
    jrp_tdp_bram_fw #(.W(STATEW), .AW(AWB)) u_detE (.clk(clk), .wea(detE_we), .addra(detE_wa), .dina(detE_wd), .douta(),
        .web(1'b0), .addrb(detE_raddr), .dinb({STATEW{1'b0}}), .doutb(detE_rd));
    jrp_tdp_bram_fw #(.W(STATEW), .AW(AWB)) u_detO (.clk(clk), .wea(detO_we), .addra(detO_wa), .dina(detO_wd), .douta(),
        .web(1'b0), .addrb(detO_raddr), .dinb({STATEW{1'b0}}), .doutb(detO_rd));

    // ---------------- frame control ----------------
    reg        cur_fid, finalized_once, finalize_req;
    reg [31:0] cells_accepted;
    assign cells_accepted_dbg = cells_accepted;

    // ---------------- pipeline: q (address issue) -> d (data returned) ----------------
    reg              had_read_q, had_read_d;
    reg [IW-1:0]     i_q, im1_q, i_d, im1_d;
    reg              fe0_q, fe1_q, v1_q, swap_q, u0_q, u1_q, f0_q, f1_q;
    reg              fe0_d, fe1_d, v1_d, swap_d, u0_d, u1_d, f0_d, f1_d;
    reg [AWB-1:0]    la_q, la_d, dE_q, dE_d, dO_q, dO_d;

    // per-lane run cells
    wire [STATEW-1:0] lc0_st, lc1_st, dc0_st, dc1_st;
    wire              lc0_cv, lc1_cv, dc0_cv, dc1_cv;
    wire [RUNW-1:0]   lc0_cr, lc1_cr, dc0_cr, dc1_cr;
    wire              dc0_f = swap_d ? f0_d : f1_d;     // bank E (even diagonal) cell
    wire              dc1_f = swap_d ? f1_d : f0_d;     // bank O (odd diagonal) cell
    wire              dc0_u = swap_d ? u0_d : u1_d;
    wire              dc1_u = swap_d ? u1_d : u0_d;

    jrp_run_cell #(.IW(IW), .RUNW(RUNW)) u_lc0 (.st_in(lamA_rd), .cur_fid(cur_fid), .i(i_d), .im1(im1_d),
        .f(fe0_d), .minlen(v_min[RUNW-1:0]), .st_out(lc0_st), .close_v(lc0_cv), .close_run(lc0_cr));
    jrp_run_cell #(.IW(IW), .RUNW(RUNW)) u_lc1 (.st_in(lamB_rd), .cur_fid(cur_fid), .i(i_d), .im1(im1_d),
        .f(fe1_d), .minlen(v_min[RUNW-1:0]), .st_out(lc1_st), .close_v(lc1_cv), .close_run(lc1_cr));
    jrp_run_cell #(.IW(IW), .RUNW(RUNW)) u_dc0 (.st_in(detE_rd), .cur_fid(cur_fid), .i(i_d), .im1(im1_d),
        .f(dc0_f), .minlen(l_min[RUNW-1:0]), .st_out(dc0_st), .close_v(dc0_cv), .close_run(dc0_cr));
    jrp_run_cell #(.IW(IW), .RUNW(RUNW)) u_dc1 (.st_in(detO_rd), .cur_fid(cur_fid), .i(i_d), .im1(im1_d),
        .f(dc1_f), .minlen(l_min[RUNW-1:0]), .st_out(dc1_st), .close_v(dc1_cv), .close_run(dc1_cr));

    // ---------------- events (registered) and histograms ----------------
    reg            evL0_v, evL1_v, evD0_v, evD1_v;
    reg [RUNW-1:0] evL0_r, evL1_r, evD0_r, evD1_r;

    function [AW_H-1:0] bin_of;
        input [RUNW-1:0] len;
        reg   [RUNW-1:0] c;
        begin
            c = (len < HIST_K) ? len : (HIST_K-1);
            bin_of = c[AW_H-1:0];
        end
    endfunction

    reg              hclr_we;
    reg [AW_H-1:0]   hclr_addr;
    wire             ext_rd_det = hist_rd_en && hist_ready && !hist_sel;
    wire             ext_rd_lam = hist_rd_en && hist_ready &&  hist_sel;
    wire [31:0]      hd0, hd1, hl0, hl1;
    wire             bd0, bd1, bl0, bl1;

    jrp_hist_unit #(.HIST_K(HIST_K), .HIST_W(HIST_W)) u_hd0 (.clk(clk), .rst_n(rst_n), .ev_v(evD0_v), .ev_idx(bin_of(evD0_r)),
        .clr_we(hclr_we), .clr_addr(hclr_addr), .rd_en(ext_rd_det), .rd_idx(hist_idx), .rd_data(hd0), .busy(bd0));
    jrp_hist_unit #(.HIST_K(HIST_K), .HIST_W(HIST_W)) u_hd1 (.clk(clk), .rst_n(rst_n), .ev_v(evD1_v), .ev_idx(bin_of(evD1_r)),
        .clr_we(hclr_we), .clr_addr(hclr_addr), .rd_en(ext_rd_det), .rd_idx(hist_idx), .rd_data(hd1), .busy(bd1));
    jrp_hist_unit #(.HIST_K(HIST_K), .HIST_W(HIST_W)) u_hl0 (.clk(clk), .rst_n(rst_n), .ev_v(evL0_v), .ev_idx(bin_of(evL0_r)),
        .clr_we(hclr_we), .clr_addr(hclr_addr), .rd_en(ext_rd_lam), .rd_idx(hist_idx), .rd_data(hl0), .busy(bl0));
    jrp_hist_unit #(.HIST_K(HIST_K), .HIST_W(HIST_W)) u_hl1 (.clk(clk), .rst_n(rst_n), .ev_v(evL1_v), .ev_idx(bin_of(evL1_r)),
        .clr_we(hclr_we), .clr_addr(hclr_addr), .rd_en(ext_rd_lam), .rd_idx(hist_idx), .rd_data(hl1), .busy(bl1));

    assign hist_ready = !(bd0 | bd1 | bl0 | bl1 | evL0_v | evL1_v | evD0_v | evD1_v);

    reg hist_sel_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) hist_sel_q <= 1'b0;
        else if (ext_rd_det | ext_rd_lam) hist_sel_q <= hist_sel;
    end
    assign hist_rd_data = hist_sel_q ? (hl0 + hl1) : (hd0 + hd1);

    // ---------------- sweep state ----------------
    reg            sw_active, sw_phase;               // phase 0: columns, 1: diagonals
    reg [AW_J:0]   sw_idx, sw_last;
    reg [AW_J:0]   n_cl;                              // n_actual clamped to N_MAX
    reg            s1_v, s1_ph, s1_b;
    reg            s2_v, s2_ph, s2_b;
    reg [AWB-1:0]  s1_a, s2_a;
    reg [1:0]      mv_pipe;
    reg            mv_set;
    assign metrics_valid = mv_pipe[1];

    // sweep read-out (second stage): the selected bank's state word
    wire [STATEW-1:0] s2_st  = s2_ph ? (s2_b ? detO_rd : detE_rd) : (s2_b ? lamB_rd : lamA_rd);
    wire              s2_open = s2_st[STATEW-2] && (s2_st[STATEW-1] === cur_fid);
    wire [RUNW-1:0]   s2_run  = s2_st[RUNW-1:0];
    wire [RUNW-1:0]   s2_min  = s2_ph ? l_min[RUNW-1:0] : v_min[RUNW-1:0];
    wire [STATEW-1:0] closed_st = {cur_fid, 1'b0, {IW{1'b0}}, {RUNW{1'b0}}};

    wire [RUNW-1:0] ev_zero = {RUNW{1'b0}};
    wire [16:0] lam_add_run = (evL0_v ? {1'b0, evL0_r} : 17'd0) + (evL1_v ? {1'b0, evL1_r} : 17'd0);
    wire [16:0] det_add_run = (evD0_v ? {1'b0, evD0_r} : 17'd0) + (evD1_v ? {1'b0, evD1_r} : 17'd0);
    wire [RUNW-1:0] lam_ev_max = (evL0_v && (!evL1_v || evL0_r >= evL1_r)) ? evL0_r : (evL1_v ? evL1_r : ev_zero);
    wire [RUNW-1:0] det_ev_max = (evD0_v && (!evD1_v || evD0_r >= evD1_r)) ? evD0_r : (evD1_v ? evD1_r : ev_zero);

    reg [AW_H:0] clr_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_main <= ST_RUN; cur_fid <= 1'b0; finalized_once <= 1'b0; finalize_req <= 1'b0;
            cells_accepted <= 32'd0;
            rr_count <= 64'd0; det_points <= 64'd0; det_lines <= 32'd0; l_max <= {RUNW{1'b0}};
            lam_points <= 64'd0; lam_lines <= 32'd0; v_max <= {RUNW{1'b0}};
            lam_raddr <= {AWB{1'b0}}; detE_raddr <= {AWB{1'b0}}; detO_raddr <= {AWB{1'b0}};
            lamA_we <= 1'b0; lamB_we <= 1'b0; detE_we <= 1'b0; detO_we <= 1'b0;
            lamA_wa <= {AWB{1'b0}}; lamB_wa <= {AWB{1'b0}}; detE_wa <= {AWB{1'b0}}; detO_wa <= {AWB{1'b0}};
            lamA_wd <= {STATEW{1'b0}}; lamB_wd <= {STATEW{1'b0}}; detE_wd <= {STATEW{1'b0}}; detO_wd <= {STATEW{1'b0}};
            had_read_q <= 1'b0; had_read_d <= 1'b0;
            i_q <= 0; im1_q <= 0; i_d <= 0; im1_d <= 0;
            fe0_q <= 0; fe1_q <= 0; v1_q <= 0; swap_q <= 0; u0_q <= 0; u1_q <= 0; f0_q <= 0; f1_q <= 0;
            fe0_d <= 0; fe1_d <= 0; v1_d <= 0; swap_d <= 0; u0_d <= 0; u1_d <= 0; f0_d <= 0; f1_d <= 0;
            la_q <= 0; la_d <= 0; dE_q <= 0; dE_d <= 0; dO_q <= 0; dO_d <= 0;
            evL0_v <= 0; evL1_v <= 0; evD0_v <= 0; evD1_v <= 0;
            evL0_r <= 0; evL1_r <= 0; evD0_r <= 0; evD1_r <= 0;
            hclr_we <= 1'b0; hclr_addr <= {AW_H{1'b0}}; clr_cnt <= 0;
            sw_active <= 1'b0; sw_phase <= 1'b0; sw_idx <= 0; sw_last <= 0; n_cl <= 0;
            s1_v <= 0; s1_ph <= 0; s1_b <= 0; s1_a <= 0; s2_v <= 0; s2_ph <= 0; s2_b <= 0; s2_a <= 0;
            mv_pipe <= 2'b00; mv_set <= 1'b0;
        end else begin
            // defaults
            lamA_we <= 1'b0; lamB_we <= 1'b0; detE_we <= 1'b0; detO_we <= 1'b0;
            evL0_v <= 1'b0; evL1_v <= 1'b0; evD0_v <= 1'b0; evD1_v <= 1'b0;
            hclr_we <= 1'b0;
            mv_pipe <= {mv_pipe[0], mv_set};
            mv_set  <= 1'b0;

            // ---- counters from the registered events ----
            if (evL0_v | evL1_v) begin
                lam_points <= lam_points + {47'd0, lam_add_run};
                lam_lines  <= lam_lines + {31'd0, evL0_v} + {31'd0, evL1_v};
                if (lam_ev_max > v_max) v_max <= lam_ev_max;
            end
            if (evD0_v | evD1_v) begin
                det_points <= det_points + {47'd0, det_add_run};
                det_lines  <= det_lines + {31'd0, evD0_v} + {31'd0, evD1_v};
                if (det_ev_max > l_max) l_max <= det_ev_max;
            end

            // ---- new frame ----
            if (frame_start) begin
                finalize_req   <= 1'b0;
                had_read_q     <= 1'b0;
                had_read_d     <= 1'b0;
                cur_fid        <= ~cur_fid;
                rr_count       <= 64'd0;
                lam_points     <= 64'd0; lam_lines <= 32'd0; v_max <= {RUNW{1'b0}};
                det_points     <= 64'd0; det_lines <= 32'd0; l_max <= {RUNW{1'b0}};
                cells_accepted <= 32'd0;
                finalized_once <= 1'b0;
                n_cl           <= (n_actual > N_MAX) ? N_MAX[AW_J:0] : n_actual[AW_J:0];
                st_main        <= ST_HIST_CLR;
                clr_cnt        <= 0;
            end

            case (st_main)
            // ---------------------------------------------------------------
            ST_RUN: begin
                had_read_d <= had_read_q;
                if (had_read_q) begin
                    i_d <= i_q; im1_d <= im1_q; fe0_d <= fe0_q; fe1_d <= fe1_q; v1_d <= v1_q; swap_d <= swap_q;
                    u0_d <= u0_q; u1_d <= u1_q; f0_d <= f0_q; f1_d <= f1_q;
                    la_d <= la_q; dE_d <= dE_q; dO_d <= dO_q;
                end
                had_read_q <= 1'b0;

                if (s_axis_tvalid && s_axis_tready) begin
                    i_q <= in_i; im1_q <= in_im1; fe0_q <= fe0; fe1_q <= fe1; v1_q <= in_v1; swap_q <= in_d1[0];
                    u0_q <= use0; u1_q <= use1; f0_q <= in_f0; f1_q <= in_f1;
                    la_q <= in_j0[AWB:1]; dE_q <= in_d1[AWB:1]; dO_q <= in_d1m1[AWB:1];
                    lam_raddr  <= in_j0[AWB:1];
                    detE_raddr <= in_d1[AWB:1];
                    detO_raddr <= in_d1m1[AWB:1];
                    had_read_q <= 1'b1;
                    cells_accepted <= cells_accepted + 32'd1 + {31'd0, in_v1};
                    rr_count <= rr_count + {63'd0, fe0} + {63'd0, fe1};
                end

                if (had_read_d) begin
                    lamA_we <= 1'b1; lamA_wa <= la_d; lamA_wd <= lc0_st;
                    lamB_we <= v1_d; lamB_wa <= la_d; lamB_wd <= lc1_st;
                    detE_we <= dc0_u; detE_wa <= dE_d; detE_wd <= dc0_st;
                    detO_we <= dc1_u; detO_wa <= dO_d; detO_wd <= dc1_st;
                    evL0_v <= lc0_cv;               evL0_r <= lc0_cr;
                    evL1_v <= lc1_cv & v1_d;        evL1_r <= lc1_cr;
                    evD0_v <= dc0_cv & dc0_u;       evD0_r <= dc0_cr;
                    evD1_v <= dc1_cv & dc1_u;       evD1_r <= dc1_cr;
                end

                // finalisation trigger: all cells accepted and the pipeline drained
                if (!finalized_once && (cells_target != 0) && (cells_accepted == cells_target)) begin
                    if (had_read_q || had_read_d) finalize_req <= 1'b1;
                    else begin
                        st_main <= ST_SWEEP; finalized_once <= 1'b1; finalize_req <= 1'b0;
                        sw_active <= (n_cl != 0); sw_phase <= 1'b0; sw_idx <= 0; sw_last <= n_cl - 1'b1;
                    end
                end
                if (finalize_req && !had_read_q && !had_read_d) begin
                    st_main <= ST_SWEEP; finalized_once <= 1'b1; finalize_req <= 1'b0;
                    sw_active <= (n_cl != 0); sw_phase <= 1'b0; sw_idx <= 0; sw_last <= n_cl - 1'b1;
                end
            end

            // ---------------------------------------------------------------
            // Sweep: read every column state, then every diagonal state, one per cycle. An open run
            // is counted (if long enough) and the word is cleared. Stage 1: address issued. Stage 2:
            // data back, decide, write.
            ST_SWEEP: begin
                s1_v <= 1'b0;
                if (sw_active) begin
                    lam_raddr <= sw_idx[AWB:1]; detE_raddr <= sw_idx[AWB:1]; detO_raddr <= sw_idx[AWB:1];
                    s1_v <= 1'b1; s1_ph <= sw_phase; s1_b <= sw_idx[0]; s1_a <= sw_idx[AWB:1];
                    if (sw_idx == sw_last) begin
                        if (!sw_phase && n_cl >= 2) begin
                            sw_phase <= 1'b1; sw_idx <= 0; sw_last <= n_cl - 2'd2;
                        end else begin
                            sw_active <= 1'b0;
                        end
                    end else begin
                        sw_idx <= sw_idx + 1'b1;
                    end
                end
                s2_v <= s1_v; s2_ph <= s1_ph; s2_b <= s1_b; s2_a <= s1_a;
                if (s2_v && s2_open) begin
                    if (s2_run >= s2_min) begin
                        if (s2_ph) begin evD0_v <= 1'b1; evD0_r <= s2_run; end
                        else       begin evL0_v <= 1'b1; evL0_r <= s2_run; end
                    end
                    case ({s2_ph, s2_b})
                    2'b00: begin lamA_we <= 1'b1; lamA_wa <= s2_a; lamA_wd <= closed_st; end
                    2'b01: begin lamB_we <= 1'b1; lamB_wa <= s2_a; lamB_wd <= closed_st; end
                    2'b10: begin detE_we <= 1'b1; detE_wa <= s2_a; detE_wd <= closed_st; end
                    default: begin detO_we <= 1'b1; detO_wa <= s2_a; detO_wd <= closed_st; end
                    endcase
                end
                if (!sw_active && !s1_v && !s2_v) begin
                    st_main <= ST_RUN;
                    mv_set  <= 1'b1;
                end
            end

            // ---------------------------------------------------------------
            ST_HIST_CLR: begin
                hclr_we   <= 1'b1;
                hclr_addr <= clr_cnt[AW_H-1:0];
                if (clr_cnt == HIST_K-1) st_main <= ST_RUN;
                clr_cnt <= clr_cnt + 1'b1;
            end

            default: st_main <= ST_RUN;
            endcase
        end
    end
endmodule
