`timescale 1ns / 1ps
// L3 testbench: jrp_top driven only through its external interfaces, as the PS would.
//   1. program the control registers over AXI-Lite (and read them back)
//   2. write START, stream N_RAW {y, x} samples on the AXI-Stream port
//   3. wait for STATUS.metrics_valid, check the error bits are clear
//   4. read the integer counters and both histograms over the RQA AXI-Lite window
//   5. compare with the Phase 1 golden counters (full N x N scan)
// Plusargs: +PFX +CNT +N (joint vectors) +NS (samples per channel) +MX +MY +TX +TY +E2X +E2Y +HAS_Y
//           +FULLHIST=<0|1> (1: read all HIST_K bins of both histograms, else only bins up to 255)
module tb_jrp_top;
    parameter integer MAX_M = 6;
    parameter integer MAX_TAU = 16;
    parameter integer N_MAX = 8192;
    parameter integer HIST_K = 8192;
    parameter integer K = 1;
    localparam integer DW = 32, N_BITS = 14;

    reg clk = 0, rst_n = 0;
    always #3.333 clk = ~clk;

    string pfx, cnt_file;
    integer n, ns, mx, my, tx, ty, has_y, fullhist;
    reg [31:0] e2x, e2y;
    initial begin
        if (!$value$plusargs("PFX=%s", pfx)) begin $display("FAIL: +PFX missing"); $finish; end
        if (!$value$plusargs("CNT=%s", cnt_file)) begin $display("FAIL: +CNT missing"); $finish; end
        if (!$value$plusargs("N=%d", n)) begin $display("FAIL: +N missing"); $finish; end
        if (!$value$plusargs("NS=%d", ns)) begin $display("FAIL: +NS missing"); $finish; end
        if (!$value$plusargs("MX=%d", mx)) mx = 5;
        if (!$value$plusargs("MY=%d", my)) my = 5;
        if (!$value$plusargs("TX=%d", tx)) tx = 3;
        if (!$value$plusargs("TY=%d", ty)) ty = 3;
        if (!$value$plusargs("E2X=%h", e2x)) e2x = 0;
        if (!$value$plusargs("E2Y=%h", e2y)) e2y = 0;
        if (!$value$plusargs("HAS_Y=%d", has_y)) has_y = 1;
        if (!$value$plusargs("FULLHIST=%d", fullhist)) fullhist = 1;
    end

    // ---- DUT ports ----
    reg  [11:0] c_awaddr, c_araddr; reg c_awvalid, c_wvalid, c_bready, c_arvalid, c_rready; reg [31:0] c_wdata;
    wire c_awready, c_wready, c_bvalid, c_arready, c_rvalid; wire [31:0] c_rdata; wire [1:0] c_bresp, c_rresp;
    reg  [16:0] q_araddr; reg q_arvalid, q_rready;
    wire q_arready, q_rvalid; wire [31:0] q_rdata;
    reg  [2*DW-1:0] s_tdata; reg s_tvalid, s_tlast; wire s_tready;

    jrp_top #(.DATA_WIDTH(DW), .MAX_M(MAX_M), .MAX_TAU(MAX_TAU), .N_MAX(N_MAX), .N_BITS(N_BITS), .HIST_W(32), .HIST_K(HIST_K), .K(K)) dut (
        .clk(clk), .rst_n(rst_n), .ext_start(1'b0), .frame_busy(), .frame_done_pulse(), .frame_cfg_err(), .n_raw_o(),
        .s_axi_awaddr(c_awaddr), .s_axi_awvalid(c_awvalid), .s_axi_awready(c_awready),
        .s_axi_wdata(c_wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(c_wvalid), .s_axi_wready(c_wready),
        .s_axi_bresp(c_bresp), .s_axi_bvalid(c_bvalid), .s_axi_bready(c_bready),
        .s_axi_araddr(c_araddr), .s_axi_arvalid(c_arvalid), .s_axi_arready(c_arready),
        .s_axi_rdata(c_rdata), .s_axi_rresp(c_rresp), .s_axi_rvalid(c_rvalid), .s_axi_rready(c_rready),
        .s_axi_rqa_awaddr(17'd0), .s_axi_rqa_awvalid(1'b0), .s_axi_rqa_awready(), .s_axi_rqa_wdata(32'd0),
        .s_axi_rqa_wstrb(4'd0), .s_axi_rqa_wvalid(1'b0), .s_axi_rqa_wready(), .s_axi_rqa_bresp(),
        .s_axi_rqa_bvalid(), .s_axi_rqa_bready(1'b1),
        .s_axi_rqa_araddr(q_araddr), .s_axi_rqa_arvalid(q_arvalid), .s_axi_rqa_arready(q_arready),
        .s_axi_rqa_rdata(q_rdata), .s_axi_rqa_rresp(), .s_axi_rqa_rvalid(q_rvalid), .s_axi_rqa_rready(q_rready),
        .s_axis_samples_tdata(s_tdata), .s_axis_samples_tvalid(s_tvalid), .s_axis_samples_tready(s_tready),
        .s_axis_samples_tlast(s_tlast),
        .pm_awaddr(6'd0), .pm_awvalid(1'b0), .pm_awready(), .pm_wdata(32'd0), .pm_wstrb(4'd0), .pm_wvalid(1'b0),
        .pm_wready(), .pm_bresp(), .pm_bvalid(), .pm_bready(1'b1),
        .pm_araddr(6'd0), .pm_arvalid(1'b0), .pm_arready(), .pm_rdata(), .pm_rresp(), .pm_rvalid(), .pm_rready(1'b1));

    // ---- AXI-Lite tasks ----
    task cwrite(input [11:0] a, input [31:0] d);
        begin
            @(posedge clk); #1; c_awaddr = a; c_wdata = d; c_awvalid = 1; c_wvalid = 1;
            @(posedge clk); while (!(c_awready && c_wready)) @(posedge clk);
            #1; c_awvalid = 0; c_wvalid = 0;
            while (!c_bvalid) @(posedge clk);
            @(posedge clk); #1;
        end
    endtask
    task cread(input [11:0] a, output [31:0] d);
        begin
            @(posedge clk); #1; c_araddr = a; c_arvalid = 1;
            @(posedge clk); while (!c_arready) @(posedge clk);
            #1; c_arvalid = 0;
            while (!c_rvalid) @(posedge clk);
            d = c_rdata; @(posedge clk); #1;
        end
    endtask
    task qread(input [16:0] a, output [31:0] d);
        begin
            @(posedge clk); #1; q_araddr = a; q_arvalid = 1;
            @(posedge clk); while (!q_arready) @(posedge clk);
            #1; q_arvalid = 0;
            while (!q_rvalid) @(posedge clk);
            d = q_rdata; @(posedge clk); #1;
        end
    endtask

    // ---- data ----
    reg [31:0] sx [0:(1<<16)-1];
    reg [31:0] sy [0:(1<<16)-1];
    reg [31:0] cw [0:(1<<16)-1];
    reg [31:0] exp_det [0:HIST_K-1];
    reg [31:0] exp_lam [0:HIST_K-1];
    integer i, errors, cyc, t_start, t_done, hist_bins;
    reg [31:0] got, st, nx, ny, base_x, base_y, mxr, myr, txr, tyr;

    always @(posedge clk) cyc <= rst_n ? cyc + 1 : 0;

    task check(input string name, input [31:0] expv);
        begin
            if (got !== expv) begin errors = errors + 1; $display("MISMATCH %s: got %0d want %0d", name, got, expv); end
        end
    endtask

    initial begin
        errors = 0; cyc = 0;
        c_awvalid = 0; c_wvalid = 0; c_bready = 1; c_arvalid = 0; c_rready = 1; c_awaddr = 0; c_araddr = 0; c_wdata = 0;
        q_arvalid = 0; q_rready = 1; q_araddr = 0; s_tvalid = 0; s_tlast = 0; s_tdata = 0;
        #1;
        $readmemh({pfx, "_x.hex"}, sx);
        if (has_y) $readmemh({pfx, "_y.hex"}, sy);
        $readmemh(cnt_file, cw);
        for (i = 0; i < HIST_K; i = i + 1) begin exp_det[i] = 0; exp_lam[i] = 0; end
        for (i = 0; i < cw[7]; i = i + 1) exp_det[cw[9 + 2*i]] = cw[10 + 2*i];
        for (i = 0; i < cw[8]; i = i + 1) exp_lam[cw[9 + 2*cw[7] + 2*i]] = cw[10 + 2*cw[7] + 2*i];
        if (!has_y) begin my = 1; ty = 1; e2y = 32'hFFFFFFFF; end   // neutral second channel
        // joint length and end-alignment bases, as the driver computes them
        nx = ns - (mx-1)*tx; ny = ns - (my-1)*ty;
        base_x = nx - n; base_y = ny - n;

        repeat (5) begin @(posedge clk); #1; end
        rst_n = 1;
        repeat (3) begin @(posedge clk); #1; end

        cread(12'h048, got); check("ID", 32'h4A525031);
        cwrite(12'h008, ns);   cwrite(12'h00C, mx);   cwrite(12'h010, tx);   cwrite(12'h014, e2x);
        cwrite(12'h024, my);   cwrite(12'h028, ty);   cwrite(12'h02C, e2y);
        cwrite(12'h018, 2);    cwrite(12'h01C, 2);
        cwrite(12'h034, base_x); cwrite(12'h038, base_y); cwrite(12'h03C, n);
        cread(12'h00C, got); check("M_X readback", mx);
        cread(12'h02C, got); check("EPS2_Y readback", e2y);
        cread(12'h03C, got); check("N_JOINT readback", n);

        // start the frame and stream the samples
        cwrite(12'h000, 32'h1);
        t_start = cyc;
        for (i = 0; i < ns; i = i + 1) begin
            @(posedge clk); #1;
            s_tdata = {(has_y ? sy[i] : 32'd0), sx[i]}; s_tvalid = 1; s_tlast = (i == ns-1);
            while (!s_tready) begin @(posedge clk); #1; end
        end
        @(posedge clk); #1; s_tvalid = 0; s_tlast = 0;

        // wait for metrics_valid (STATUS bit 3)
        st = 0;
        i = 0;
        while (!st[3] && i < 400000) begin cread(12'h004, st); i = i + 1; repeat (200) @(posedge clk); end
        t_done = cyc;
        if (!st[3]) begin errors = errors + 1; $display("TIMEOUT waiting for metrics_valid"); end
        if (st[6:4] !== 3'b000) begin errors = errors + 1; $display("STATUS error bits set: %b", st[6:4]); end
        $display("start to metrics_valid: %0d cycles (samples %0d, n*n %0d, hist clear %0d)", t_done - t_start, ns, n*n, 2*HIST_K);
        cread(12'h04C, got); check("NX_VEC", nx);
        cread(12'h050, got); check("NY_VEC", ny);
        repeat (300) begin @(posedge clk); #1; end

        qread(17'h008, got); check("rr_count_lo", cw[0]);
        qread(17'h010, got); check("det_points_lo", cw[1]);
        qread(17'h018, got); check("det_lines", cw[2]);
        qread(17'h01C, got); check("l_max", cw[3]);
        qread(17'h020, got); check("lam_points_lo", cw[4]);
        qread(17'h028, got); check("lam_lines", cw[5]);
        qread(17'h02C, got); check("v_max", cw[6]);
        qread(17'h038, got); check("cells_accepted", n*n);
        hist_bins = fullhist ? HIST_K : 256;
        for (i = 0; i < hist_bins; i = i + 1) begin
            qread(17'h01000 + 4*i, got);
            if (got !== exp_det[i]) begin errors = errors + 1; if (errors < 12) $display("DET hist bin %0d: got %0d want %0d", i, got, exp_det[i]); end
        end
        for (i = 0; i < hist_bins; i = i + 1) begin
            qread(17'h01000 + 4*HIST_K + 4*i, got);
            if (got !== exp_lam[i]) begin errors = errors + 1; if (errors < 12) $display("LAM hist bin %0d: got %0d want %0d", i, got, exp_lam[i]); end
        end
        if (errors == 0) $display("PASS %s: counters and histograms match through the top level", pfx);
        else             $display("FAIL %s: %0d errors", pfx, errors);
        $finish;
    end
endmodule
