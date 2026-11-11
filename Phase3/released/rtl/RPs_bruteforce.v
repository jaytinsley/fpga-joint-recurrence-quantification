`timescale 1ns / 1ps
module RPs_bruteforce #(
    parameter integer DATA_WIDTH = 32,
    parameter integer MAX_M      = 10,
    parameter integer N_MAX      = 8192,
    parameter integer N_BITS     = 14,
    parameter integer HIST_W      = 14,
    parameter integer HIST_K      = 8192

)(
    input  wire                         clk,          // fabric clock (e.g., 150 MHz)
    input  wire                         rst_n,

    // AXI-Lite control
    input  wire [11:0]                  s_axi_awaddr,
    input  wire                         s_axi_awvalid,
    output wire                         s_axi_awready,
    input  wire [31:0]                  s_axi_wdata,
    input  wire [3:0]                   s_axi_wstrb,
    input  wire                         s_axi_wvalid,
    output wire                         s_axi_wready,
    output wire [1:0]                   s_axi_bresp,
    output wire                         s_axi_bvalid,
    input  wire                         s_axi_bready,

    input  wire [11:0]                  s_axi_araddr,
    input  wire                         s_axi_arvalid,
    output wire                         s_axi_arready,
    output wire [31:0]                  s_axi_rdata,
    output wire [1:0]                   s_axi_rresp,
    output wire                         s_axi_rvalid,
    input  wire                         s_axi_rready,

    // ========= new RQA AXI-Lite slave (dedicated to RQA readout) ========
    input  wire [16:0]        s_axi_rqa_awaddr,
    input  wire               s_axi_rqa_awvalid,
    output wire               s_axi_rqa_awready,
    input  wire [31:0]        s_axi_rqa_wdata,
    input  wire [3:0]         s_axi_rqa_wstrb,
    input  wire               s_axi_rqa_wvalid,
    output wire               s_axi_rqa_wready,
    output wire [1:0]         s_axi_rqa_bresp,
    output wire               s_axi_rqa_bvalid,
    input  wire               s_axi_rqa_bready,
    input  wire [16:0]        s_axi_rqa_araddr,
    input  wire               s_axi_rqa_arvalid,
    output wire               s_axi_rqa_arready,
    output wire [31:0]        s_axi_rqa_rdata,
    output wire [1:0]         s_axi_rqa_rresp,
    output wire               s_axi_rqa_rvalid,
    input  wire               s_axi_rqa_rready,

    // AXI-Stream scalar samples (from AXI-DMA MM2S)
    input  wire [DATA_WIDTH-1:0]        s_axis_samples_tdata,
    input  wire                         s_axis_samples_tvalid,
    output wire                         s_axis_samples_tready,
    input  wire                         s_axis_samples_tlast,

    // Perf AXI-Lite (expose as a second slave or pack separately)
    input  wire [5:0]                   pm_awaddr,
    input  wire                         pm_awvalid,
    output wire                         pm_awready,
    input  wire [31:0]                  pm_wdata,
    input  wire [3:0]                   pm_wstrb,
    input  wire                         pm_wvalid,
    output wire                         pm_wready,
    output wire [1:0]                   pm_bresp,
    output wire                         pm_bvalid,
    input  wire                         pm_bready,

    input  wire [5:0]                   pm_araddr,
    input  wire                         pm_arvalid,
    output wire                         pm_arready,
    output wire [31:0]                  pm_rdata,
    output wire [1:0]                   pm_rresp,
    output wire                         pm_rvalid,
    input  wire                         pm_rready
);

    // ---------------- AXI-Lite regs ----------------
    wire start_pulse, soft_reset_pulse, frame_end_pulse;
    wire [31:0] n_raw;
    wire [7:0]  m_dim;
    wire [7:0]  tau_delay;
    wire [31:0] eps2_q;
    wire [31:0] l_min, v_min;

    wire psr_in_ready;
    wire ing_busy;
    wire scan_busy;
    wire metrics_valid_pulse;

    wire [31:0] n_actual_psr; // raw PSR-produced count (debug/info)

    // PSR
    wire data_ready, data_valid;
    wire [31:0] n_loaded;

    reg        rqa_start_pulse;
    reg        pairs_start_pulse_gen;
    reg [31:0] N_frame;
    reg [31:0] cells_target_reg;
    reg ingest_done_d1, ingest_done_d2; // two-cycle delay so n_actual_psr includes last vector
    always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        rqa_start_pulse       <= 1'b0;
        pairs_start_pulse_gen <= 1'b0;
        N_frame               <= 32'd0;
        cells_target_reg      <= 32'd0;
        ingest_done_d1        <= 1'b0;
        ingest_done_d2        <= 1'b0;
      end else begin
        ingest_done_d1    <= frame_end_pulse;
        ingest_done_d2    <= ingest_done_d1;  // extra cycle: wait for last n_actual_psr increment
        rqa_start_pulse       <= 1'b0;
        pairs_start_pulse_gen <= 1'b0;
    
        if (ingest_done_d2) begin
          N_frame          <= n_actual_psr;          // now includes last vector
          cells_target_reg <= n_actual_psr * n_actual_psr;  // N*N
          rqa_start_pulse  <= 1'b1;
          pairs_start_pulse_gen <= 1'b1;
        end
      end
    end

    // ---------------- axi parameters ----------------------------------------//
    axi_lite_regs u_regs (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),

        .start_pulse(start_pulse),
        .soft_reset_pulse(soft_reset_pulse),

        .n_raw(n_raw),
        .m_dim(m_dim),
        .tau_delay(tau_delay),
        .eps2_q(eps2_q),
        .l_min(l_min),
        .v_min(v_min),

        .n_actual(N_frame),          
        .psr_in_ready(psr_in_ready),
        .ing_busy(ing_busy),
        .scan_busy(scan_busy),
        .metrics_valid(metrics_valid_pulse)
    );

    // ---------------- PSR ingest (AXIS samples -> PSR) ----------------
    assign s_axis_samples_tready = data_ready;
    assign data_valid            = s_axis_samples_tvalid;
    wire [DATA_WIDTH-1:0] data_in = s_axis_samples_tdata;
    wire  data_last;
    assign data_last = s_axis_samples_tlast;
    wire [DATA_WIDTH*MAX_M-1:0] vec_psr_out;
    wire                        vec_psr_valid;
    wire                        vec_psr_ready;

    phase_space_reconstruction #(
        .DATA_WIDTH(DATA_WIDTH),
        .MAX_M     (MAX_M),
        .MAX_TAU   (16)
    ) u_psr (
        .clk(clk), .rst_n(rst_n),
        .data_in(data_in), .data_valid(data_valid), 
        .data_last(data_last),
        .data_ready(data_ready),
        .m_dim(m_dim), .tau_delay(tau_delay),
        .vector_out(vec_psr_out), .vector_valid(vec_psr_valid), .vector_ready(vec_psr_ready),
        .frame_start(start_pulse), .ingest_done_pulse(frame_end_pulse),
        .n_actual(n_actual_psr),
        .n_target(n_raw)
    );

    // ---------------- Vector buffer ----------------
    wire vec_rd_en_a, vec_rd_en_b;
    wire [31:0] vec_rd_idx_a, vec_rd_idx_b;
    wire [DATA_WIDTH*MAX_M-1:0] vec_a, vec_b;
    wire vec_a_valid, vec_b_valid;

    vector_buffer #(
        .DATA_WIDTH(DATA_WIDTH), .MAX_M(MAX_M), .N_MAX(N_MAX)
    ) u_vbuf (
        .clk(clk), .rst_n(rst_n),
        .frame_start(start_pulse), .frame_end(),
        .s_vec_tdata (vec_psr_out),
        .s_vec_tvalid(vec_psr_valid),
        .s_vec_tready(vec_psr_ready),
        .n_loaded(n_loaded),
        .rd_en_a(vec_rd_en_a), .rd_idx_a(vec_rd_idx_a), .vec_a(vec_a), .vec_a_valid(vec_a_valid),
        .rd_en_b(vec_rd_en_b), .rd_idx_b(vec_rd_idx_b), .vec_b(vec_b), .vec_b_valid(vec_b_valid)
    );

    assign psr_in_ready = data_ready;

    wire [N_BITS-1:0] pi_i, pi_j;
    wire               pi_valid, pi_ready, gen_done_pulse;

    grid_index_gen #(
      .N_BITS(N_BITS)
    ) u_pairs (
        .clk(clk), .rst_n(rst_n),
        .start_pulse(pairs_start_pulse_gen),  
        .N(N_frame),
        .i_out(pi_i), .j_out(pi_j),
        .valid(pi_valid), .ready(pi_ready),
        .done_pulse(gen_done_pulse)
    );

    // ---------------- Compare orchestrator + DTC ----------------
    wire [2*N_BITS:0] cells_tdata;
    wire              cells_tvalid, cells_tready;
    wire              pairs_done_pulse, cells_done_pulse;
    wire              dtc_start_pulse,dtc_end_pulse;

    compare_orchestrator #(
        .DATA_WIDTH(DATA_WIDTH), .MAX_M(MAX_M), .N_BITS(N_BITS)
    ) u_orch (
        .clk(clk), .rst_n(rst_n),
        .frame_start(pairs_start_pulse_gen),   
        .N_actual(N_frame),
        .m_dim(m_dim), .eps2(eps2_q),
        .pair_start_pulse(),  // generator driven by start pulse directly (unused)
        .pi_i(pi_i), .pi_j(pi_j), .pi_valid(pi_valid), .pi_ready(pi_ready),
        .pairs_done_pulse_in(gen_done_pulse),
        .rd_en_a(vec_rd_en_a), .rd_idx_a(vec_rd_idx_a), .vec_a(vec_a), .vec_a_valid(vec_a_valid),
        .rd_en_b(vec_rd_en_b), .rd_idx_b(vec_rd_idx_b), .vec_b(vec_b), .vec_b_valid(vec_b_valid),
        .m_axis_tdata(cells_tdata), .m_axis_tvalid(cells_tvalid), .m_axis_tready(cells_tready),
        .pairs_done_pulse(pairs_done_pulse), .cells_done_pulse(cells_done_pulse),
        .dtc_start_pulse(dtc_start_pulse), .dtc_end_pulse(dtc_end_pulse)
    );

    assign ing_busy  = pi_valid | ~gen_done_pulse; // ���� busy
    assign scan_busy = ~metrics_valid_pulse;

    // ---------------- RQA extractor ----------------
    RQA_extractor_axi #(
      .N_MAX(N_MAX),
      .N_BITS(N_BITS),
      .RUNW(16),
      .ENABLE_HIST(1),
      .HIST_W(HIST_W),
      .HIST_K(HIST_K)
    ) u_rqa_axi (
      .clk            (clk),
      .rst_n          (rst_n),
      .frame_start    (rqa_start_pulse),   
      .cells_target   (cells_target_reg),  
      .n_actual       (N_frame),
      .s_axis_tdata   (cells_tdata),
      .s_axis_tvalid  (cells_tvalid),
      .s_axis_tready  (cells_tready),

      // ==== RQA AXI-Lite  ====
      .s_axi_awaddr   (s_axi_rqa_awaddr),
      .s_axi_awvalid  (s_axi_rqa_awvalid),
      .s_axi_awready  (s_axi_rqa_awready),
      .s_axi_wdata    (s_axi_rqa_wdata),
      .s_axi_wstrb    (s_axi_rqa_wstrb),
      .s_axi_wvalid   (s_axi_rqa_wvalid),
      .s_axi_wready   (s_axi_rqa_wready),
      .s_axi_bresp    (s_axi_rqa_bresp),
      .s_axi_bvalid   (s_axi_rqa_bvalid),
      .s_axi_bready   (s_axi_rqa_bready),
      .s_axi_araddr   (s_axi_rqa_araddr),
      .s_axi_arvalid  (s_axi_rqa_arvalid),
      .s_axi_arready  (s_axi_rqa_arready),
      .s_axi_rdata    (s_axi_rqa_rdata),
      .s_axi_rresp    (s_axi_rqa_rresp),
      .s_axi_rvalid   (s_axi_rqa_rvalid),
      .s_axi_rready   (s_axi_rqa_rready),
      .l_min          (l_min),
      .v_min          (v_min),
      .metrics_valid_pulse(metrics_valid_pulse)
    );

    // ---------------- Perf monitor ----------------

    axi_perf_mon u_perf (
        .clk(clk), .rst_n(rst_n),
        .load_end_pulse (rqa_start_pulse),
        .pairs_end_pulse(pairs_done_pulse),
        .cells_end_pulse(cells_done_pulse),
        .scan_end_pulse (metrics_valid_pulse),
        .dtc_start_pulse(dtc_start_pulse),
        .dtc_end_pulse(dtc_end_pulse),
        .start_pulse_out(), // not used (PS writes start)
        .s_axi_awaddr(pm_awaddr), .s_axi_awvalid(pm_awvalid), .s_axi_awready(pm_awready),
        .s_axi_wdata(pm_wdata), .s_axi_wstrb(pm_wstrb), .s_axi_wvalid(pm_wvalid), .s_axi_wready(pm_wready),
        .s_axi_bresp(pm_bresp), .s_axi_bvalid(pm_bvalid), .s_axi_bready(pm_bready),
        .s_axi_araddr(pm_araddr), .s_axi_arvalid(pm_arvalid), .s_axi_arready(pm_arready),
        .s_axi_rdata(pm_rdata), .s_axi_rresp(pm_rresp), .s_axi_rvalid(pm_rvalid), .s_axi_rready(pm_rready)
    );

endmodule
