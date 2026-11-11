`timescale 1ns / 1ps
// Extractor-only testbench for the K = 2 core: random recurrence matrices (gen_k2_random.py) streamed
// as {i, j0, f1, f0, v1} beats into jrp_rqa_extractor_k2_axi, counters and histograms read back over
// AXI-Lite and compared with the Phase 1 integer model. Many frames in one run, back to back, so
// stale-state bugs show up. For n <= 2 one idle cycle is left between beats, as jrp_pair_gen_k2 does.
// Plusargs: +DIR=<k2rand dir with manifest.txt>  +GAPS=1 (random idle cycles between beats)
module tb_k2_extract;
    parameter integer HIST_K = 8192;
    localparam integer N_BITS = 14;

    reg clk = 0, rst_n = 0;
    always #3.333 clk = ~clk;

    string dir;
    integer gaps;
    initial begin
        if (!$value$plusargs("DIR=%s", dir)) begin $display("FAIL: +DIR missing"); $finish; end
        if (!$value$plusargs("GAPS=%d", gaps)) gaps = 0;
    end

    reg  frame_start;
    reg  [31:0] cells_target, n_actual;
    reg  [2*N_BITS+2:0] tdata;
    reg  tvalid;
    wire tready;
    reg  [16:0] araddr; reg arvalid; wire arready; wire [31:0] rdata; wire rvalid; reg rready;
    wire metrics_valid;

    jrp_rqa_extractor_k2_axi #(.N_MAX(8192), .N_BITS(N_BITS), .RUNW(16), .ENABLE_HIST(1), .HIST_W(32), .HIST_K(HIST_K)) u_rqa (
        .clk(clk), .rst_n(rst_n), .frame_start(frame_start), .cells_target(cells_target), .n_actual(n_actual),
        .s_axis_tdata(tdata), .s_axis_tvalid(tvalid), .s_axis_tready(tready),
        .s_axi_awaddr(17'd0), .s_axi_awvalid(1'b0), .s_axi_awready(), .s_axi_wdata(32'd0), .s_axi_wstrb(4'd0),
        .s_axi_wvalid(1'b0), .s_axi_wready(), .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b1),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .l_min(32'd2), .v_min(32'd2), .metrics_valid_pulse(metrics_valid));

    reg [31:0] beats [0:(1<<17)-1];
    reg [31:0] cw [0:(1<<16)-1];
    reg [31:0] exp_det [0:HIST_K-1];
    reg [31:0] exp_lam [0:HIST_K-1];
    integer fd, rc, n, nb, i, k, b, errors, case_errors, ncases, nfail, cyc, t0, t_valid, kk, seed;
    string name;
    reg [31:0] got;
    reg saw_metrics;
    reg [31:0] rnd;

    integer dbg;
    initial if (!$value$plusargs("DBG=%d", dbg)) dbg = 0;
    always @(posedge clk) if (dbg) begin
        if (u_rqa.u_core.evL0_v | u_rqa.u_core.evL1_v) $display("%0t LAM ev0=%b run %0d ev1=%b run %0d", $time, u_rqa.u_core.evL0_v, u_rqa.u_core.evL0_r, u_rqa.u_core.evL1_v, u_rqa.u_core.evL1_r);
        if (u_rqa.u_core.evD0_v | u_rqa.u_core.evD1_v) $display("%0t DET ev0=%b run %0d ev1=%b run %0d", $time, u_rqa.u_core.evD0_v, u_rqa.u_core.evD0_r, u_rqa.u_core.evD1_v, u_rqa.u_core.evD1_r);
        if (u_rqa.u_core.s2_v) $display("%0t sweep s2 ph%b b%b a%0d open=%b run=%0d", $time, u_rqa.u_core.s2_ph, u_rqa.u_core.s2_b, u_rqa.u_core.s2_a, u_rqa.u_core.s2_open, u_rqa.u_core.s2_run);
    end
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

    task check(input string nm, input [31:0] expv);
        begin
            if (got !== expv) begin case_errors = case_errors + 1; if (case_errors < 8) $display("MISMATCH %s %s: got %0d want %0d", name, nm, got, expv); end
        end
    endtask

    initial begin
        errors = 0; ncases = 0; nfail = 0; cyc = 0; seed = 7;
        frame_start = 0; tvalid = 0; tdata = 0; arvalid = 0; araddr = 0; rready = 1; cells_target = 0; n_actual = 0;
        repeat (5) begin @(posedge clk); #1; end
        rst_n = 1;
        repeat (3) begin @(posedge clk); #1; end
        fd = $fopen({dir, "/manifest.txt"}, "r");
        if (fd == 0) begin $display("FAIL: cannot open manifest"); $finish; end
        while (!$feof(fd)) begin
            rc = $fscanf(fd, "%s %d %d\n", name, n, nb);
            if (rc != 3) break;
            case_errors = 0;
            for (i = 0; i < (1<<17); i = i + 1) beats[i] = 0;
            $readmemh({dir, "/", name, "_beats.hex"}, beats);
            $readmemh({dir, "/", name, "_counters.hex"}, cw);
            for (i = 0; i < HIST_K; i = i + 1) begin exp_det[i] = 0; exp_lam[i] = 0; end
            for (i = 0; i < cw[7]; i = i + 1) exp_det[cw[9 + 2*i]] = cw[10 + 2*i];
            for (i = 0; i < cw[8]; i = i + 1) exp_lam[cw[9 + 2*cw[7] + 2*i]] = cw[10 + 2*cw[7] + 2*i];

            saw_metrics = 0; t_valid = -1;
            n_actual = n; cells_target = n * n;
            frame_start = 1; @(posedge clk); #1; frame_start = 0;
            // stream
            for (b = 0; b < nb; b = b + 1) begin
                tdata = beats[b][2*N_BITS+2:0]; tvalid = 1;
                @(posedge clk);
                while (!tready) @(posedge clk);
                #1; tvalid = 0;
                if (n <= 2) begin @(posedge clk); #1; end
                if (gaps) begin
                    rnd = $urandom(seed + b);
                    if (rnd[2:0] == 0) begin repeat (rnd[5:3] + 1) begin @(posedge clk); #1; end end
                end
            end
            tvalid = 0;
            t0 = 0;
            while (!saw_metrics && t0 < 50000) begin @(posedge clk); t0 = t0 + 1; end
            if (!saw_metrics) begin case_errors = case_errors + 1; $display("TIMEOUT %s", name); end
            repeat (300) begin @(posedge clk); #1; end
            axi_read(17'h008, got); check("rr_count_lo", cw[0]);
            axi_read(17'h010, got); check("det_points_lo", cw[1]);
            axi_read(17'h018, got); check("det_lines", cw[2]);
            axi_read(17'h01C, got); check("l_max", cw[3]);
            axi_read(17'h020, got); check("lam_points_lo", cw[4]);
            axi_read(17'h028, got); check("lam_lines", cw[5]);
            axi_read(17'h02C, got); check("v_max", cw[6]);
            axi_read(17'h038, got); check("cells_accepted", n*n);
            for (i = 0; i <= n + 2 && i < HIST_K; i = i + 1) begin
                axi_read(17'h01000 + 4*i, got);
                if (got !== exp_det[i]) begin case_errors = case_errors + 1; if (case_errors < 8) $display("MISMATCH %s DET bin %0d: got %0d want %0d", name, i, got, exp_det[i]); end
                axi_read(17'h01000 + 4*HIST_K + 4*i, got);
                if (got !== exp_lam[i]) begin case_errors = case_errors + 1; if (case_errors < 8) $display("MISMATCH %s LAM bin %0d: got %0d want %0d", name, i, got, exp_lam[i]); end
            end
            ncases = ncases + 1;
            if (case_errors != 0) begin nfail = nfail + 1; $display("FAILCASE %s (%0d errors)", name, case_errors); end
            errors = errors + case_errors;
        end
        $display("cases %0d failed %0d", ncases, nfail);
        if (errors == 0) $display("PASS k2 extractor: all cases match");
        else             $display("FAIL k2 extractor: %0d errors", errors);
        $finish;
    end
endmodule
