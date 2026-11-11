`timescale 1ns / 1ps
// Multi-frame test: runs several golden cases back to back on ONE instance of jrp_board_core (reset once),
// as the board does, through the single AXI-Lite port. Checks the counters and the histograms (every bin up
// to max(l_max, v_max) + 1) after each frame.
// +PLAN=<file>: one line per case: pfx cnt_file n ns mx my tx ty e2x(hex) e2y(hex) has_y
module tb_board_multi;
    parameter integer MAX_M = 6;
    parameter integer HIST_K = 8192;
    parameter integer K = 1;
    localparam [19:0] CTRL = 20'h00000, RQA = 20'h20000, PERF = 20'h40000, FEED = 20'h60000;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

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

    string plan, pfx, cnt_file;
    integer fd, r, n, ns, mx, my, tx, ty, has_y;
    reg [31:0] e2x, e2y;
    reg [31:0] sx [0:(1<<16)-1];
    reg [31:0] sy [0:(1<<16)-1];
    reg [31:0] cw [0:(1<<16)-1];
    reg [31:0] exp_det [0:HIST_K-1];
    reg [31:0] exp_lam [0:HIST_K-1];
    integer i, k, errors, total_errors, frame, polls, top, cases_run;
    reg [31:0] got, st, nx, ny, base_x, base_y;

    // (the +SWEEP / +DEBUG hierarchical probes into the K = 1 extractor were removed when K = 2 was added:
    //  the extractor now sits inside a generate block. See git history of finding 7 in docs/phase3_results.md.)

    initial begin
        if (!$value$plusargs("PLAN=%s", plan)) begin $display("FAIL: +PLAN missing"); $finish; end
        fd = $fopen(plan, "r");
        if (fd == 0) begin $display("FAIL: cannot open plan"); $finish; end
        awvalid = 0; wvalid = 0; bready = 1; arvalid = 0; rready = 1; awaddr = 0; araddr = 0; wdata = 0;
        total_errors = 0; frame = 0; cases_run = 0;
        repeat (5) begin @(posedge clk); #1; end
        rst_n = 1;
        repeat (3) begin @(posedge clk); #1; end

        while (!$feof(fd)) begin
            r = $fscanf(fd, "%s %s %d %d %d %d %d %d %h %h %d\n", pfx, cnt_file, n, ns, mx, my, tx, ty, e2x, e2y, has_y);
            if (r != 11) break;
            frame = frame + 1; cases_run = cases_run + 1; errors = 0;
            $readmemh({pfx, "_x.hex"}, sx);
            if (has_y) $readmemh({pfx, "_y.hex"}, sy);
            $readmemh(cnt_file, cw);
            for (i = 0; i < HIST_K; i = i + 1) begin exp_det[i] = 0; exp_lam[i] = 0; end
            for (i = 0; i < cw[7]; i = i + 1) exp_det[cw[9 + 2*i]] = cw[10 + 2*i];
            for (i = 0; i < cw[8]; i = i + 1) exp_lam[cw[9 + 2*cw[7] + 2*i]] = cw[10 + 2*cw[7] + 2*i];
            if (!has_y) begin my = 1; ty = 1; e2y = 32'hFFFFFFFF; end
            nx = ns - (mx-1)*tx; ny = ns - (my-1)*ty; base_x = nx - n; base_y = ny - n;

            wr(CTRL + 20'h008, ns);  wr(CTRL + 20'h00C, mx);  wr(CTRL + 20'h010, tx);  wr(CTRL + 20'h014, e2x);
            wr(CTRL + 20'h024, my);  wr(CTRL + 20'h028, ty);  wr(CTRL + 20'h02C, e2y);
            wr(CTRL + 20'h018, 2);   wr(CTRL + 20'h01C, 2);
            wr(CTRL + 20'h034, base_x); wr(CTRL + 20'h038, base_y); wr(CTRL + 20'h03C, n);
            wr(FEED + 20'h00, 32'h2);
            for (i = 0; i < ns; i = i + 1) begin
                wr(FEED + 20'h0C, sx[i]);
                wr(FEED + 20'h10, has_y ? sy[i] : 32'd0);
            end
            wr(FEED + 20'h08, ns);
            wr(PERF + 20'h000, 32'h2); wr(PERF + 20'h000, 32'h1);
            wr(CTRL + 20'h000, 32'h1);
            wr(FEED + 20'h00, 32'h1);
            st = 0; polls = 0;
            while (!st[3] && polls < 4000) begin rd(CTRL + 20'h004, st); polls = polls + 1; repeat (500) @(posedge clk); end
            if (!st[3]) begin errors = errors + 1; $display("frame %0d TIMEOUT", frame); end
            repeat (300) begin @(posedge clk); #1; end

            rd(RQA + 20'h008, got); if (got !== cw[0]) begin errors = errors + 1; $display("  rr_count got %0d want %0d", got, cw[0]); end
            rd(RQA + 20'h010, got); if (got !== cw[1]) begin errors = errors + 1; $display("  det_points got %0d want %0d", got, cw[1]); end
            rd(RQA + 20'h018, got); if (got !== cw[2]) begin errors = errors + 1; $display("  det_lines got %0d want %0d", got, cw[2]); end
            rd(RQA + 20'h01C, got); if (got !== cw[3]) begin errors = errors + 1; $display("  l_max got %0d want %0d", got, cw[3]); end
            rd(RQA + 20'h020, got); if (got !== cw[4]) begin errors = errors + 1; $display("  lam_points got %0d want %0d", got, cw[4]); end
            rd(RQA + 20'h028, got); if (got !== cw[5]) begin errors = errors + 1; $display("  lam_lines got %0d want %0d", got, cw[5]); end
            rd(RQA + 20'h02C, got); if (got !== cw[6]) begin errors = errors + 1; $display("  v_max got %0d want %0d", got, cw[6]); end
            top = (cw[3] > cw[6] ? cw[3] : cw[6]) + 1; if (top > HIST_K - 1) top = HIST_K - 1;
            for (i = 0; i <= top; i = i + 1) begin
                rd(RQA + 20'h01000 + 4*i, got);
                if (got !== exp_det[i]) begin errors = errors + 1; if (errors < 8) $display("  DET bin %0d got %0d want %0d", i, got, exp_det[i]); end
                rd(RQA + 20'h01000 + 4*HIST_K + 4*i, got);
                if (got !== exp_lam[i]) begin errors = errors + 1; if (errors < 8) $display("  LAM bin %0d got %0d want %0d", i, got, exp_lam[i]); end
            end
            $display("%s frame %0d %s", (errors == 0) ? "PASS" : "FAIL", frame, pfx);
            total_errors = total_errors + errors;
        end
        $display("%s: %0d frames, %0d errors", (total_errors == 0) ? "ALLPASS" : "SOMEFAIL", cases_run, total_errors);
        $finish;
    end
endmodule
