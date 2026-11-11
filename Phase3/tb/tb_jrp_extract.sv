`timescale 1ns / 1ps
// Self-checking L2/L3 testbench: vector memories + jrp_scan_engine + the released
// RQA_extractor_axi, read back over AXI-Lite like the PS would. Compares the integer counters
// and both full histograms with the Phase 1 golden counters (full N x N scan).
// Plusargs as tb_jrp_scan_engine, plus +CNT=<path of <case>_counters.hex>.
module tb_jrp_extract;
    parameter integer MAX_M = 6;
    parameter integer N_MAX = 1024;
    parameter integer HIST_K = 8192;
    localparam integer DW = 32, N_BITS = 14, VECW = DW*MAX_M;

    reg clk = 0, rst_n = 0;
    always #3.333 clk = ~clk;

    string pfx, cnt_file;
    integer n, mx, my, has_y;
    reg [31:0] e2x, e2y;
    initial begin
        if (!$value$plusargs("PFX=%s", pfx)) begin $display("FAIL: +PFX missing"); $finish; end
        if (!$value$plusargs("CNT=%s", cnt_file)) begin $display("FAIL: +CNT missing"); $finish; end
        if (!$value$plusargs("N=%d", n)) begin $display("FAIL: +N missing"); $finish; end
        if (!$value$plusargs("MX=%d", mx)) mx = 5;
        if (!$value$plusargs("MY=%d", my)) my = 5;
        if (!$value$plusargs("E2X=%h", e2x)) e2x = 0;
        if (!$value$plusargs("E2Y=%h", e2y)) e2y = 0;
        if (!$value$plusargs("HAS_Y=%d", has_y)) has_y = 1;
    end

    // ---- memories ----
    reg  [VECW-1:0] sx_data, sy_data;
    reg             s_valid, frame_start_mem;
    wire [31:0]     nlx, nly;
    wire            rd_en_ax, rd_en_bx, rd_en_ay, rd_en_by;
    wire [31:0]     rd_idx_ax, rd_idx_bx, rd_idx_ay, rd_idx_by;
    wire [VECW-1:0] vec_ax, vec_bx, vec_ay, vec_by;
    wire            vax_v, vbx_v, vay_v, vby_v;
    jrp_vector_buffer #(.DATA_WIDTH(DW), .MAX_M(MAX_M), .N_MAX(N_MAX)) u_vbx (
        .clk(clk), .rst_n(rst_n), .frame_start(frame_start_mem),
        .s_vec_tdata(sx_data), .s_vec_tvalid(s_valid), .s_vec_tready(), .n_loaded(nlx),
        .rd_en_a(rd_en_ax), .rd_idx_a(rd_idx_ax), .vec_a(vec_ax), .vec_a_valid(vax_v),
        .rd_en_b(rd_en_bx), .rd_idx_b(rd_idx_bx), .vec_b(vec_bx), .vec_b_valid(vbx_v));
    jrp_vector_buffer #(.DATA_WIDTH(DW), .MAX_M(MAX_M), .N_MAX(N_MAX)) u_vby (
        .clk(clk), .rst_n(rst_n), .frame_start(frame_start_mem),
        .s_vec_tdata(sy_data), .s_vec_tvalid(s_valid), .s_vec_tready(), .n_loaded(nly),
        .rd_en_a(rd_en_ay), .rd_idx_a(rd_idx_ay), .vec_a(vec_ay), .vec_a_valid(vay_v),
        .rd_en_b(rd_en_by), .rd_idx_b(rd_idx_by), .vec_b(vec_by), .vec_b_valid(vby_v));

    // ---- scan engine -> extractor ----
    reg  start;
    reg  [31:0] n_r, mx_r, my_r, e2x_r, e2y_r;
    wire [2*N_BITS:0] tdata; wire tvalid, tready, pairs_done, cells_done, lost_err, align_err;
    jrp_scan_engine #(.DATA_WIDTH(DW), .MAX_M(MAX_M), .N_BITS(N_BITS)) u_eng (
        .clk(clk), .rst_n(rst_n), .start(start), .n(n_r), .base_x(32'd0), .base_y(32'd0),
        .m_x(mx_r[7:0]), .m_y(my_r[7:0]), .eps2_x(e2x_r), .eps2_y(e2y_r),
        .rd_en_ax(rd_en_ax), .rd_idx_ax(rd_idx_ax), .vec_ax(vec_ax), .vec_ax_valid(vax_v),
        .rd_en_bx(rd_en_bx), .rd_idx_bx(rd_idx_bx), .vec_bx(vec_bx), .vec_bx_valid(vbx_v),
        .rd_en_ay(rd_en_ay), .rd_idx_ay(rd_idx_ay), .vec_ay(vec_ay), .vec_ay_valid(vay_v),
        .rd_en_by(rd_en_by), .rd_idx_by(rd_idx_by), .vec_by(vec_by), .vec_by_valid(vby_v),
        .m_axis_tdata(tdata), .m_axis_tvalid(tvalid), .m_axis_tready(tready),
        .pairs_done_pulse(pairs_done), .cells_done_pulse(cells_done),
        .lost_err(lost_err), .align_err(align_err));

    reg  rqa_frame_start;
    reg  [31:0] cells_target;
    reg  [16:0] araddr; reg arvalid; wire arready; wire [31:0] rdata; wire rvalid; reg rready;
    wire metrics_valid;
`ifdef RELEASED_EXTRACTOR
    RQA_extractor_axi #(.N_MAX(8192), .N_BITS(N_BITS), .RUNW(16), .ENABLE_HIST(1), .HIST_W(32), .HIST_K(HIST_K)) u_rqa (
        .clk(clk), .rst_n(rst_n), .frame_start(rqa_frame_start), .cells_target(cells_target), .n_actual(n_r),
        .s_axis_tdata(tdata), .s_axis_tvalid(tvalid), .s_axis_tready(tready),
        .s_axi_awaddr(17'd0), .s_axi_awvalid(1'b0), .s_axi_awready(), .s_axi_wdata(32'd0), .s_axi_wstrb(4'd0),
        .s_axi_wvalid(1'b0), .s_axi_wready(), .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b1),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .l_min(32'd2), .v_min(32'd2), .metrics_valid_pulse(metrics_valid));
`else
    jrp_rqa_extractor_axi #(.N_MAX(8192), .N_BITS(N_BITS), .RUNW(16), .ENABLE_HIST(1), .HIST_W(32), .HIST_K(HIST_K)) u_rqa (
        .clk(clk), .rst_n(rst_n), .frame_start(rqa_frame_start), .cells_target(cells_target), .n_actual(n_r),
        .s_axis_tdata(tdata), .s_axis_tvalid(tvalid), .s_axis_tready(tready),
        .s_axi_awaddr(17'd0), .s_axi_awvalid(1'b0), .s_axi_awready(), .s_axi_wdata(32'd0), .s_axi_wstrb(4'd0),
        .s_axi_wvalid(1'b0), .s_axi_wready(), .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b1),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .l_min(32'd2), .v_min(32'd2), .metrics_valid_pulse(metrics_valid));
`endif

    // ---- data ----
    reg [31:0] wx [0:(1<<18)-1];
    reg [31:0] wy [0:(1<<18)-1];
    reg [31:0] cw [0:(1<<16)-1];
    integer i, k, errors, cyc, t0, t_valid;
    reg [VECW-1:0] bus;
    reg [31:0] got;
    reg [31:0] exp_det [0:HIST_K-1];
    reg [31:0] exp_lam [0:HIST_K-1];
    reg saw_metrics;

    always @(posedge clk) cyc <= rst_n ? cyc + 1 : 0;
    always @(posedge clk) if (metrics_valid) begin saw_metrics = 1; t_valid = cyc; end

    task axi_read(input [16:0] addr, output [31:0] data);
        begin
            @(posedge clk); #1; araddr = addr; arvalid = 1;
            @(posedge clk); while (!arready) @(posedge clk);
            #1; arvalid = 0;
            while (!rvalid) @(posedge clk);
            data = rdata;
            @(posedge clk); #1;
        end
    endtask

    task check(input string name, input [31:0] expv);
        begin
            if (got !== expv) begin errors = errors + 1; $display("MISMATCH %s: got %0d want %0d", name, got, expv); end
        end
    endtask

    initial begin
        errors = 0; saw_metrics = 0; cyc = 0; t_valid = -1;
        s_valid = 0; frame_start_mem = 0; start = 0; rqa_frame_start = 0; sx_data = 0; sy_data = 0;
        arvalid = 0; araddr = 0; rready = 1; cells_target = 0;
        #1;
        n_r = n; mx_r = mx; my_r = my; e2x_r = e2x; e2y_r = e2y;
        if (!has_y) begin my_r = 1; e2y_r = 32'hFFFFFFFF; end
        $readmemh({pfx, "_vec_x.hex"}, wx);
        if (has_y) $readmemh({pfx, "_vec_y.hex"}, wy);
        $readmemh(cnt_file, cw);
        for (i = 0; i < HIST_K; i = i + 1) begin exp_det[i] = 0; exp_lam[i] = 0; end
        for (i = 0; i < cw[7]; i = i + 1) exp_det[cw[9 + 2*i]] = cw[10 + 2*i];
        for (i = 0; i < cw[8]; i = i + 1) exp_lam[cw[9 + 2*cw[7] + 2*i]] = cw[10 + 2*cw[7] + 2*i];

        repeat (5) begin @(posedge clk); #1; end
        rst_n = 1;
        repeat (3) begin @(posedge clk); #1; end
        frame_start_mem = 1; @(posedge clk); #1; frame_start_mem = 0;
        for (i = 0; i < n; i = i + 1) begin
            bus = 0; for (k = 0; k < mx; k = k + 1) bus[k*DW +: DW] = wx[i*mx + k];
            sx_data = bus;
            bus = 0; if (has_y) for (k = 0; k < my; k = k + 1) bus[k*DW +: DW] = wy[i*my + k];
            sy_data = bus;
            s_valid = 1; @(posedge clk); #1;
        end
        s_valid = 0;
        repeat (6) begin @(posedge clk); #1; end

        // frame: extractor and scan start together; the extractor clears its histograms first,
        // during which tready is low and the engine waits
        cells_target = n * n;
        rqa_frame_start = 1; start = 1; @(posedge clk); #1; rqa_frame_start = 0; start = 0;
        t0 = cyc;
        k = 0;
        while (!saw_metrics && k < 3*HIST_K*2 + 2*n*n + 20000) begin @(posedge clk); k = k + 1; end
        if (!saw_metrics) begin errors = errors + 1; $display("TIMEOUT: metrics_valid never asserted"); end
        $display("frame took %0d cycles (n*n = %0d, histogram clear = %0d)", t_valid - t0, n*n, 2*HIST_K);
        repeat (300) begin @(posedge clk); #1; end

        // read counters
        axi_read(17'h008, got); check("rr_count_lo", cw[0]);
        axi_read(17'h00C, got); check("rr_count_hi", 0);
        axi_read(17'h010, got); check("det_points_lo", cw[1]);
        axi_read(17'h018, got); check("det_lines", cw[2]);
        axi_read(17'h01C, got); check("l_max", cw[3]);
        axi_read(17'h020, got); check("lam_points_lo", cw[4]);
        axi_read(17'h028, got); check("lam_lines", cw[5]);
        axi_read(17'h02C, got); check("v_max", cw[6]);
        axi_read(17'h038, got); check("cells_accepted", n*n);
        // read both histograms completely
        for (i = 0; i < HIST_K; i = i + 1) begin
            axi_read(17'h01000 + 4*i, got);
            if (got !== exp_det[i]) begin errors = errors + 1; if (errors < 12) $display("DET hist bin %0d: got %0d want %0d", i, got, exp_det[i]); end
        end
        for (i = 0; i < HIST_K; i = i + 1) begin
            axi_read(17'h01000 + 4*HIST_K + 4*i, got);
            if (got !== exp_lam[i]) begin errors = errors + 1; if (errors < 12) $display("LAM hist bin %0d: got %0d want %0d", i, got, exp_lam[i]); end
        end
        if (lost_err)  begin errors = errors + 1; $display("lost_err set"); end
        if (align_err) begin errors = errors + 1; $display("align_err set"); end
        if (errors == 0) $display("PASS %s: counters and histograms match", pfx);
        else             $display("FAIL %s: %0d errors", pfx, errors);
        $finish;
    end
endmodule
