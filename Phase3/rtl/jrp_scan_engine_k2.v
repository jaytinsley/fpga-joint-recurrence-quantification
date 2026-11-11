`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// jrp_scan_engine_k2.v
//   K = 2 version of jrp_scan_engine: two lanes, each two released distance units and an AND,
//   evaluate the cells (i, j0) and (i, j0 + 1) of a row in the same cycle, so the full N x N grid
//   (decision D1) takes ceil(N/2) * N cycles instead of N * N.
//   Read ports per channel: A = row vector i (shared by both lanes), B = vector j0, C = vector
//   j0 + 1 (j0 again on the last beat of a row of odd length, the result is then masked).
//   Beat format to the extractor: {i, j0, f1, f0, v1}, v1 = second cell valid.
//   Latency, backpressure and error flags as jrp_scan_engine (see there).
// -----------------------------------------------------------------------------
module jrp_scan_engine_k2 #(
    parameter integer DATA_WIDTH = 32,
    parameter integer MAX_M      = 6,
    parameter integer N_BITS     = 14
)(
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         start,
    input  wire [31:0]                  n,
    input  wire [31:0]                  base_x,
    input  wire [31:0]                  base_y,
    input  wire [7:0]                   m_x,
    input  wire [7:0]                   m_y,
    input  wire [DATA_WIDTH-1:0]        eps2_x,
    input  wire [DATA_WIDTH-1:0]        eps2_y,

    // Vector memory x: ports A (i), B (j0), C (j0 + 1)
    output reg                          rd_en_ax,  output reg [31:0] rd_idx_ax,
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_ax,    input  wire       vec_ax_valid,
    output reg                          rd_en_bx,  output reg [31:0] rd_idx_bx,
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_bx,    input  wire       vec_bx_valid,
    output reg                          rd_en_cx,  output reg [31:0] rd_idx_cx,
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_cx,    input  wire       vec_cx_valid,
    // Vector memory y
    output reg                          rd_en_ay,  output reg [31:0] rd_idx_ay,
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_ay,    input  wire       vec_ay_valid,
    output reg                          rd_en_by,  output reg [31:0] rd_idx_by,
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_by,    input  wire       vec_by_valid,
    output reg                          rd_en_cy,  output reg [31:0] rd_idx_cy,
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_cy,    input  wire       vec_cy_valid,

    // Beats to the extractor: {i, j0, f1, f0, v1}
    output reg  [2*N_BITS+2:0]          m_axis_tdata,
    output reg                          m_axis_tvalid,
    input  wire                         m_axis_tready,

    output reg                          pairs_done_pulse,
    output reg                          cells_done_pulse,
    output reg                          lost_err,
    output reg                          align_err
);
    localparam integer FLAG_LAT = 7;
    localparam integer SCAN_LAT = FLAG_LAT + 2;

    // ---- stage 0: pair generator ----
    wire [N_BITS-1:0] g_i, g_j;
    wire              g_valid, g_valid1, g_last, g_done;
    jrp_pair_gen_k2 #(.N_BITS(N_BITS)) u_gen (
        .clk(clk), .rst_n(rst_n), .start(start), .n(n), .en(m_axis_tready),
        .i_out(g_i), .j_out(g_j), .valid(g_valid), .valid1(g_valid1), .last(g_last), .done_pulse(g_done));

    // ---- stage 1: indices and read enables ----
    reg [N_BITS-1:0] t0_i, t0_j;
    reg              t0_last, t0_v1;
    wire [31:0] j1 = {{(32-N_BITS){1'b0}}, g_j} + (g_valid1 ? 32'd1 : 32'd0);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_en_ax <= 1'b0; rd_en_bx <= 1'b0; rd_en_cx <= 1'b0;
            rd_en_ay <= 1'b0; rd_en_by <= 1'b0; rd_en_cy <= 1'b0;
            rd_idx_ax <= 32'd0; rd_idx_bx <= 32'd0; rd_idx_cx <= 32'd0;
            rd_idx_ay <= 32'd0; rd_idx_by <= 32'd0; rd_idx_cy <= 32'd0;
            t0_i <= {N_BITS{1'b0}}; t0_j <= {N_BITS{1'b0}}; t0_last <= 1'b0; t0_v1 <= 1'b0;
        end else begin
            rd_en_ax <= g_valid; rd_en_bx <= g_valid; rd_en_cx <= g_valid;
            rd_en_ay <= g_valid; rd_en_by <= g_valid; rd_en_cy <= g_valid;
            if (g_valid) begin
                rd_idx_ax <= base_x + {{(32-N_BITS){1'b0}}, g_i};
                rd_idx_bx <= base_x + {{(32-N_BITS){1'b0}}, g_j};
                rd_idx_cx <= base_x + j1;
                rd_idx_ay <= base_y + {{(32-N_BITS){1'b0}}, g_i};
                rd_idx_by <= base_y + {{(32-N_BITS){1'b0}}, g_j};
                rd_idx_cy <= base_y + j1;
            end
            t0_i <= g_i; t0_j <= g_j; t0_last <= g_valid & g_last; t0_v1 <= g_valid1;
        end
    end

    // ---- tag pipe ----
    localparam integer TW = 2*N_BITS + 2;
    reg [TW-1:0] tag [0:FLAG_LAT-1];
    reg [FLAG_LAT-1:0] tag_v;
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tag_v <= {FLAG_LAT{1'b0}};
            for (k = 0; k < FLAG_LAT; k = k + 1) tag[k] <= {TW{1'b0}};
        end else begin
            tag[0]  <= {t0_i, t0_j, t0_v1, t0_last};
            tag_v   <= {tag_v[FLAG_LAT-2:0], rd_en_ax};
            for (k = 1; k < FLAG_LAT; k = k + 1) tag[k] <= tag[k-1];
        end
    end

    // ---- two lanes ----
    wire flag0, flag1, valid0, valid1, skew0, skew1;
    jrp_lane #(.DATA_WIDTH(DATA_WIDTH), .MAX_M(MAX_M)) u_lane0 (
        .clk(clk), .rst_n(rst_n),
        .vec_ax(vec_ax), .vec_bx(vec_bx), .vx_valid(vec_ax_valid & vec_bx_valid),
        .vec_ay(vec_ay), .vec_by(vec_by), .vy_valid(vec_ay_valid & vec_by_valid),
        .m_x(m_x), .m_y(m_y), .eps2_x(eps2_x), .eps2_y(eps2_y),
        .flag(flag0), .out_valid(valid0), .skew_err(skew0));
    jrp_lane #(.DATA_WIDTH(DATA_WIDTH), .MAX_M(MAX_M)) u_lane1 (
        .clk(clk), .rst_n(rst_n),
        .vec_ax(vec_ax), .vec_bx(vec_cx), .vx_valid(vec_ax_valid & vec_cx_valid),
        .vec_ay(vec_ay), .vec_by(vec_cy), .vy_valid(vec_ay_valid & vec_cy_valid),
        .m_x(m_x), .m_y(m_y), .eps2_x(eps2_x), .eps2_y(eps2_y),
        .flag(flag1), .out_valid(valid1), .skew_err(skew1));

    // ---- output register ----
    wire [TW-1:0] tag_out = tag[FLAG_LAT-1];
    wire          tag_v1  = tag_out[1];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tdata <= {(2*N_BITS+3){1'b0}}; m_axis_tvalid <= 1'b0;
            pairs_done_pulse <= 1'b0; cells_done_pulse <= 1'b0;
            lost_err <= 1'b0; align_err <= 1'b0;
        end else begin
            pairs_done_pulse <= g_done;
            cells_done_pulse <= 1'b0;
            if (start) begin lost_err <= 1'b0; align_err <= 1'b0; end
            m_axis_tvalid <= valid0;
            if (valid0) begin
                m_axis_tdata <= {tag_out[TW-1:2], flag1 & tag_v1, flag0, tag_v1};
                if (tag_out[0]) cells_done_pulse <= 1'b1;
            end
            if (m_axis_tvalid && !m_axis_tready) lost_err <= 1'b1;
            if (skew0 || skew1 || (valid0 != valid1) || (valid0 != tag_v[FLAG_LAT-1]) ||
                (vec_ax_valid != vec_bx_valid) || (vec_ax_valid != vec_cx_valid) ||
                (vec_ay_valid != vec_by_valid) || (vec_ay_valid != vec_cy_valid) ||
                (vec_ax_valid != vec_ay_valid))
                align_err <= 1'b1;
        end
    end
endmodule
