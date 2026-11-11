`timescale 1ns / 1ps
// Board-level testbench: jrp_board_core driven ONLY through its single AXI4-Lite port, exactly as the
// Vivado JTAG-to-AXI master will drive it on the AXU5EVB-P: configure, load the sample RAM through the
// feeder registers, start, wait, read the counters and histograms, compare with the Phase 1 golden values.
// Plusargs as tb_jrp_top (+PFX +CNT +N +NS +MX +MY +TX +TY +E2X +E2Y +HAS_Y +FULLHIST).
module tb_board_core;
    parameter integer MAX_M = 6;
    parameter integer HIST_K = 8192;
    parameter integer K = 1;

    localparam [19:0] CTRL = 20'h00000, RQA = 20'h20000, PERF = 20'h40000, FEED = 20'h60000, CLKC = 20'h80000;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;   // 100 MHz, the first board clock

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

    reg [19:0] awaddr, araddr; reg awvalid, wvalid, bready, arvalid, rready; reg [31:0] wdata;
    wire awready, wready, bvalid, arready, rvalid; wire [31:0] rdata; wire [1:0] bresp, rresp;

    jrp_board_core #(.MAX_M(MAX_M), .K(K)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready));

    task wr(input [19:0] a, input [31:0] d);
        begin
            @(posedge clk); #1; awaddr = a; wdata = d; awvalid = 1; wvalid = 1;
            @(posedge clk); while (!(awready && wready)) @(posedge clk);
            #1; awvalid = 0; wvalid = 0;
            while (!bvalid) @(posedge clk);
            @(posedge clk); #1;
        end
    endtask
    task rd(input [19:0] a, output [31:0] d);
        begin
            @(posedge clk); #1; araddr = a; arvalid = 1;
            @(posedge clk); while (!arready) @(posedge clk);
            #1; arvalid = 0;
            while (!rvalid) @(posedge clk);
            d = rdata; @(posedge clk); #1;
        end
    endtask

    reg [31:0] sx [0:(1<<16)-1];
    reg [31:0] sy [0:(1<<16)-1];
    reg [31:0] cw [0:(1<<16)-1];
    reg [31:0] exp_det [0:HIST_K-1];
    reg [31:0] exp_lam [0:HIST_K-1];
    integer i, errors, hist_bins, polls;
    reg [31:0] got, st, nx, ny, base_x, base_y, c0, c1, feed_cycles, t_start, t_load, t_pairs, t_cells, t_scan, t_total;

    task check(input string name, input [31:0] expv);
        begin
            if (got !== expv) begin errors = errors + 1; $display("MISMATCH %s: got %0d want %0d", name, got, expv); end
        end
    endtask

    initial begin
        errors = 0;
        awvalid = 0; wvalid = 0; bready = 1; arvalid = 0; rready = 1; awaddr = 0; araddr = 0; wdata = 0;
        #1;
        $readmemh({pfx, "_x.hex"}, sx);
        if (has_y) $readmemh({pfx, "_y.hex"}, sy);
        $readmemh(cnt_file, cw);
        for (i = 0; i < HIST_K; i = i + 1) begin exp_det[i] = 0; exp_lam[i] = 0; end
        for (i = 0; i < cw[7]; i = i + 1) exp_det[cw[9 + 2*i]] = cw[10 + 2*i];
        for (i = 0; i < cw[8]; i = i + 1) exp_lam[cw[9 + 2*cw[7] + 2*i]] = cw[10 + 2*cw[7] + 2*i];
        if (!has_y) begin my = 1; ty = 1; e2y = 32'hFFFFFFFF; end
        nx = ns - (mx-1)*tx; ny = ns - (my-1)*ty; base_x = nx - n; base_y = ny - n;

        repeat (5) begin @(posedge clk); #1; end
        rst_n = 1;
        repeat (3) begin @(posedge clk); #1; end

        // ---- identification and clock counter ----
        rd(CTRL + 20'h048, got); check("ID", 32'h4A525031);
        rd(CLKC + 20'h0, c0); repeat (50) @(posedge clk); rd(CLKC + 20'h0, c1);
        if (c1 <= c0) begin errors = errors + 1; $display("clock counter not running: %0d -> %0d", c0, c1); end
        rd(PERF + 20'h0, got);   // performance monitor reachable (value not checked)

        // ---- configure ----
        wr(CTRL + 20'h008, ns);  wr(CTRL + 20'h00C, mx);  wr(CTRL + 20'h010, tx);  wr(CTRL + 20'h014, e2x);
        wr(CTRL + 20'h024, my);  wr(CTRL + 20'h028, ty);  wr(CTRL + 20'h02C, e2y);
        wr(CTRL + 20'h018, 2);   wr(CTRL + 20'h01C, 2);
        wr(CTRL + 20'h034, base_x); wr(CTRL + 20'h038, base_y); wr(CTRL + 20'h03C, n);
        rd(CTRL + 20'h02C, got); check("EPS2_Y readback", e2y);

        // ---- load the sample RAM through the feeder ----
        wr(FEED + 20'h00, 32'h2);   // reset the write pointer
        for (i = 0; i < ns; i = i + 1) begin
            wr(FEED + 20'h0C, sx[i]);
            wr(FEED + 20'h10, has_y ? sy[i] : 32'd0);
        end
        wr(FEED + 20'h08, ns);
        rd(FEED + 20'h04, got);
        if (got[31:16] !== ns[15:0]) begin errors = errors + 1; $display("feeder write pointer %0d, want %0d", got[31:16], ns); end

        // ---- start the frame, then the stream (the perf monitor is armed first) ----
        wr(PERF + 20'h000, 32'h2);   // clear
        wr(PERF + 20'h000, 32'h1);   // start: latches T_START
        wr(CTRL + 20'h000, 32'h1);
        wr(FEED + 20'h00, 32'h1);
        st = 0; polls = 0;
        while (!st[3] && polls < 4000) begin rd(CTRL + 20'h004, st); polls = polls + 1; repeat (500) @(posedge clk); end
        if (!st[3]) begin errors = errors + 1; $display("TIMEOUT waiting for metrics_valid"); end
        if (st[6:4] !== 3'b000) begin errors = errors + 1; $display("STATUS error bits set: %b", st[6:4]); end
        rd(FEED + 20'h14, feed_cycles);
        $display("feeder stream took %0d cycles for %0d beats", feed_cycles, ns);
        if (feed_cycles < ns || feed_cycles > ns + 8) begin errors = errors + 1; $display("stream duration out of range"); end
        rd(FEED + 20'h04, got);
        if (got[1] !== 1'b1) begin errors = errors + 1; $display("feeder done flag not set"); end
        repeat (300) begin @(posedge clk); #1; end

        // ---- performance monitor: hardware cycle counts of the frame ----
        rd(PERF + 20'h000, got);
        if (got[1:0] !== 2'b10) begin errors = errors + 1; $display("perf monitor status %b, want done and not armed", got[1:0]); end
        rd(PERF + 20'h018, t_start); rd(PERF + 20'h020, t_load); rd(PERF + 20'h028, t_pairs);
        rd(PERF + 20'h030, t_cells); rd(PERF + 20'h038, t_scan); rd(PERF + 20'h00C, t_total);
        $display("perf: ingest+embed %0d, scan start to last pair %0d, to last flag %0d, flags to metrics %0d, total %0d cycles",
                 t_load - t_start, t_pairs - t_load, t_cells - t_load, t_scan - t_cells, t_total);
        if ((t_cells - t_load) < n*n || (t_cells - t_load) > n*n + 2*HIST_K + 64) begin
            errors = errors + 1; $display("scan duration %0d outside [%0d, %0d]", t_cells - t_load, n*n, n*n + 2*HIST_K + 64);
        end
        if (t_total != (t_scan - t_start)) begin errors = errors + 1; $display("total cycles register inconsistent"); end

        // ---- counters and histograms ----
        rd(RQA + 20'h008, got); check("rr_count_lo", cw[0]);
        rd(RQA + 20'h010, got); check("det_points_lo", cw[1]);
        rd(RQA + 20'h018, got); check("det_lines", cw[2]);
        rd(RQA + 20'h01C, got); check("l_max", cw[3]);
        rd(RQA + 20'h020, got); check("lam_points_lo", cw[4]);
        rd(RQA + 20'h028, got); check("lam_lines", cw[5]);
        rd(RQA + 20'h02C, got); check("v_max", cw[6]);
        rd(RQA + 20'h038, got); check("cells_accepted", n*n);
        hist_bins = fullhist ? HIST_K : 256;
        for (i = 0; i < hist_bins; i = i + 1) begin
            rd(RQA + 20'h01000 + 4*i, got);
            if (got !== exp_det[i]) begin errors = errors + 1; if (errors < 12) $display("DET hist bin %0d: got %0d want %0d", i, got, exp_det[i]); end
        end
        for (i = 0; i < hist_bins; i = i + 1) begin
            rd(RQA + 20'h01000 + 4*HIST_K + 4*i, got);
            if (got !== exp_lam[i]) begin errors = errors + 1; if (errors < 12) $display("LAM hist bin %0d: got %0d want %0d", i, got, exp_lam[i]); end
        end
        if (errors == 0) $display("PASS %s: board core, counters and histograms match", pfx);
        else             $display("FAIL %s: %0d errors", pfx, errors);
        $finish;
    end
endmodule
