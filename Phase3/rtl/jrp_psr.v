`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// jrp_psr.v
//   Streaming delay embedding with the same ports and handshake as the released
//   phase_space_reconstruction.v (Li, Lai and Oberst 2026, Zenodo 10.5281/zenodo.20406392, MIT).
//   Vector t = {x[t], x[t-tau], ..., x[t-(m-1) tau]}, component 0 = newest sample, zero above m.
//   The first vector is emitted once (m-1) tau samples of history exist.
//
//   Why a replacement: in the released module the history buffer has (MAX_M-1)*MAX_TAU entries
//   (144 in the released top level, 80 for MAX_M = 6) but the read address is formed by plain
//   PTRW-bit subtraction, which is only correct for a power-of-two depth. Once the write pointer
//   has wrapped, reads can land on locations that were never written (simulation: 'x' vectors
//   from the 135th vector on, 728 of 4084 wrong at N = 4096 with MAX_M = 10, MAX_TAU = 16).
//   Here the history is a shift register, so no pointer arithmetic exists, and each tap is a
//   MAX_TAU-to-1 selection instead of a read port on a RAM.
//   tau_delay must be 1..MAX_TAU and m_dim 1..MAX_M; values outside give zero components.
// -----------------------------------------------------------------------------
module jrp_psr #(
    parameter integer DATA_WIDTH = 32,
    parameter integer MAX_M      = 6,
    parameter integer MAX_TAU    = 16
)(
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire [DATA_WIDTH-1:0]        data_in,
    input  wire                         data_valid,
    input  wire                         data_last,      // unused, kept for port compatibility
    output wire                         data_ready,

    input  wire [7:0]                   m_dim,
    input  wire [7:0]                   tau_delay,

    output reg  [DATA_WIDTH*MAX_M-1:0]  vector_out,
    output reg                          vector_valid,
    input  wire                         vector_ready,

    input  wire                         frame_start,
    output reg                          ingest_done_pulse,
    output reg  [31:0]                  n_actual,       // vectors produced this frame
    input  wire [31:0]                  n_target        // samples per frame
);
    localparam integer DEPTH = (MAX_M > 1) ? (MAX_M-1)*MAX_TAU : 1;

    // hist[0] = previous sample x[t-1], hist[d] = x[t-1-d]
    reg [DATA_WIDTH-1:0] hist [0:DEPTH-1];
    reg [31:0] sample_cnt;      // samples accepted this frame, saturating at DEPTH
    reg [31:0] samp_cnt_total;

    assign data_ready = vector_ready || !vector_valid;
    wire accept = data_valid && data_ready;
    wire [31:0] need = (m_dim >= 8'd1) ? ((m_dim - 8'd1) * tau_delay) : 32'd0;
    wire can_emit = (sample_cnt >= need);

    // tap i (1 .. MAX_M-1): x[t - i*tau] = hist[i*tau - 1]
    reg [DATA_WIDTH-1:0] tap [0:MAX_M-1];
    integer ti, tt;
    always @(*) begin
        for (ti = 0; ti < MAX_M; ti = ti + 1) tap[ti] = {DATA_WIDTH{1'b0}};
        for (ti = 1; ti < MAX_M; ti = ti + 1)
            for (tt = 1; tt <= MAX_TAU; tt = tt + 1)
                if (ti < m_dim && tau_delay == tt) tap[ti] = hist[ti*tt - 1];
    end

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_cnt <= 32'd0; samp_cnt_total <= 32'd0;
            vector_valid <= 1'b0; vector_out <= {DATA_WIDTH*MAX_M{1'b0}};
            ingest_done_pulse <= 1'b0; n_actual <= 32'd0;
            for (k = 0; k < DEPTH; k = k + 1) hist[k] <= {DATA_WIDTH{1'b0}};
        end else begin
            ingest_done_pulse <= 1'b0;
            if (frame_start) begin
                sample_cnt <= 32'd0; samp_cnt_total <= 32'd0;
                vector_valid <= 1'b0; n_actual <= 32'd0;
            end
            if (accept) begin
                samp_cnt_total <= samp_cnt_total + 1'b1;
                if (sample_cnt < DEPTH) sample_cnt <= sample_cnt + 1;
                hist[0] <= data_in;
                for (k = 1; k < DEPTH; k = k + 1) hist[k] <= hist[k-1];
                if (samp_cnt_total + 1 == n_target) ingest_done_pulse <= 1'b1;
            end
            if (accept && can_emit) begin
                vector_out[DATA_WIDTH-1:0] <= data_in;
                for (k = 1; k < MAX_M; k = k + 1)
                    vector_out[k*DATA_WIDTH +: DATA_WIDTH] <= tap[k];
                vector_valid <= 1'b1;
            end else if (vector_valid && vector_ready) begin
                vector_valid <= 1'b0;
            end
            if (vector_valid && vector_ready) n_actual <= n_actual + 1;
        end
    end
endmodule
