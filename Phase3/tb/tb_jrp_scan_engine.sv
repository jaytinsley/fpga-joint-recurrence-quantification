`timescale 1ns / 1ps
// Self-checking L2 testbench: vector memories + jrp_scan_engine against Phase 1 golden vectors.
// Plusargs: +PFX=<path prefix of the case, e.g. ../../Phase1/golden/jrp_mixedparams_small>
//           +N=<joint vectors> +MX=<m_x> +MY=<m_y> +E2X=<eps2_x hex> +E2Y=<eps2_y hex>
//           +HAS_Y=<0|1> (0: single-channel case, y neutral) +STALL=<cycles tready low after start>
// Checks: pair order (i outer, j inner), every flag vs <PFX>_flags.hex, beat count N*N,
//         fixed latency, no lost_err / align_err.
module tb_jrp_scan_engine;
    parameter integer MAX_M = 6;
    parameter integer N_MAX = 1024;
    localparam integer DW = 32;
    localparam integer N_BITS = 14;
    localparam integer VECW = DW*MAX_M;

    reg clk = 0, rst_n = 0;
    always #3.333 clk = ~clk;   // 150 MHz

    // ---- plusargs ----
    string pfx;
    integer n, mx, my, has_y, stall;
    reg [31:0] e2x, e2y;
    initial begin
        if (!$value$plusargs("PFX=%s", pfx)) begin $display("FAIL: +PFX missing"); $finish; end
        if (!$value$plusargs("N=%d", n))     begin $display("FAIL: +N missing");   $finish; end
        if (!$value$plusargs("MX=%d", mx))   mx = 5;
        if (!$value$plusargs("MY=%d", my))   my = 5;
        if (!$value$plusargs("E2X=%h", e2x)) e2x = 32'h0;
        if (!$value$plusargs("E2Y=%h", e2y)) e2y = 32'h0;
        if (!$value$plusargs("HAS_Y=%d", has_y)) has_y = 1;
        if (!$value$plusargs("STALL=%d", stall)) stall = 0;
    end

    // ---- vector memories ----
    reg  [VECW-1:0] sx_data, sy_data;
    reg             s_valid;
    reg             frame_start;
    wire            s_readyx, s_readyy;
    wire [31:0]     nlx, nly;
    wire            rd_en_ax, rd_en_bx, rd_en_ay, rd_en_by;
    wire [31:0]     rd_idx_ax, rd_idx_bx, rd_idx_ay, rd_idx_by;
    wire [VECW-1:0] vec_ax, vec_bx, vec_ay, vec_by;
    wire            vax_v, vbx_v, vay_v, vby_v;

    jrp_vector_buffer #(.DATA_WIDTH(DW), .MAX_M(MAX_M), .N_MAX(N_MAX)) u_vbx (
        .clk(clk), .rst_n(rst_n), .frame_start(frame_start), 
        .s_vec_tdata(sx_data), .s_vec_tvalid(s_valid), .s_vec_tready(s_readyx), .n_loaded(nlx),
        .rd_en_a(rd_en_ax), .rd_idx_a(rd_idx_ax), .vec_a(vec_ax), .vec_a_valid(vax_v),
        .rd_en_b(rd_en_bx), .rd_idx_b(rd_idx_bx), .vec_b(vec_bx), .vec_b_valid(vbx_v));
    jrp_vector_buffer #(.DATA_WIDTH(DW), .MAX_M(MAX_M), .N_MAX(N_MAX)) u_vby (
        .clk(clk), .rst_n(rst_n), .frame_start(frame_start), 
        .s_vec_tdata(sy_data), .s_vec_tvalid(s_valid), .s_vec_tready(s_readyy), .n_loaded(nly),
        .rd_en_a(rd_en_ay), .rd_idx_a(rd_idx_ay), .vec_a(vec_ay), .vec_a_valid(vay_v),
        .rd_en_b(rd_en_by), .rd_idx_b(rd_idx_by), .vec_b(vec_by), .vec_b_valid(vby_v));

    // ---- DUT ----
    reg         start;
    reg         tready;
    wire [2*N_BITS:0] tdata;
    wire        tvalid, pairs_done, cells_done, lost_err, align_err;
    reg  [31:0] mx_r, my_r, e2x_r, e2y_r, n_r;

    jrp_scan_engine #(.DATA_WIDTH(DW), .MAX_M(MAX_M), .N_BITS(N_BITS)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .n(n_r), .base_x(32'd0), .base_y(32'd0),
        .m_x(mx_r[7:0]), .m_y(my_r[7:0]), .eps2_x(e2x_r), .eps2_y(e2y_r),
        .rd_en_ax(rd_en_ax), .rd_idx_ax(rd_idx_ax), .vec_ax(vec_ax), .vec_ax_valid(vax_v),
        .rd_en_bx(rd_en_bx), .rd_idx_bx(rd_idx_bx), .vec_bx(vec_bx), .vec_bx_valid(vbx_v),
        .rd_en_ay(rd_en_ay), .rd_idx_ay(rd_idx_ay), .vec_ay(vec_ay), .vec_ay_valid(vay_v),
        .rd_en_by(rd_en_by), .rd_idx_by(rd_idx_by), .vec_by(vec_by), .vec_by_valid(vby_v),
        .m_axis_tdata(tdata), .m_axis_tvalid(tvalid), .m_axis_tready(tready),
        .pairs_done_pulse(pairs_done), .cells_done_pulse(cells_done),
        .lost_err(lost_err), .align_err(align_err));

    // ---- golden data ----
    reg [31:0] wx [0:(1<<18)-1];
    reg [31:0] wy [0:(1<<18)-1];
    reg [31:0] fl [0:(1<<17)-1];

    integer i, k, errors, beats, first_beat_cycle, last_beat_cycle, start_cycle, cyc;
    reg [VECW-1:0] bus;
    integer exp_i, exp_j;
    reg saw_pairs_done, saw_cells_done;

    always @(posedge clk) cyc <= (rst_n) ? cyc + 1 : 0;

    // optional debug trace of the first lane inputs (+DEBUG)
    integer dbg_n = 0;
    always @(posedge clk) if ($test$plusargs("DEBUG") && rst_n) begin
        if (rd_en_ax && dbg_n < 6) $display("[%0d] rd idx_a=%0d idx_b=%0d", cyc, rd_idx_ax, rd_idx_bx);
        if (vax_v && vbx_v && dbg_n < 6) begin
            $display("[%0d] lane in: ax0=%h bx0=%h ay0=%h by0=%h  (wx[0]=%h wx[1]=%h)", cyc,
                vec_ax[31:0], vec_bx[31:0], vec_ay[31:0], vec_by[31:0], wx[0], wx[1]);
            dbg_n = dbg_n + 1;
        end
    end

    // ---- monitor ----
    always @(posedge clk) if (rst_n && tvalid && tready) begin
        exp_i = beats / n; exp_j = beats % n;
        if (tdata[2*N_BITS:N_BITS+1] !== exp_i[N_BITS-1:0] || tdata[N_BITS:1] !== exp_j[N_BITS-1:0]) begin
            errors = errors + 1;
            if (errors < 10) $display("ORDER error beat %0d: got (%0d,%0d) want (%0d,%0d)", beats,
                tdata[2*N_BITS:N_BITS+1], tdata[N_BITS:1], exp_i, exp_j);
        end
        if (tdata[0] !== fl[beats][0]) begin
            errors = errors + 1;
            if (errors < 10) $display("FLAG error beat %0d (%0d,%0d): got %0d want %0d", beats, exp_i, exp_j,
                tdata[0], fl[beats][0]);
        end
        if (beats == 0) first_beat_cycle = cyc;
        last_beat_cycle = cyc;
        beats = beats + 1;
    end
    always @(posedge clk) begin
        if (pairs_done) saw_pairs_done = 1;
        if (cells_done) saw_cells_done = 1;
    end

    initial begin
        errors = 0; beats = 0; saw_pairs_done = 0; saw_cells_done = 0;
        s_valid = 0; frame_start = 0; start = 0; tready = 1; sx_data = 0; sy_data = 0;
        first_beat_cycle = -1; last_beat_cycle = -1; cyc = 0;
        #1;
        n_r = n; mx_r = mx; my_r = my; e2x_r = e2x; e2y_r = e2y;
        $readmemh({pfx, "_vec_x.hex"}, wx);
        if (has_y) $readmemh({pfx, "_vec_y.hex"}, wy);
        $readmemh({pfx, "_flags.hex"}, fl);
        if (!has_y) begin   // neutral y channel: all-zero vectors, eps2 huge so y always recurs
            my_r = 1; e2y_r = 32'hFFFFFFFF;
        end
        repeat (5) begin @(posedge clk); #1; end #1;
        rst_n = 1;
        repeat (3) begin @(posedge clk); #1; end #1;
        // load vectors (index order = write order)
        frame_start = 1; @(posedge clk); #1; frame_start = 0;
        for (i = 0; i < n; i = i + 1) begin
            bus = 0;
            for (k = 0; k < mx; k = k + 1) bus[k*DW +: DW] = wx[i*mx + k];
            sx_data = bus;
            bus = 0;
            if (has_y) for (k = 0; k < my; k = k + 1) bus[k*DW +: DW] = wy[i*my + k];
            sy_data = bus;
            s_valid = 1; @(posedge clk); #1;
        end
        s_valid = 0;
        repeat (6) begin @(posedge clk); #1; end #1;
        // scan
        tready = (stall == 0);
        start = 1; @(posedge clk); #1; start_cycle = cyc; start = 0;
        if (stall > 0) begin repeat (stall) begin @(posedge clk); #1; end #1; tready = 1; end
        // wait for completion
        k = 0;
        while (beats < n*n && k < n*n*2 + 5000 + stall) begin @(posedge clk); #1; k = k + 1; end
        repeat (20) begin @(posedge clk); #1; end #1;
        if (beats != n*n) begin errors = errors + 1; $display("BEAT COUNT error: got %0d want %0d", beats, n*n); end
        if (lost_err)  begin errors = errors + 1; $display("lost_err set"); end
        if (align_err) begin errors = errors + 1; $display("align_err set"); end
        if (!saw_pairs_done || !saw_cells_done) begin errors = errors + 1; $display("completion pulses missing"); end
        if (errors == 0 && stall == 0 && (last_beat_cycle - first_beat_cycle) != n*n - 1) begin
            errors = errors + 1; $display("THROUGHPUT error: beats span %0d cycles, want %0d",
                last_beat_cycle - first_beat_cycle + 1, n*n);
        end
        $display("first beat %0d cycles after start, last after %0d (n*n = %0d); latency over pairs = %0d",
            first_beat_cycle - start_cycle, last_beat_cycle - start_cycle, n*n, first_beat_cycle - start_cycle);
        if (errors == 0) $display("PASS %s: %0d pairs", pfx, beats);
        else             $display("FAIL %s: %0d errors", pfx, errors);
        $finish;
    end
endmodule
