`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// jrp_vector_buffer3.v
//   jrp_vector_buffer with a third read port (C): the K = 2 scan reads the row vector (port A)
//   and two adjacent column vectors (ports B and C) in every cycle. Three mirrored copies.
//   Everything below is jrp_vector_buffer.
//   Derived from the released vector_buffer.v (Li, Lai and Oberst 2026, Zenodo
//   10.5281/zenodo.20406392, MIT). Same structure: frame-based write from the embedding block,
//   two mirrored UltraRAM copies (xpm_memory_tdpram, READ_LATENCY 2) giving two read ports.
//
//   One change, found in Phase 3 simulation: read data and read valid are aligned.
//   Released module: a read request in cycle T returns data in cycle T+3 but asserts
//   vec_*_valid in cycle T+4. It works there only because compare_orchestrator issues one read
//   and waits, while the address register keeps the data stable. With a request in every cycle
//   (the pipelined scan engine) each valid would pair with the next request's data.
//   Here a request in cycle T gives data AND valid in cycle T+3 (RD_LAT = 3).
//
//   The released fallback (inferred block RAM, USE_XPM undefined) is not carried over.
// -----------------------------------------------------------------------------
module jrp_vector_buffer3 #(
    parameter integer DATA_WIDTH = 32,
    parameter integer MAX_M      = 6,
    parameter integer N_MAX      = 8192
)(
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         frame_start,   // clears the write pointer and the count

    // Write side (always ready), one vector per beat
    input  wire [DATA_WIDTH*MAX_M-1:0]  s_vec_tdata,
    input  wire                         s_vec_tvalid,
    output wire                         s_vec_tready,
    output reg  [31:0]                  n_loaded,

    // Read port A (index i) and port B (index j): request in cycle T, data and valid in T+3
    input  wire                         rd_en_a,
    input  wire [31:0]                  rd_idx_a,
    output reg  [DATA_WIDTH*MAX_M-1:0]  vec_a,
    output reg                          vec_a_valid,
    input  wire                         rd_en_b,
    input  wire [31:0]                  rd_idx_b,
    output reg  [DATA_WIDTH*MAX_M-1:0]  vec_b,
    output reg                          vec_b_valid,
    input  wire                         rd_en_c,
    input  wire [31:0]                  rd_idx_c,
    output reg  [DATA_WIDTH*MAX_M-1:0]  vec_c,
    output reg                          vec_c_valid
);
    localparam integer VECW     = DATA_WIDTH*MAX_M;
    localparam integer AW       = (N_MAX<=1) ? 1 : $clog2(N_MAX);
    localparam integer READ_LAT = 2;          // XPM read latency (UltraRAM needs >= 2)

    assign s_vec_tready = 1'b1;

    reg [AW-1:0] wptr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= {AW{1'b0}}; n_loaded <= 32'd0;
        end else begin
            if (frame_start) begin
                wptr <= {AW{1'b0}}; n_loaded <= 32'd0;
            end
            if (s_vec_tvalid && s_vec_tready) begin
                wptr     <= (wptr == N_MAX-1) ? {AW{1'b0}} : wptr + 1'b1;
                n_loaded <= n_loaded + 1;
            end
        end
    end

    wire            wea   = s_vec_tvalid && s_vec_tready;
    wire [AW-1:0]   addra = wptr;
    wire [VECW-1:0] dina  = s_vec_tdata;

    reg  [AW-1:0]   addrb_a_r, addrb_b_r, addrb_c_r;
    wire [AW-1:0]   addrb_a = rd_en_a ? rd_idx_a[AW-1:0] : addrb_a_r;
    wire [AW-1:0]   addrb_b = rd_en_b ? rd_idx_b[AW-1:0] : addrb_b_r;
    wire [AW-1:0]   addrb_c = rd_en_c ? rd_idx_c[AW-1:0] : addrb_c_r;
    wire [VECW-1:0] doutb_a, doutb_b, doutb_c;

    xpm_memory_tdpram #(
      .MEMORY_SIZE(N_MAX*VECW), .MEMORY_PRIMITIVE("ultra"), .CLOCKING_MODE("common_clock"),
      .WRITE_DATA_WIDTH_A(VECW), .READ_DATA_WIDTH_A(VECW), .ADDR_WIDTH_A(AW),
      .READ_LATENCY_A(READ_LAT), .WRITE_MODE_A("no_change"),
      .WRITE_DATA_WIDTH_B(VECW), .READ_DATA_WIDTH_B(VECW), .ADDR_WIDTH_B(AW),
      .READ_LATENCY_B(READ_LAT), .WRITE_MODE_B("no_change"),
      .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0")
    ) u_mem0 (
      .clka(clk), .ena(1'b1), .wea({(VECW/8){wea}}), .addra(addra), .dina(dina), .douta(),
      .clkb(clk), .enb(1'b1), .web({(VECW/8){1'b0}}), .addrb(addrb_a), .dinb({VECW{1'b0}}), .doutb(doutb_a),
      .sleep(1'b0), .rsta(1'b0), .rstb(1'b0), .regcea(1'b1), .regceb(1'b1),
      .injectsbiterra(1'b0), .injectdbiterra(1'b0), .sbiterrb(), .dbiterrb());

    xpm_memory_tdpram #(
      .MEMORY_SIZE(N_MAX*VECW), .MEMORY_PRIMITIVE("ultra"), .CLOCKING_MODE("common_clock"),
      .WRITE_DATA_WIDTH_A(VECW), .READ_DATA_WIDTH_A(VECW), .ADDR_WIDTH_A(AW),
      .READ_LATENCY_A(READ_LAT), .WRITE_MODE_A("no_change"),
      .WRITE_DATA_WIDTH_B(VECW), .READ_DATA_WIDTH_B(VECW), .ADDR_WIDTH_B(AW),
      .READ_LATENCY_B(READ_LAT), .WRITE_MODE_B("no_change"),
      .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0")
    ) u_mem1 (
      .clka(clk), .ena(1'b1), .wea({(VECW/8){wea}}), .addra(addra), .dina(dina), .douta(),
      .clkb(clk), .enb(1'b1), .web({(VECW/8){1'b0}}), .addrb(addrb_b), .dinb({VECW{1'b0}}), .doutb(doutb_b),
      .sleep(1'b0), .rsta(1'b0), .rstb(1'b0), .regcea(1'b1), .regceb(1'b1),
      .injectsbiterra(1'b0), .injectdbiterra(1'b0), .sbiterrb(), .dbiterrb());

    xpm_memory_tdpram #(
      .MEMORY_SIZE(N_MAX*VECW), .MEMORY_PRIMITIVE("ultra"), .CLOCKING_MODE("common_clock"),
      .WRITE_DATA_WIDTH_A(VECW), .READ_DATA_WIDTH_A(VECW), .ADDR_WIDTH_A(AW),
      .READ_LATENCY_A(READ_LAT), .WRITE_MODE_A("no_change"),
      .WRITE_DATA_WIDTH_B(VECW), .READ_DATA_WIDTH_B(VECW), .ADDR_WIDTH_B(AW),
      .READ_LATENCY_B(READ_LAT), .WRITE_MODE_B("no_change"),
      .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0")
    ) u_mem2 (
      .clka(clk), .ena(1'b1), .wea({(VECW/8){wea}}), .addra(addra), .dina(dina), .douta(),
      .clkb(clk), .enb(1'b1), .web({(VECW/8){1'b0}}), .addrb(addrb_c), .dinb({VECW{1'b0}}), .doutb(doutb_c),
      .sleep(1'b0), .rsta(1'b0), .rstb(1'b0), .regcea(1'b1), .regceb(1'b1),
      .injectsbiterra(1'b0), .injectdbiterra(1'b0), .sbiterrb(), .dbiterrb());

    // Valid pipe has READ_LAT bits: request in cycle T, valid in cycle T+READ_LAT+1, the same
    // cycle in which the registered data (vec_*) is correct.
    reg [READ_LAT-1:0] rd_a_pipe, rd_b_pipe, rd_c_pipe;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addrb_a_r <= {AW{1'b0}}; addrb_b_r <= {AW{1'b0}}; addrb_c_r <= {AW{1'b0}};
            rd_a_pipe <= {READ_LAT{1'b0}}; rd_b_pipe <= {READ_LAT{1'b0}}; rd_c_pipe <= {READ_LAT{1'b0}};
            vec_a <= {VECW{1'b0}}; vec_b <= {VECW{1'b0}}; vec_c <= {VECW{1'b0}};
            vec_a_valid <= 1'b0; vec_b_valid <= 1'b0; vec_c_valid <= 1'b0;
        end else begin
            if (rd_en_a) addrb_a_r <= rd_idx_a[AW-1:0];
            if (rd_en_b) addrb_b_r <= rd_idx_b[AW-1:0];
            if (rd_en_c) addrb_c_r <= rd_idx_c[AW-1:0];
            rd_a_pipe   <= {rd_a_pipe[READ_LAT-2:0], rd_en_a};
            rd_b_pipe   <= {rd_b_pipe[READ_LAT-2:0], rd_en_b};
            rd_c_pipe   <= {rd_c_pipe[READ_LAT-2:0], rd_en_c};
            vec_a       <= doutb_a;
            vec_b       <= doutb_b;
            vec_c       <= doutb_c;
            vec_a_valid <= rd_a_pipe[READ_LAT-1];
            vec_b_valid <= rd_b_pipe[READ_LAT-1];
            vec_c_valid <= rd_c_pipe[READ_LAT-1];
        end
    end
endmodule
