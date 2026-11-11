`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// jrp_pair_gen_k2.v
//   Full N x N pair generator for K = 2: one beat per cycle, each beat is the two adjacent
//   cells (i, j0) and (i, j0 + 1) of a row, j0 even. Row-major order as the released
//   grid_index_gen.v (Li, Lai and Oberst 2026, Zenodo 10.5281/zenodo.20406392, MIT) and
//   jrp_pair_gen.v, two cells at a time. `valid1` is low on the last beat of a row of odd length.
//   `en` low pauses the scan with no beat lost.
//   For n <= 2 a beat is issued every second cycle: consecutive rows then touch the same state
//   words in consecutive beats, which the extractor's read-modify-write loop cannot take.
// -----------------------------------------------------------------------------
module jrp_pair_gen_k2 #(
    parameter integer N_BITS = 14
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                start,      // one-cycle pulse, loads n and restarts the scan
    input  wire [31:0]         n,
    input  wire                en,
    output reg  [N_BITS-1:0]   i_out,
    output reg  [N_BITS-1:0]   j_out,      // j0, even
    output reg                 valid,
    output reg                 valid1,     // second cell (j0 + 1) exists
    output reg                 last,
    output reg                 done_pulse
);
    reg               run;
    reg [31:0]        n_r;
    reg [N_BITS-1:0]  i_r, j_r;

    wire [31:0] j_next = {{(32-N_BITS){1'b0}}, j_r} + 32'd2;
    wire [31:0] i_next = {{(32-N_BITS){1'b0}}, i_r} + 32'd1;
    wire        slow   = (n_r <= 32'd2);
    wire        issue  = run && en && !(slow && valid);
    wire [31:0] j_one  = {{(32-N_BITS){1'b0}}, j_r} + 32'd1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run <= 1'b0; n_r <= 32'd0; i_r <= {N_BITS{1'b0}}; j_r <= {N_BITS{1'b0}};
            i_out <= {N_BITS{1'b0}}; j_out <= {N_BITS{1'b0}};
            valid <= 1'b0; valid1 <= 1'b0; last <= 1'b0; done_pulse <= 1'b0;
        end else begin
            valid <= 1'b0; valid1 <= 1'b0; last <= 1'b0; done_pulse <= 1'b0;
            if (start) begin
                n_r <= n;
                run <= (n != 32'd0);
                i_r <= {N_BITS{1'b0}};
                j_r <= {N_BITS{1'b0}};
            end else if (issue) begin
                i_out <= i_r; j_out <= j_r; valid <= 1'b1; valid1 <= (j_one < n_r);
                if (j_next >= n_r) begin
                    j_r <= {N_BITS{1'b0}};
                    if (i_next == n_r) begin
                        run <= 1'b0; last <= 1'b1; done_pulse <= 1'b1;
                    end else begin
                        i_r <= i_r + 1'b1;
                    end
                end else begin
                    j_r <= j_r + 2'd2;
                end
            end
        end
    end
endmodule
