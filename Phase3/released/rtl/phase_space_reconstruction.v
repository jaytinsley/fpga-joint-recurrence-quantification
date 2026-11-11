
// phase_space_reconstruction.v
// Build m-dimensional delay-embedded vectors inside PL.
// data_in: scalar sample stream; vector_out: packed [MAX_M*DATA_WIDTH] bus.
//
// Latency: needs (m-1)*tau samples to fill before vector_valid can assert.
// Backpressure: data_ready reflects downstream vector_ready so we never overrun.
`timescale 1ns / 1ps
module phase_space_reconstruction #(
    parameter integer DATA_WIDTH = 32,
    parameter integer MAX_M      = 10,
    parameter integer MAX_TAU    = 128
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Scalar sample stream (from AXIS sink)
    input  wire [DATA_WIDTH-1:0]        data_in,
    input  wire                         data_valid,
    input  wire                         data_last,     // AXIS TLAST
    output wire                         data_ready,

    // Runtime controls
    input  wire [7:0]                   m_dim,       // 1..MAX_M
    input  wire [7:0]                   tau_delay,   // 1..MAX_TAU

    // Packed vector output
    output reg  [DATA_WIDTH*MAX_M-1:0]  vector_out,
    output reg                          vector_valid,
    input  wire                         vector_ready,

    // Optional: expose N_actual (count of vectors produced in this frame)
    input  wire                         frame_start,
    output reg                          ingest_done_pulse, 
    output reg  [31:0]                  n_actual,
    input  wire [31:0]                  n_target
);
    // Effective buffer depth: (MAX_M-1)*MAX_TAU
    localparam integer BUFFER_DEPTH = (MAX_M-1) * MAX_TAU;
    localparam integer PTRW = (BUFFER_DEPTH<=1) ? 1 : $clog2(BUFFER_DEPTH);

    // Circular buffer for history
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] hist [0:BUFFER_DEPTH-1];

    reg [PTRW-1:0] wr_ptr;
    reg [31:0]     sample_cnt;
    reg            gen_en;
    reg [31:0] samp_cnt_total;
    // Flow control: accept a scalar when downstream can consume/propagate
    assign data_ready = vector_ready || !vector_valid;
 
    integer i;
    // Signed arithmetic not needed for indexing; wrap helpers
    function [PTRW-1:0] sub_wrap;
        input [PTRW-1:0] a;
        input [31:0]     offs;
        begin
            sub_wrap = a - offs[PTRW-1:0];
        end
    endfunction


    // Main logic
    reg [PTRW-1:0] wr_ptr_dly;  // capture write pointer for consistent indexing
    reg saw_last_q;
    wire accept = data_valid && data_ready;
    wire [31:0]     sample_cnt_next = sample_cnt + (accept ? 32'd1 : 32'd0);
    wire [31:0] need = (m_dim>=1) ? ( (m_dim-1) * tau_delay ) : 32'd0;
    wire can_emit = (sample_cnt >= need);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr       <= {PTRW{1'b0}};
            wr_ptr_dly   <= {PTRW{1'b0}};
            sample_cnt   <= 32'd0;
            gen_en       <= 1'b0;
            vector_valid <= 1'b0;
            vector_out   <= {DATA_WIDTH*MAX_M{1'b0}};
            ingest_done_pulse <= 1'b0;
            saw_last_q <= 1'b0;
            n_actual <= 32'd0;
            samp_cnt_total    <= 32'd0;
        end else begin
            ingest_done_pulse <= 1'b0;
            
            if (frame_start) begin
                wr_ptr     <= {PTRW{1'b0}};
                wr_ptr_dly <= {PTRW{1'b0}};
                sample_cnt <= 32'd0;
                gen_en     <= 1'b0;
                vector_valid <= 1'b0;
                n_actual <= 32'd0;
                saw_last_q <= 1'b0;
                samp_cnt_total <= 32'd0;
            end

            // accept scalar
            if (accept) begin
                samp_cnt_total <= samp_cnt_total + 1'b1;
                hist[wr_ptr] <= data_in;
                wr_ptr       <= (wr_ptr == BUFFER_DEPTH-1) ? {PTRW{1'b0}} : wr_ptr + 1'b1;
                wr_ptr_dly   <= wr_ptr + 1'b1;

                if (sample_cnt < BUFFER_DEPTH) sample_cnt <= sample_cnt + 1;
                if (data_last) saw_last_q <= 1'b1;
                if (samp_cnt_total + 1 == n_target) begin
                    ingest_done_pulse <= 1'b1;
                end
            end
            if (accept && can_emit) begin
                // component 0 is the current sample just written
                vector_out[DATA_WIDTH-1:0] <= data_in;
                // remaining components come from history at multiples of tau
                for (i = 1; i < MAX_M; i = i + 1) begin : GEN_COMP
                    if (i < m_dim) begin
                        // Read position = wr_ptr_dly - i*tau (wrap)
                        vector_out[i*DATA_WIDTH +: DATA_WIDTH] <= hist[sub_wrap(wr_ptr_dly, i*tau_delay)];
                    end else begin
                        vector_out[i*DATA_WIDTH +: DATA_WIDTH] <= {DATA_WIDTH{1'b0}};
                    end
                end
                vector_valid <= 1'b1;
            end 
            else if (vector_valid && vector_ready) begin
                vector_valid <= 1'b0;
            end
            if (vector_valid && vector_ready) n_actual <= n_actual + 1;
        end
    end
endmodule
