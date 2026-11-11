`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// jrp_lane.v
//   One dual-channel comparison lane: two instances of the released
//   distance_threshold_calculation (Li, Lai and Oberst 2026, Zenodo
//   10.5281/zenodo.20406392, MIT), one per channel, whose recurrence flags are ANDed:
//     JR(i, j) = [d2(x_i, x_j) <= eps2_x << 24] AND [d2(y_i, y_j) <= eps2_y << 24]
//   Both units are fully pipelined (in_ready is tied high by out_ready = 1), so the lane
//   accepts one pair per cycle. Inputs for the two channels must arrive together.
//   Latency from in_valid to out_valid: DTC_LAT = 4 cycles.
// -----------------------------------------------------------------------------
module jrp_lane #(
    parameter integer DATA_WIDTH = 32,
    parameter integer MAX_M      = 6
)(
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_ax,   // x vector of index i
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_bx,   // x vector of index j
    input  wire                         vx_valid,
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_ay,
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_by,
    input  wire                         vy_valid,

    input  wire [7:0]                   m_x,
    input  wire [7:0]                   m_y,
    input  wire [DATA_WIDTH-1:0]        eps2_x,   // eps_x^2 as unsigned Q8.24
    input  wire [DATA_WIDTH-1:0]        eps2_y,

    output wire                         flag,     // valid when out_valid
    output wire                         out_valid,
    output wire                         skew_err  // x and y results out of step (never in a correct design)
);
    wire flag_x, flag_y, ov_x, ov_y;

    distance_threshold_calculation #(.DATA_WIDTH(DATA_WIDTH), .MAX_M(MAX_M)) u_dtc_x (
        .clk(clk), .rst_n(rst_n), .vec_a(vec_ax), .vec_b(vec_bx), .m_active(m_x),
        .in_valid(vx_valid), .in_ready(), .eps2(eps2_x),
        .rec_flag(flag_x), .out_valid(ov_x), .out_ready(1'b1));

    distance_threshold_calculation #(.DATA_WIDTH(DATA_WIDTH), .MAX_M(MAX_M)) u_dtc_y (
        .clk(clk), .rst_n(rst_n), .vec_a(vec_ay), .vec_b(vec_by), .m_active(m_y),
        .in_valid(vy_valid), .in_ready(), .eps2(eps2_y),
        .rec_flag(flag_y), .out_valid(ov_y), .out_ready(1'b1));

    assign flag      = flag_x & flag_y;
    assign out_valid = ov_x & ov_y;
    assign skew_err  = (ov_x != ov_y);
endmodule
