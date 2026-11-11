`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// jrp_top.v
//   Dual-channel joint recurrence plot and JRQA counters, full N x N scan (decision D1).
//   Extends the released RPs_bruteforce.v (Li, Lai and Oberst 2026, Zenodo
//   10.5281/zenodo.20406392, MIT); see docs/phase2_architecture.md for the specification.
//
//   Samples: one 64-bit AXI-Stream beat {y[31:0], x[31:0]} per time step (Q8.24 each).
//   Per frame: the PS writes the registers, writes START, streams N_RAW beats. Each channel is
//   embedded (m, tau) and stored in its own vector memory. When the last sample is in, the scan
//   engine streams all N_JOINT x N_JOINT pairs through two distance units, ANDs the flags and feeds
//   the RQA extractor. The PS reads the integer counters and histograms over the RQA AXI-Lite
//   window and forms the metrics (jrp.rqa.metrics_from_counters).
//   The driver computes N_JOINT = N_RAW - max((m_x-1) tau_x, (m_y-1) tau_y) and BASE_X/BASE_Y
//   (end alignment: base_x = n_x - N_JOINT with n_x = N_RAW - (m_x-1) tau_x, likewise y).
//   Reused unchanged from the release: distance_threshold_calculation
//   (inside jrp_lane), axi_perf_mon. Replaced: jrp_psr (the released embedding block corrupts vectors
//   after its history buffer wraps), jrp_vector_buffer, jrp_rqa_extractor(_axi) (histogram update),
//   jrp_axi_regs. New: jrp_pair_gen, jrp_lane, jrp_scan_engine, this module.
// -----------------------------------------------------------------------------
module jrp_top #(
    parameter integer DATA_WIDTH = 32,
    parameter integer MAX_M      = 6,
    parameter integer MAX_TAU    = 16,
    parameter integer N_MAX      = 8192,
    parameter integer N_BITS     = 14,
    parameter integer HIST_W     = 32,   // released default 14 saturates a bin at 16383 lines
    parameter integer HIST_K     = 8192,
    parameter integer K          = 1     // cells per cycle: 1 (one pair) or 2 (two adjacent cells of a row)
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Frame sequencer hooks (jrp_rt_ingest). ext_start acts like a write of START to the control block;
    // tie it low when the frame is started over AXI-Lite. The outputs are free for any user.
    input  wire                         ext_start,
    output wire                         frame_busy,        // ingest or scan in progress
    output wire                         frame_done_pulse,  // metrics valid (one cycle)
    output wire                         frame_cfg_err,     // last start was refused (bad N_JOINT / BASE)
    output wire [31:0]                  n_raw_o,           // N_RAW register

    // AXI-Lite control block
    input  wire [11:0]                  s_axi_awaddr,
    input  wire                         s_axi_awvalid,
    output wire                         s_axi_awready,
    input  wire [31:0]                  s_axi_wdata,
    input  wire [3:0]                   s_axi_wstrb,
    input  wire                         s_axi_wvalid,
    output wire                         s_axi_wready,
    output wire [1:0]                   s_axi_bresp,
    output wire                         s_axi_bvalid,
    input  wire                         s_axi_bready,
    input  wire [11:0]                  s_axi_araddr,
    input  wire                         s_axi_arvalid,
    output wire                         s_axi_arready,
    output wire [31:0]                  s_axi_rdata,
    output wire [1:0]                   s_axi_rresp,
    output wire                         s_axi_rvalid,
    input  wire                         s_axi_rready,

    // AXI-Lite RQA counters and histograms
    input  wire [16:0]                  s_axi_rqa_awaddr,
    input  wire                         s_axi_rqa_awvalid,
    output wire                         s_axi_rqa_awready,
    input  wire [31:0]                  s_axi_rqa_wdata,
    input  wire [3:0]                   s_axi_rqa_wstrb,
    input  wire                         s_axi_rqa_wvalid,
    output wire                         s_axi_rqa_wready,
    output wire [1:0]                   s_axi_rqa_bresp,
    output wire                         s_axi_rqa_bvalid,
    input  wire                         s_axi_rqa_bready,
    input  wire [16:0]                  s_axi_rqa_araddr,
    input  wire                         s_axi_rqa_arvalid,
    output wire                         s_axi_rqa_arready,
    output wire [31:0]                  s_axi_rqa_rdata,
    output wire [1:0]                   s_axi_rqa_rresp,
    output wire                         s_axi_rqa_rvalid,
    input  wire                         s_axi_rqa_rready,

    // AXI-Stream samples {y, x}
    input  wire [2*DATA_WIDTH-1:0]      s_axis_samples_tdata,
    input  wire                         s_axis_samples_tvalid,
    output wire                         s_axis_samples_tready,
    input  wire                         s_axis_samples_tlast,

    // Performance monitor AXI-Lite
    input  wire [5:0]                   pm_awaddr,
    input  wire                         pm_awvalid,
    output wire                         pm_awready,
    input  wire [31:0]                  pm_wdata,
    input  wire [3:0]                   pm_wstrb,
    input  wire                         pm_wvalid,
    output wire                         pm_wready,
    output wire [1:0]                   pm_bresp,
    output wire                         pm_bvalid,
    input  wire                         pm_bready,
    input  wire [5:0]                   pm_araddr,
    input  wire                         pm_arvalid,
    output wire                         pm_arready,
    output wire [31:0]                  pm_rdata,
    output wire [1:0]                   pm_rresp,
    output wire                         pm_rvalid,
    input  wire                         pm_rready
);
    localparam integer VECW = DATA_WIDTH*MAX_M;

    // ---------------- registers ----------------
    wire start_pulse_reg, soft_reset_pulse;
    wire start_pulse = start_pulse_reg | ext_start;
    wire [31:0] n_raw, eps2_x, eps2_y, l_min, v_min, cfg, base_x, base_y, n_joint;
    wire [7:0]  m_x, tau_x, m_y, tau_y;
    wire        eng_lost, eng_align;
    wire        ing_busy, scan_busy, metrics_valid_pulse;
    reg         metrics_valid_sticky;
    reg         cfg_err;
    wire [31:0] nx_vec, ny_vec;
    wire        psr_ready;

    jrp_axi_regs u_regs (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .start_pulse(start_pulse_reg), .soft_reset_pulse(soft_reset_pulse),
        .n_raw(n_raw), .m_x(m_x), .tau_x(tau_x), .eps2_x(eps2_x), .m_y(m_y), .tau_y(tau_y), .eps2_y(eps2_y),
        .l_min(l_min), .v_min(v_min), .cfg(cfg), .base_x(base_x), .base_y(base_y), .n_joint(n_joint),
        .psr_in_ready(psr_ready), .ing_busy(ing_busy), .scan_busy(scan_busy),
        .metrics_valid(metrics_valid_sticky), .lost_err(eng_lost), .align_err(eng_align), .cfg_err(cfg_err),
        .nx_vec(nx_vec), .ny_vec(ny_vec));

    // ---------------- embedding blocks (released module, one per channel) ----------------
    wire rdy_x, rdy_y;
    assign psr_ready = rdy_x & rdy_y;
    assign s_axis_samples_tready = psr_ready;
    wire samp_valid = s_axis_samples_tvalid & psr_ready;   // both blocks advance in lockstep

    wire [VECW-1:0] vec_x_in, vec_y_in;
    wire            vec_x_valid, vec_y_valid, vec_x_ready, vec_y_ready;
    wire            done_x, done_y;

    jrp_psr #(.DATA_WIDTH(DATA_WIDTH), .MAX_M(MAX_M), .MAX_TAU(MAX_TAU)) u_psr_x (
        .clk(clk), .rst_n(rst_n), .data_in(s_axis_samples_tdata[DATA_WIDTH-1:0]), .data_valid(samp_valid),
        .data_last(s_axis_samples_tlast), .data_ready(rdy_x), .m_dim(m_x), .tau_delay(tau_x),
        .vector_out(vec_x_in), .vector_valid(vec_x_valid), .vector_ready(vec_x_ready),
        .frame_start(start_pulse), .ingest_done_pulse(done_x), .n_actual(nx_vec), .n_target(n_raw));
    jrp_psr #(.DATA_WIDTH(DATA_WIDTH), .MAX_M(MAX_M), .MAX_TAU(MAX_TAU)) u_psr_y (
        .clk(clk), .rst_n(rst_n), .data_in(s_axis_samples_tdata[2*DATA_WIDTH-1:DATA_WIDTH]), .data_valid(samp_valid),
        .data_last(s_axis_samples_tlast), .data_ready(rdy_y), .m_dim(m_y), .tau_delay(tau_y),
        .vector_out(vec_y_in), .vector_valid(vec_y_valid), .vector_ready(vec_y_ready),
        .frame_start(start_pulse), .ingest_done_pulse(done_y), .n_actual(ny_vec), .n_target(n_raw));

    // ---------------- vector memories ----------------
    wire rd_en_ax, rd_en_bx, rd_en_ay, rd_en_by;
    wire [31:0] rd_idx_ax, rd_idx_bx, rd_idx_ay, rd_idx_by;
    wire [VECW-1:0] vec_ax, vec_bx, vec_ay, vec_by;
    wire vax_v, vbx_v, vay_v, vby_v;

    wire rd_en_cx, rd_en_cy;
    wire [31:0] rd_idx_cx, rd_idx_cy;
    wire [VECW-1:0] vec_cx, vec_cy;
    wire vcx_v, vcy_v;

    generate if (K == 2) begin : G_VEC2
        jrp_vector_buffer3 #(.DATA_WIDTH(DATA_WIDTH), .MAX_M(MAX_M), .N_MAX(N_MAX)) u_vbx (
            .clk(clk), .rst_n(rst_n), .frame_start(start_pulse),
            .s_vec_tdata(vec_x_in), .s_vec_tvalid(vec_x_valid), .s_vec_tready(vec_x_ready), .n_loaded(),
            .rd_en_a(rd_en_ax), .rd_idx_a(rd_idx_ax), .vec_a(vec_ax), .vec_a_valid(vax_v),
            .rd_en_b(rd_en_bx), .rd_idx_b(rd_idx_bx), .vec_b(vec_bx), .vec_b_valid(vbx_v),
            .rd_en_c(rd_en_cx), .rd_idx_c(rd_idx_cx), .vec_c(vec_cx), .vec_c_valid(vcx_v));
        jrp_vector_buffer3 #(.DATA_WIDTH(DATA_WIDTH), .MAX_M(MAX_M), .N_MAX(N_MAX)) u_vby (
            .clk(clk), .rst_n(rst_n), .frame_start(start_pulse),
            .s_vec_tdata(vec_y_in), .s_vec_tvalid(vec_y_valid), .s_vec_tready(vec_y_ready), .n_loaded(),
            .rd_en_a(rd_en_ay), .rd_idx_a(rd_idx_ay), .vec_a(vec_ay), .vec_a_valid(vay_v),
            .rd_en_b(rd_en_by), .rd_idx_b(rd_idx_by), .vec_b(vec_by), .vec_b_valid(vby_v),
            .rd_en_c(rd_en_cy), .rd_idx_c(rd_idx_cy), .vec_c(vec_cy), .vec_c_valid(vcy_v));
    end else begin : G_VEC1
        jrp_vector_buffer #(.DATA_WIDTH(DATA_WIDTH), .MAX_M(MAX_M), .N_MAX(N_MAX)) u_vbx (
            .clk(clk), .rst_n(rst_n), .frame_start(start_pulse),
            .s_vec_tdata(vec_x_in), .s_vec_tvalid(vec_x_valid), .s_vec_tready(vec_x_ready), .n_loaded(),
            .rd_en_a(rd_en_ax), .rd_idx_a(rd_idx_ax), .vec_a(vec_ax), .vec_a_valid(vax_v),
            .rd_en_b(rd_en_bx), .rd_idx_b(rd_idx_bx), .vec_b(vec_bx), .vec_b_valid(vbx_v));
        jrp_vector_buffer #(.DATA_WIDTH(DATA_WIDTH), .MAX_M(MAX_M), .N_MAX(N_MAX)) u_vby (
            .clk(clk), .rst_n(rst_n), .frame_start(start_pulse),
            .s_vec_tdata(vec_y_in), .s_vec_tvalid(vec_y_valid), .s_vec_tready(vec_y_ready), .n_loaded(),
            .rd_en_a(rd_en_ay), .rd_idx_a(rd_idx_ay), .vec_a(vec_ay), .vec_a_valid(vay_v),
            .rd_en_b(rd_en_by), .rd_idx_b(rd_idx_by), .vec_b(vec_by), .vec_b_valid(vby_v));
        assign rd_en_cx = 1'b0; assign rd_en_cy = 1'b0; assign rd_idx_cx = 32'd0; assign rd_idx_cy = 32'd0;
    end endgenerate

    // ---------------- frame sequencing ----------------
    // The embedding blocks pulse ingest_done when the last sample is accepted; two cycles later the
    // vector counts are final (as in the released top level). Then the scan and the extractor start.
    reg done_d1, done_d2, ing_active, scan_active;
    reg scan_start_pulse, rqa_frame_start;
    reg [31:0] cells_target_reg;
    wire [31:0] cells_target_calc = n_joint * n_joint;
    wire cfg_bad = ((base_x + n_joint) > nx_vec) || ((base_y + n_joint) > ny_vec) || (n_joint == 32'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_d1 <= 1'b0; done_d2 <= 1'b0; ing_active <= 1'b0; scan_active <= 1'b0;
            scan_start_pulse <= 1'b0; rqa_frame_start <= 1'b0; cells_target_reg <= 32'd0;
            cfg_err <= 1'b0; metrics_valid_sticky <= 1'b0;
        end else begin
            done_d1 <= done_x; done_d2 <= done_d1;
            scan_start_pulse <= 1'b0; rqa_frame_start <= 1'b0;
            if (start_pulse) begin
                ing_active <= 1'b1; cfg_err <= 1'b0; metrics_valid_sticky <= 1'b0; scan_active <= 1'b0;
            end
            if (done_d2) begin
                ing_active <= 1'b0;
                if (cfg_bad) begin
                    cfg_err <= 1'b1;                    // nothing to scan: refuse to start
                end else begin
                    scan_start_pulse <= 1'b1; rqa_frame_start <= 1'b1;
                    cells_target_reg <= cells_target_calc;
                    scan_active <= 1'b1;
                end
            end
            if (metrics_valid_pulse) begin scan_active <= 1'b0; metrics_valid_sticky <= 1'b1; end
        end
    end
    assign ing_busy  = ing_active;
    assign scan_busy = scan_active;
    assign frame_busy = ing_active | scan_active;
    assign frame_done_pulse = metrics_valid_pulse;
    assign frame_cfg_err = cfg_err;
    assign n_raw_o = n_raw;

    // ---------------- scan engine -> extractor ----------------
    wire flag_tvalid, flag_tready, pairs_done_pulse, cells_done_pulse;

    generate if (K == 2) begin : G_K2
        wire [2*N_BITS+2:0] flag_tdata;
        jrp_scan_engine_k2 #(.DATA_WIDTH(DATA_WIDTH), .MAX_M(MAX_M), .N_BITS(N_BITS)) u_engine (
            .clk(clk), .rst_n(rst_n), .start(scan_start_pulse), .n(n_joint), .base_x(base_x), .base_y(base_y),
            .m_x(m_x), .m_y(m_y), .eps2_x(eps2_x), .eps2_y(eps2_y),
            .rd_en_ax(rd_en_ax), .rd_idx_ax(rd_idx_ax), .vec_ax(vec_ax), .vec_ax_valid(vax_v),
            .rd_en_bx(rd_en_bx), .rd_idx_bx(rd_idx_bx), .vec_bx(vec_bx), .vec_bx_valid(vbx_v),
            .rd_en_cx(rd_en_cx), .rd_idx_cx(rd_idx_cx), .vec_cx(vec_cx), .vec_cx_valid(vcx_v),
            .rd_en_ay(rd_en_ay), .rd_idx_ay(rd_idx_ay), .vec_ay(vec_ay), .vec_ay_valid(vay_v),
            .rd_en_by(rd_en_by), .rd_idx_by(rd_idx_by), .vec_by(vec_by), .vec_by_valid(vby_v),
            .rd_en_cy(rd_en_cy), .rd_idx_cy(rd_idx_cy), .vec_cy(vec_cy), .vec_cy_valid(vcy_v),
            .m_axis_tdata(flag_tdata), .m_axis_tvalid(flag_tvalid), .m_axis_tready(flag_tready),
            .pairs_done_pulse(pairs_done_pulse), .cells_done_pulse(cells_done_pulse),
            .lost_err(eng_lost), .align_err(eng_align));

        jrp_rqa_extractor_k2_axi #(.N_MAX(N_MAX), .N_BITS(N_BITS), .RUNW(16), .ENABLE_HIST(1), .HIST_W(HIST_W), .HIST_K(HIST_K)) u_rqa (
            .clk(clk), .rst_n(rst_n), .frame_start(rqa_frame_start), .cells_target(cells_target_reg), .n_actual(n_joint),
            .s_axis_tdata(flag_tdata), .s_axis_tvalid(flag_tvalid), .s_axis_tready(flag_tready),
            .s_axi_awaddr(s_axi_rqa_awaddr), .s_axi_awvalid(s_axi_rqa_awvalid), .s_axi_awready(s_axi_rqa_awready),
            .s_axi_wdata(s_axi_rqa_wdata), .s_axi_wstrb(s_axi_rqa_wstrb), .s_axi_wvalid(s_axi_rqa_wvalid), .s_axi_wready(s_axi_rqa_wready),
            .s_axi_bresp(s_axi_rqa_bresp), .s_axi_bvalid(s_axi_rqa_bvalid), .s_axi_bready(s_axi_rqa_bready),
            .s_axi_araddr(s_axi_rqa_araddr), .s_axi_arvalid(s_axi_rqa_arvalid), .s_axi_arready(s_axi_rqa_arready),
            .s_axi_rdata(s_axi_rqa_rdata), .s_axi_rresp(s_axi_rqa_rresp), .s_axi_rvalid(s_axi_rqa_rvalid), .s_axi_rready(s_axi_rqa_rready),
            .l_min(l_min), .v_min(v_min), .metrics_valid_pulse(metrics_valid_pulse));
    end else begin : G_K1
        wire [2*N_BITS:0] flag_tdata;
        jrp_scan_engine #(.DATA_WIDTH(DATA_WIDTH), .MAX_M(MAX_M), .N_BITS(N_BITS)) u_engine (
            .clk(clk), .rst_n(rst_n), .start(scan_start_pulse), .n(n_joint), .base_x(base_x), .base_y(base_y),
            .m_x(m_x), .m_y(m_y), .eps2_x(eps2_x), .eps2_y(eps2_y),
            .rd_en_ax(rd_en_ax), .rd_idx_ax(rd_idx_ax), .vec_ax(vec_ax), .vec_ax_valid(vax_v),
            .rd_en_bx(rd_en_bx), .rd_idx_bx(rd_idx_bx), .vec_bx(vec_bx), .vec_bx_valid(vbx_v),
            .rd_en_ay(rd_en_ay), .rd_idx_ay(rd_idx_ay), .vec_ay(vec_ay), .vec_ay_valid(vay_v),
            .rd_en_by(rd_en_by), .rd_idx_by(rd_idx_by), .vec_by(vec_by), .vec_by_valid(vby_v),
            .m_axis_tdata(flag_tdata), .m_axis_tvalid(flag_tvalid), .m_axis_tready(flag_tready),
            .pairs_done_pulse(pairs_done_pulse), .cells_done_pulse(cells_done_pulse),
            .lost_err(eng_lost), .align_err(eng_align));

        jrp_rqa_extractor_axi #(.N_MAX(N_MAX), .N_BITS(N_BITS), .RUNW(16), .ENABLE_HIST(1), .HIST_W(HIST_W), .HIST_K(HIST_K)) u_rqa (
            .clk(clk), .rst_n(rst_n), .frame_start(rqa_frame_start), .cells_target(cells_target_reg), .n_actual(n_joint),
            .s_axis_tdata(flag_tdata), .s_axis_tvalid(flag_tvalid), .s_axis_tready(flag_tready),
            .s_axi_awaddr(s_axi_rqa_awaddr), .s_axi_awvalid(s_axi_rqa_awvalid), .s_axi_awready(s_axi_rqa_awready),
            .s_axi_wdata(s_axi_rqa_wdata), .s_axi_wstrb(s_axi_rqa_wstrb), .s_axi_wvalid(s_axi_rqa_wvalid), .s_axi_wready(s_axi_rqa_wready),
            .s_axi_bresp(s_axi_rqa_bresp), .s_axi_bvalid(s_axi_rqa_bvalid), .s_axi_bready(s_axi_rqa_bready),
            .s_axi_araddr(s_axi_rqa_araddr), .s_axi_arvalid(s_axi_rqa_arvalid), .s_axi_arready(s_axi_rqa_arready),
            .s_axi_rdata(s_axi_rqa_rdata), .s_axi_rresp(s_axi_rqa_rresp), .s_axi_rvalid(s_axi_rqa_rvalid), .s_axi_rready(s_axi_rqa_rready),
            .l_min(l_min), .v_min(v_min), .metrics_valid_pulse(metrics_valid_pulse));
    end endgenerate

    // ---------------- performance monitor (released module) ----------------
    axi_perf_mon u_perf (
        .clk(clk), .rst_n(rst_n),
        .load_end_pulse(rqa_frame_start), .pairs_end_pulse(pairs_done_pulse), .cells_end_pulse(cells_done_pulse),
        .scan_end_pulse(metrics_valid_pulse), .dtc_start_pulse(scan_start_pulse), .dtc_end_pulse(cells_done_pulse),
        .start_pulse_out(),
        .s_axi_awaddr(pm_awaddr), .s_axi_awvalid(pm_awvalid), .s_axi_awready(pm_awready),
        .s_axi_wdata(pm_wdata), .s_axi_wstrb(pm_wstrb), .s_axi_wvalid(pm_wvalid), .s_axi_wready(pm_wready),
        .s_axi_bresp(pm_bresp), .s_axi_bvalid(pm_bvalid), .s_axi_bready(pm_bready),
        .s_axi_araddr(pm_araddr), .s_axi_arvalid(pm_arvalid), .s_axi_arready(pm_arready),
        .s_axi_rdata(pm_rdata), .s_axi_rresp(pm_rresp), .s_axi_rvalid(pm_rvalid), .s_axi_rready(pm_rready));
endmodule
