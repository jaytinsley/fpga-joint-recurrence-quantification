`timescale 1ns / 1ps
// Unit test of jrp_rt_ingest with a behavioural model of jrp_top (start, stream sink with random stalls, a
// fixed scan time, result pulse). The stream carries the sample index so each drained window can be checked.
// Plusargs: NRAW HOP PERIOD SCAN TOTAL PV (% of cycles the source offers a sample) DROP (0/1) PMAXACK
module tb_rt_ingest;
    parameter integer DEPTH = 256;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [5:0] awaddr, araddr; reg awvalid, wvalid, bready, arvalid, rready; reg [31:0] wdata;
    wire awready, wready, bvalid, arready, rvalid; wire [31:0] rdata; wire [1:0] bresp, rresp;
    reg  [63:0] s_tdata; reg s_tvalid; wire s_tready;
    wire [63:0] m_tdata; wire m_tvalid; reg m_tready; wire m_tlast;
    wire ext_start, irq;
    reg  top_busy, top_result, top_cfg_err;
    reg  [31:0] nraw; reg [63:0] cyc;
    always @(posedge clk) cyc <= rst_n ? cyc + 1 : 64'd0;

    jrp_rt_ingest #(.DEPTH(DEPTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready), .s_axis_tlast(1'b0),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .ext_start(ext_start), .top_busy(top_busy), .top_result(top_result), .top_cfg_err(top_cfg_err),
        .n_raw(nraw), .cyc(cyc), .irq(irq));

    task wr(input [5:0] a, input [31:0] d);
        begin
            @(posedge clk); #1; awaddr = a; wdata = d; awvalid = 1; wvalid = 1;
            @(posedge clk); while (!(awready && wready)) @(posedge clk);
            #1; awvalid = 0; wvalid = 0;
            while (!bvalid) @(posedge clk);
            @(posedge clk); #1;
        end
    endtask
    task rd(input [5:0] a, output [31:0] d);
        begin
            @(posedge clk); #1; araddr = a; arvalid = 1;
            @(posedge clk); while (!arready) @(posedge clk);
            #1; arvalid = 0;
            while (!rvalid) @(posedge clk);
            d = rdata; @(posedge clk); #1;
        end
    endtask

    integer NRAW, HOP, PERIOD, SCAN, TOTAL, PV, DROP, PMAXACK, HOPEFF;
    integer errors = 0, frames_model = 0, nwin_exp;
    // ---- model of jrp_top ----
    reg [31:0] win [0:8191];
    integer recv = 0, scan_cnt = 0, in_scan = 0, model_gap = 0, k;
    reg [31:0] prev, cur;
    always @(posedge clk) begin
        top_result <= 1'b0;
        m_tready <= ($urandom % 100) < 60;
        if (ext_start) begin top_busy <= 1'b1; recv = 0; end
        if (m_tvalid && m_tready) begin
            win[recv] = m_tdata[31:0];
            if (m_tdata[63:32] !== (m_tdata[31:0] ^ 32'hA5A50000)) begin errors = errors + 1; $display("hi word mismatch beat %0d", recv); end
            if (m_tlast) begin
                if (recv != NRAW - 1) begin errors = errors + 1; $display("tlast at beat %0d, want %0d", recv, NRAW - 1); end
                in_scan = 1; scan_cnt = SCAN;
                model_gap = 0;
                for (k = 1; k < NRAW; k = k + 1) if (win[k] !== win[k-1] + 1) model_gap = 1;
                if (!DROP) begin
                    if (win[0] !== frames_model * HOPEFF) begin errors = errors + 1; $display("frame %0d starts at %0d, want %0d", frames_model, win[0], frames_model * HOPEFF); end
                    if (model_gap) begin errors = errors + 1; $display("frame %0d: samples not consecutive", frames_model); end
                end
            end
            recv = recv + 1;
        end
        if (in_scan) begin
            if (scan_cnt <= 1) begin in_scan = 0; top_result <= 1'b1; top_busy <= 1'b0; frames_model = frames_model + 1; end
            else scan_cnt = scan_cnt - 1;
        end
    end

    // ---- source ----
    integer sent = 0;
    initial begin
        s_tvalid = 0; s_tdata = 0;
        wait (rst_n);
        repeat (20) @(posedge clk);
        @(posedge clk); #1;
        while (sent < TOTAL) begin
            if (($urandom % 100) < PV) begin
                s_tdata = {sent[31:0] ^ 32'hA5A50000, sent[31:0]}; s_tvalid = 1;
                @(posedge clk); while (!s_tready) @(posedge clk);
                sent = sent + 1; #1;
            end else begin
                s_tvalid = 0; @(posedge clk); #1;
            end
        end
        s_tvalid = 0;
    end

    // ---- main ----
    reg [31:0] v, st;
    integer idle, tmo, acks = 0;
    initial begin
        if (!$value$plusargs("NRAW=%d", NRAW)) NRAW = 64;
        if (!$value$plusargs("HOP=%d", HOP)) HOP = 0;
        if (!$value$plusargs("PERIOD=%d", PERIOD)) PERIOD = 0;
        if (!$value$plusargs("SCAN=%d", SCAN)) SCAN = 500;
        if (!$value$plusargs("TOTAL=%d", TOTAL)) TOTAL = 1600;
        if (!$value$plusargs("PV=%d", PV)) PV = 30;
        if (!$value$plusargs("DROP=%d", DROP)) DROP = 0;
        if (!$value$plusargs("PMAXACK=%d", PMAXACK)) PMAXACK = 20;
        HOPEFF = (HOP == 0) ? NRAW : HOP;
        nwin_exp = (TOTAL >= NRAW) ? ((TOTAL - NRAW) / HOPEFF + 1) : 0;
        awvalid = 0; wvalid = 0; bready = 1; arvalid = 0; rready = 1; awaddr = 0; araddr = 0; wdata = 0;
        top_busy = 0; top_result = 0; top_cfg_err = 0; nraw = NRAW;
        repeat (5) @(posedge clk); #1; rst_n = 1;
        repeat (3) @(posedge clk);
        wr(6'h08, HOP); wr(6'h0C, PERIOD);
        wr(6'h00, 32'h1 | (DROP ? 32'h8 : 32'h0));
        idle = 0; tmo = 0;
        while (idle < 4 * (SCAN + 4 * NRAW + 200) && tmo < 3000000) begin
            @(posedge clk); tmo = tmo + 1;
            if (irq) begin
                repeat ($urandom % (PMAXACK + 1)) @(posedge clk);
                rd(6'h04, st);
                if (DROP && st[2] !== model_gap[0]) begin errors = errors + 1; $display("frame %0d: gap flag %0b, model %0d", frames_model - 1, st[2], model_gap); end
                wr(6'h00, 32'h4 | 32'h1 | (DROP ? 32'h8 : 32'h0));
                acks = acks + 1; idle = 0;
            end else if (sent >= TOTAL && dut.st == 0) idle = idle + 1; else idle = 0;
        end
        if (tmo >= 3000000) begin errors = errors + 1; $display("TIMEOUT"); end
        rd(6'h1C, v); if (v !== frames_model) begin errors = errors + 1; $display("FRAMES_DONE %0d, model %0d", v, frames_model); end
        if (!DROP) begin
            if (frames_model != nwin_exp) begin errors = errors + 1; $display("frames %0d, expected %0d", frames_model, nwin_exp); end
            rd(6'h18, v); if (v !== 0) begin errors = errors + 1; $display("DROPPED %0d in backpressure mode", v); end
            rd(6'h04, st); if (st[1]) begin errors = errors + 1; $display("overrun set in backpressure mode"); end
        end else begin
            rd(6'h18, v);
            if (v + dut.wcnt !== TOTAL) begin errors = errors + 1; $display("dropped %0d + stored %0d != %0d", v, dut.wcnt, TOTAL); end
            $display("  dropped %0d of %0d", v, TOTAL);
        end
        rd(6'h14, v); $display("  OCC_MAX %0d of %0d", v, DEPTH);
        rd(6'h30, v); $display("  gap frames %0d", v);
        $display("  frames %0d acks %0d sent %0d", frames_model, acks, sent);
        $display("%s: NRAW=%0d HOP=%0d PERIOD=%0d SCAN=%0d TOTAL=%0d PV=%0d DROP=%0d errors=%0d",
                 (errors == 0) ? "PASS" : "FAIL", NRAW, HOP, PERIOD, SCAN, TOTAL, PV, DROP, errors);
        $finish;
    end
endmodule
