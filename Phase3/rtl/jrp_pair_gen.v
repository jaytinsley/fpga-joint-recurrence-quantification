`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// jrp_pair_gen.v
//   Full N x N pair generator, one pair per cycle, registered outputs.
//   Pair order is the one of the released grid_index_gen.v (Li, Lai and Oberst 2026,
//   Zenodo 10.5281/zenodo.20406392, MIT): i outer, j inner, i = j included.
//   Differences from the released module: no per-pair handshake. A pair is issued in
//   every cycle in which `en` is high; `en` low pauses the scan with no pair lost.
//   `valid`, `i_out`, `j_out`, `last` are registered together. `done_pulse` coincides
//   with the last pair.
// -----------------------------------------------------------------------------
module jrp_pair_gen #(
    parameter integer N_BITS = 14
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                start,      // one-cycle pulse, loads n and restarts the scan
    input  wire [31:0]         n,          // vectors per channel after alignment
    input  wire                en,         // issue enable (pauses the scan when low)
    output reg  [N_BITS-1:0]   i_out,
    output reg  [N_BITS-1:0]   j_out,
    output reg                 valid,
    output reg                 last,
    output reg                 done_pulse
);
    reg               run;
    reg [31:0]        n_r;
    reg [N_BITS-1:0]  i_r, j_r;

    wire [31:0] j_next = {{(32-N_BITS){1'b0}}, j_r} + 32'd1;
    wire [31:0] i_next = {{(32-N_BITS){1'b0}}, i_r} + 32'd1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run <= 1'b0; n_r <= 32'd0; i_r <= {N_BITS{1'b0}}; j_r <= {N_BITS{1'b0}};
            i_out <= {N_BITS{1'b0}}; j_out <= {N_BITS{1'b0}};
            valid <= 1'b0; last <= 1'b0; done_pulse <= 1'b0;
        end else begin
            valid <= 1'b0; last <= 1'b0; done_pulse <= 1'b0;
            if (start) begin
                n_r <= n;
                run <= (n != 32'd0);
                i_r <= {N_BITS{1'b0}};
                j_r <= {N_BITS{1'b0}};
            end else if (run && en) begin
                i_out <= i_r; j_out <= j_r; valid <= 1'b1;
                if (j_next == n_r) begin
                    j_r <= {N_BITS{1'b0}};
                    if (i_next == n_r) begin
                        run <= 1'b0; last <= 1'b1; done_pulse <= 1'b1;
                    end else begin
                        i_r <= i_r + 1'b1;
                    end
                end else begin
                    j_r <= j_r + 1'b1;
                end
            end
        end
    end
endmodule
