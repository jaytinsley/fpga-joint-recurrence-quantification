`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// jrp_scan_engine.v
//   Pipelined replacement for the released grid_index_gen + compare_orchestrator pair.
//   Streams the full N x N grid (decision D1) at one pair per cycle:
//     pair generator -> index + base registers -> two mirrored read ports on each channel's
//     vector memory -> jrp_lane (two distance units + AND) -> {i, j, flag} stream.
//   The flag stream format and the pair order equal those of the released
//   compare_orchestrator, so the released RQA extractor is reused unchanged.
//   Latency is fixed: the first flag appears SCAN_LAT cycles after the first pair is
//   issued, and the last flag SCAN_LAT cycles after the last pair.
//   Backpressure: the released extractor holds tready high for a whole scan and only drops
//   it while clearing histograms at frame start. Pairs are issued only while m_axis_tready
//   is high. If tready falls while pairs are in flight, a flag would be lost: `lost_err`
//   latches and stays set until the next start.
// -----------------------------------------------------------------------------
module jrp_scan_engine #(
    parameter integer DATA_WIDTH = 32,
    parameter integer MAX_M      = 6,
    parameter integer N_BITS     = 14
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Control (held stable during a frame)
    input  wire                         start,       // one-cycle pulse
    input  wire [31:0]                  n,           // joint vectors per channel
    input  wire [31:0]                  base_x,      // memory index of joint vector 0, channel x
    input  wire [31:0]                  base_y,
    input  wire [7:0]                   m_x,
    input  wire [7:0]                   m_y,
    input  wire [DATA_WIDTH-1:0]        eps2_x,
    input  wire [DATA_WIDTH-1:0]        eps2_y,

    // Vector memory x: read port A (index i), port B (index j)
    output reg                          rd_en_ax,
    output reg  [31:0]                  rd_idx_ax,
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_ax,
    input  wire                         vec_ax_valid,
    output reg                          rd_en_bx,
    output reg  [31:0]                  rd_idx_bx,
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_bx,
    input  wire                         vec_bx_valid,
    // Vector memory y
    output reg                          rd_en_ay,
    output reg  [31:0]                  rd_idx_ay,
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_ay,
    input  wire                         vec_ay_valid,
    output reg                          rd_en_by,
    output reg  [31:0]                  rd_idx_by,
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_by,
    input  wire                         vec_by_valid,

    // Flag stream to the RQA extractor: {i, j, flag}
    output reg  [2*N_BITS:0]            m_axis_tdata,
    output reg                          m_axis_tvalid,
    input  wire                         m_axis_tready,

    // Events and status
    output reg                          pairs_done_pulse,   // last pair issued
    output reg                          cells_done_pulse,   // last flag emitted
    output reg                          lost_err,
    output reg                          align_err           // memory/lane outputs not aligned with the tag pipe
);
    // Cycles from the cycle in which rd_en is high (stage 1) to the cycle in which the lane's
    // out_valid is high: memory 3 (jrp_vector_buffer, READ_LAT 2) + distance unit 4.
    localparam integer FLAG_LAT = 7;
    // Plus one stage in the pair generator output register and one output register here.
    localparam integer SCAN_LAT = FLAG_LAT + 2;

    // ---- stage 0: pair generator (registered outputs) ----
    wire [N_BITS-1:0] g_i, g_j;
    wire              g_valid, g_last, g_done;
    jrp_pair_gen #(.N_BITS(N_BITS)) u_gen (
        .clk(clk), .rst_n(rst_n), .start(start), .n(n), .en(m_axis_tready),
        .i_out(g_i), .j_out(g_j), .valid(g_valid), .last(g_last), .done_pulse(g_done));

    // ---- stage 1: base-offset indices and read enables (registered) ----
    reg [N_BITS-1:0] t0_i, t0_j;
    reg              t0_last;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_en_ax <= 1'b0; rd_en_bx <= 1'b0; rd_en_ay <= 1'b0; rd_en_by <= 1'b0;
            rd_idx_ax <= 32'd0; rd_idx_bx <= 32'd0; rd_idx_ay <= 32'd0; rd_idx_by <= 32'd0;
            t0_i <= {N_BITS{1'b0}}; t0_j <= {N_BITS{1'b0}}; t0_last <= 1'b0;
        end else begin
            rd_en_ax <= g_valid; rd_en_bx <= g_valid; rd_en_ay <= g_valid; rd_en_by <= g_valid;
            if (g_valid) begin
                rd_idx_ax <= base_x + {{(32-N_BITS){1'b0}}, g_i};
                rd_idx_bx <= base_x + {{(32-N_BITS){1'b0}}, g_j};
                rd_idx_ay <= base_y + {{(32-N_BITS){1'b0}}, g_i};
                rd_idx_by <= base_y + {{(32-N_BITS){1'b0}}, g_j};
            end
            t0_i <= g_i; t0_j <= g_j; t0_last <= g_valid & g_last;
        end
    end

    // ---- tag pipe: carries (i, j, last) alongside the memory and lane latency ----
    localparam integer TW = 2*N_BITS + 1;
    reg [TW-1:0] tag [0:FLAG_LAT-1];
    reg [FLAG_LAT-1:0] tag_v;
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tag_v <= {FLAG_LAT{1'b0}};
            for (k = 0; k < FLAG_LAT; k = k + 1) tag[k] <= {TW{1'b0}};
        end else begin
            tag[0]  <= {t0_i, t0_j, t0_last};
            tag_v   <= {tag_v[FLAG_LAT-2:0], rd_en_ax};
            for (k = 1; k < FLAG_LAT; k = k + 1) tag[k] <= tag[k-1];
        end
    end

    // ---- lane ----
    wire lane_flag, lane_valid, lane_skew;
    jrp_lane #(.DATA_WIDTH(DATA_WIDTH), .MAX_M(MAX_M)) u_lane (
        .clk(clk), .rst_n(rst_n),
        .vec_ax(vec_ax), .vec_bx(vec_bx), .vx_valid(vec_ax_valid & vec_bx_valid),
        .vec_ay(vec_ay), .vec_by(vec_by), .vy_valid(vec_ay_valid & vec_by_valid),
        .m_x(m_x), .m_y(m_y), .eps2_x(eps2_x), .eps2_y(eps2_y),
        .flag(lane_flag), .out_valid(lane_valid), .skew_err(lane_skew));

    // ---- output register ----
    wire [TW-1:0] tag_out = tag[FLAG_LAT-1];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tdata <= {(2*N_BITS+1){1'b0}}; m_axis_tvalid <= 1'b0;
            pairs_done_pulse <= 1'b0; cells_done_pulse <= 1'b0;
            lost_err <= 1'b0; align_err <= 1'b0;
        end else begin
            pairs_done_pulse <= g_done;
            cells_done_pulse <= 1'b0;
            if (start) begin lost_err <= 1'b0; align_err <= 1'b0; end
            m_axis_tvalid <= lane_valid;
            if (lane_valid) begin
                m_axis_tdata <= {tag_out[TW-1:1], lane_flag};
                if (tag_out[0]) cells_done_pulse <= 1'b1;
            end
            // a presented beat that the sink does not take is overwritten by the next one
            if (m_axis_tvalid && !m_axis_tready) lost_err <= 1'b1;
            if (lane_skew || (lane_valid != tag_v[FLAG_LAT-1]) ||
                (vec_ax_valid != vec_bx_valid) || (vec_ay_valid != vec_by_valid) ||
                (vec_ax_valid != vec_ay_valid))
                align_err <= 1'b1;
        end
    end
endmodule
