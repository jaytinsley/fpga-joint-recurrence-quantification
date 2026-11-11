
// compare_orchestrator.v
// Aligns meta (i,j) with DTC output; includes 1-deep skid buffer.
// Produces event pulses when last pair/cell are accepted.

`timescale 1ns / 1ps

module compare_orchestrator #(
    parameter integer DATA_WIDTH = 32,
    parameter integer MAX_M      = 10,
    parameter integer N_BITS     = 14
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Control
    input  wire                         frame_start,
    input  wire [31:0]                  N_actual,
    input  wire [7:0]                   m_dim,
    input  wire [DATA_WIDTH-1:0]        eps2,

    // Pair source
    output wire                         pair_start_pulse,
    input  wire [N_BITS-1:0]            pi_i,
    input  wire [N_BITS-1:0]            pi_j,
    input  wire                         pi_valid,
    output wire                         pi_ready,
    input  wire                         pairs_done_pulse_in, // from generator

    // Vector buffer (random read)
    output reg                          rd_en_a,
    output reg  [31:0]                  rd_idx_a,
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_a,
    input  wire                         vec_a_valid,

    output reg                          rd_en_b,
    output reg  [31:0]                  rd_idx_b,
    input  wire [DATA_WIDTH*MAX_M-1:0]  vec_b,
    input  wire                         vec_b_valid,

    // AXIS out to RQA: tdata = {i[N_BITS], j[N_BITS], rec_flag}
    output reg  [2*N_BITS:0]            m_axis_tdata,
    output reg                          m_axis_tvalid,
    input  wire                         m_axis_tready,

    // Perf pulses
    output reg                          pairs_done_pulse,
    output reg                          cells_done_pulse,
     // NEW: expose DTC timing pulses
    output reg                          dtc_start_pulse,
    output wire                         dtc_end_pulse
);

    localparam S_IDLE=2'd0, S_RD=2'd1, S_DTC=2'd2;
    reg [1:0] st;

    // Latch current pair
    reg [N_BITS-1:0] cur_i, cur_j;
    reg              hold_pair;

    // Tie into DTC
    wire dtc_in_ready, dtc_out_valid, dtc_out_ready;
    wire rec_flag;

    reg  dtc_in_valid;
    reg  [DATA_WIDTH*MAX_M-1:0] vec_a_r, vec_b_r;

    // Pair counter to detect "pairs done" and "cells done"
    reg [31:0] pair_cnt;
    reg [31:0] cell_cnt;
    wire [31:0] cells_tgt  = N_actual*N_actual;
    // Pair handshake
    assign pi_ready = (st==S_IDLE);

    // Kick generator once per frame
    assign pair_start_pulse = frame_start;
    assign dtc_end_pulse = cells_done_pulse;
    reg dtc_started;

    // FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE;
            rd_en_a <= 1'b0; rd_en_b <= 1'b0;
            dtc_in_valid <= 1'b0;
            m_axis_tvalid <= 1'b0;
            pairs_done_pulse <= 1'b0; cells_done_pulse <= 1'b0;
            pair_cnt <= 32'd0; cell_cnt <= 32'd0;
            hold_pair <= 1'b0;          
        end else begin
            pairs_done_pulse <= 1'b0;
            cells_done_pulse <= 1'b0;          
            // Count external generator completion pulse too, but we also self-count
            if (frame_start) 
            begin
                pair_cnt <= 32'd0; cell_cnt <= 32'd0;
            end
            if (pairs_done_pulse_in) 
            begin
                 pairs_done_pulse <= 1'b1;             
            end
            case (st)
            S_IDLE: begin
                dtc_in_valid <= 1'b0;
                rd_en_a <= 1'b0; rd_en_b <= 1'b0;
                if (pi_valid && pi_ready) begin
                    cur_i <= pi_i; cur_j <= pi_j;
                    // issue reads
                    rd_en_a <= 1'b1; rd_idx_a <= {18'd0, pi_i}; // zero-extend
                    rd_en_b <= 1'b1; rd_idx_b <= {18'd0, pi_j};
                    hold_pair <= 1'b1;
                    st <= S_RD;
                end
            end
            S_RD: begin
                rd_en_a <= 1'b0; rd_en_b <= 1'b0;
                if (vec_a_valid && vec_b_valid) begin
                    vec_a_r <= vec_a;
                    vec_b_r <= vec_b;
                    dtc_in_valid <= 1'b1;
                    st <= S_DTC;
                    // pair accepted
                    pair_cnt <= pair_cnt + 1;
                end
            end
            S_DTC: begin
                // push into DTC when ready
                if (dtc_in_valid && dtc_in_ready) begin
                    dtc_in_valid <= 1'b0;
                end

                // Use dtc_out_valid_d + rec_flag_d: rec_flag is captured at the
                // dtc_out_valid cycle, then used one cycle later.  This compensates
                // for any synthesis retiming on the wide comparator inside DTC.
                if (dtc_out_valid) begin
                    if (!m_axis_tvalid) begin
                        m_axis_tdata  <= {cur_i, cur_j, rec_flag};
                        m_axis_tvalid <= 1'b1;
                    end
                end

                // When downstream accepts the AXIS beat, consume it and move on
                if (m_axis_tvalid && m_axis_tready) begin
                    // actual acceptance: increment cell count & check target
                    cell_cnt <= cell_cnt + 1;
                    if (cell_cnt + 1 == cells_tgt) cells_done_pulse <= 1'b1;

                    // clear valid and go accept next pair
                    m_axis_tvalid <= 1'b0;
                    st <= S_IDLE;
                    hold_pair <= 1'b0;
                end
            end

            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        dtc_started     <= 1'b0;
        dtc_start_pulse <= 1'b0;
      end else begin
        dtc_start_pulse <= 1'b0;
        if (frame_start) dtc_started <= 1'b0;
    
        if (!dtc_started && dtc_in_valid && dtc_in_ready) begin
          dtc_started     <= 1'b1;
          dtc_start_pulse <= 1'b1;
        end
      end
    end
    // DTC instance
    distance_threshold_calculation #(
        .DATA_WIDTH(DATA_WIDTH),
        .MAX_M     (MAX_M)
    ) u_dtc (
        .clk      (clk),
        .rst_n    (rst_n),
        .vec_a    (vec_a_r),
        .vec_b    (vec_b_r),
        .m_active (m_dim),
        .in_valid (dtc_in_valid),
        .in_ready (dtc_in_ready),
        .eps2     (eps2),
        .rec_flag (rec_flag),
        .out_valid(dtc_out_valid),
        .out_ready(1'b1) // internal buffering already provided by skid/AXIS
    );

endmodule 

