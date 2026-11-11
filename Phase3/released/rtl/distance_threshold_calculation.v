
//////////////////////////////////////////////////////////////////////////////////
// distance_threshold_calculation.v
// Computes squared L2 distance between two packed vectors and compares to eps2.
// Fully pipelined; accepts one vector-pair per cycle when downstream ready.
//
// Notes:
// - MAX_M components are wired; 'm_active' masks extras to zero.
// - DATA_WIDTH can be float or fixed-point; typical is fixed-point Q-format.
//   If using float, replace the sum pipeline with a floating adder tree.

`timescale 1ns / 1ps

module distance_threshold_calculation #(
    parameter integer DATA_WIDTH = 32,
    parameter integer MAX_M      = 10
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Packed vectors
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_a,
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_b,
    input  wire [7:0]                   m_active,

    // Handshake
    input  wire                         in_valid,
    output wire                         in_ready,

    input  wire [DATA_WIDTH-1:0]        eps2,       // same numeric domain as squared sum (integer)
    output reg                          rec_flag,
    output reg                          out_valid,
    input  wire                         out_ready
);
    // Backpressure: accept new input when final stage can progress
    assign in_ready = out_ready || !out_valid;

    // SUMW must hold sum of up to MAX_M squares each of width 2*DATA_WIDTH.
    localparam SUMW = 2*DATA_WIDTH + $clog2(MAX_M);
    // FRAC: fractional bits in the Q-format of input data.
    // Data is Q8.24 (value = x * 2^24), so FRAC=24.
    // eps2_ext = eps2_q << FRAC, bringing it to the same 2^48 scale as stage_sum.
    localparam integer FRAC = 24;
    // pipeline valids
    reg v_s1, v_s2, v_s3;

    // stage registers
    // diffs (signed)
    reg signed [DATA_WIDTH-1:0] diff [0:MAX_M-1];

    // squares (unsigned) -- 2*DATA_WIDTH width
    reg [2*DATA_WIDTH-1:0] sq [0:MAX_M-1];

    // accumulation
    reg [SUMW-1:0] stage_sum;
    reg [SUMW-1:0] acc;

    // register copy of threshold expanded to SUMW for compare
    reg [SUMW-1:0] eps2_ext;
    reg [DATA_WIDTH-1:0] eps2_r;

    integer i;

    // ------------------------------------------------------------------
    // Stage 1: capture diffs when input accepted
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_s1 <= 1'b0;
            for (i=0;i<MAX_M;i=i+1) diff[i] <= 'd0;
        end else begin
            // when input accepted (in_ready & in_valid), latch diffs
            if (in_ready) begin
                v_s1 <= in_valid;
                if (in_valid) begin
                    for (i=0;i<MAX_M;i=i+1) begin
                        if (i < m_active)
                            diff[i] <= $signed(vec_a[i*DATA_WIDTH +: DATA_WIDTH]) - $signed(vec_b[i*DATA_WIDTH +: DATA_WIDTH]);
                        else
                            diff[i] <= 'd0;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Stage 2: squares (registered) -- compute when v_s1 asserted
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_s2 <= 1'b0;
            for (i=0;i<MAX_M;i=i+1) sq[i] <= {2*DATA_WIDTH{1'b0}};
        end else begin
            // advance valid
            v_s2 <= v_s1;
            // compute squares from registered diffs when v_s1 was asserted
            if (v_s1) begin
                for (i=0;i<MAX_M;i=i+1) begin
                    // diff is signed; square result is non-negative -> store into unsigned sq
                    // Use explicit cast to signed*signed to infer DSP multiplier if possible
                    sq[i] <= $signed(diff[i]) * $signed(diff[i]);
                end
            end else begin
                // optional: keep previous or clear; keeping previous is fine as stage enables via v_s2
                // Here we clear to be deterministic
                for (i=0;i<MAX_M;i=i+1) sq[i] <= {2*DATA_WIDTH{1'b0}};
            end
        end
    end

    // ------------------------------------------------------------------
    // Stage 3: accumulation into stage_sum (blocking local accumulate then register)
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_s3 <= 1'b0;
            stage_sum <= {SUMW{1'b0}};
            acc <= {SUMW{1'b0}};
        end else begin
            v_s3 <= v_s2;
            if (v_s2) begin
                // compute accumulator combinationally into acc (blocking style)
                acc = {SUMW{1'b0}};
                for (i=0;i<MAX_M;i=i+1) begin
                    // zero-extend each sq[i] into SUMW width
                    acc = acc + {{(SUMW - (2*DATA_WIDTH)){1'b0}}, sq[i]};
                end
                stage_sum <= acc;
            end
        end
    end

    // ------------------------------------------------------------------
    // Final compare and output register
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            rec_flag  <= 1'b0;
            eps2_r    <= {DATA_WIDTH{1'b0}};
            eps2_ext  <= {SUMW{1'b0}};
        end else begin
            // capture threshold when new input accepted (follow previous behavior)
            if (in_ready) begin
                eps2_r <= eps2;
                eps2_ext <= {{(SUMW - DATA_WIDTH - FRAC){1'b0}}, eps2, {FRAC{1'b0}}}; // Q8.24 data: shift eps2_q left by FRAC=24
            end

            if (out_ready || !out_valid) begin
                out_valid <= v_s3;
                if (v_s3) begin
                    // full-width compare
                    rec_flag <= (stage_sum <= eps2_ext);
                end
            end
        end
    end

endmodule
