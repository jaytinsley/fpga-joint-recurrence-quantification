// -----------------------------------------------------------------------------
// vector_buffer.v
//   - Frame-based write from PSR (AXIS-like): always-ready sink
//   - Two random-read ports (A/B), 1 request -> registered data + valid pulse
//   - Mirrors each write into two memories for true 2R access
//   - USE_XPM:   XPM true dual-port memory targeting UltraRAM (default)
//   - fallback:  inferred block RAM arrays (1-cycle read)
//   - Read valid alignment handled internally (URAM READ_LAT=2; BRAM=1)
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`define USE_XPM
module vector_buffer #(
    parameter integer DATA_WIDTH = 32,
    parameter integer MAX_M      = 10,
    parameter integer N_MAX      = 8192
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Frame control
    input  wire                         frame_start,
    input  wire                         frame_end,     // (unused here, reserved)

    // AXIS-like write side from PSR
    input  wire [DATA_WIDTH*MAX_M-1:0]  s_vec_tdata,
    input  wire                         s_vec_tvalid,
    output wire                         s_vec_tready,

    // Expose count
    output reg  [31:0]                  n_loaded,

    // Random read port A (for index i)
    input  wire                         rd_en_a,
    input  wire [31:0]                  rd_idx_a,
    output reg  [DATA_WIDTH*MAX_M-1:0]  vec_a,
    output reg                          vec_a_valid,

    // Random read port B (for index j)
    input  wire                         rd_en_b,
    input  wire [31:0]                  rd_idx_b,
    output reg  [DATA_WIDTH*MAX_M-1:0]  vec_b,
    output reg                          vec_b_valid
);
    localparam integer VECW = DATA_WIDTH*MAX_M;
    localparam integer AW   = (N_MAX<=1) ? 1 : $clog2(N_MAX);

    // Always-ready sink (no backpressure inside this buffer)
    assign s_vec_tready = 1'b1;

    // -----------------------------
    // Write pointer & load counter
    // -----------------------------
    reg [AW-1:0] wptr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr     <= {AW{1'b0}};
            n_loaded <= 32'd0;
        end else begin
            if (frame_start) begin
                wptr     <= {AW{1'b0}};
                n_loaded <= 32'd0;
            end
            if (s_vec_tvalid && s_vec_tready) begin
                // Wrap at N_MAX (supports non-power-of-2 depths)
                if (wptr == N_MAX-1)
                    wptr <= {AW{1'b0}};
                else
                    wptr <= wptr + 1'b1;
                n_loaded <= n_loaded + 1;
            end
        end
    end

    // =========================================
    // Two mirrored memories: mem0 (for read A),
    //                        mem1 (for read B)
    // Each is written identically on writes.
    // =========================================

`ifdef USE_XPM
    // ---------- Preferred: XPM (UltraRAM), 2R via two mirrored TDP memories ----------
    // URAM requirements:
    //   - Use xpm_memory_tdpram
    //   - WRITE_MODE_A/B = "no_change"
    //   - READ_LATENCY_A/B >= 2 (we use 2)
    //   - Byte-write not supported; drive full-width wea
    //localparam string  MEM_PRIM  = "ultra";  // change to "block" if you want BRAM via XPM
    localparam integer READ_LAT  = 2;

    wire                 wea   = (s_vec_tvalid && s_vec_tready);
    wire [AW-1:0]        addra = wptr;
    wire [VECW-1:0]      dina  = s_vec_tdata;

    // ---- mem0: write on port A, read on port B (serves read port A) ----
    // addrb_a_r: registered hold of last requested address.
    // addrb_a:   combinational mux - presents the NEW address to XPM in the
    //            same cycle rd_en_a fires, so XPM samples the correct address
    //            at that clock edge (not 1 cycle late via non-blocking assign).
    reg  [AW-1:0]        addrb_a_r;
    wire [AW-1:0]        addrb_a = rd_en_a ? rd_idx_a[AW-1:0] : addrb_a_r;
    wire [VECW-1:0]      doutb_a;

    xpm_memory_tdpram #(
      .MEMORY_SIZE        (N_MAX*VECW),        // in bits
      .MEMORY_PRIMITIVE   ("ultra"),          // "ultra" or "block"
      .CLOCKING_MODE      ("common_clock"),
      // Port A (write)
      .WRITE_DATA_WIDTH_A (VECW),
      .READ_DATA_WIDTH_A  (VECW),
      .ADDR_WIDTH_A       (AW),
      .READ_LATENCY_A     (READ_LAT),
      .WRITE_MODE_A       ("no_change"),
      // Port B (read)
      .WRITE_DATA_WIDTH_B (VECW),
      .READ_DATA_WIDTH_B  (VECW),
      .ADDR_WIDTH_B       (AW),
      .READ_LATENCY_B     (READ_LAT),
      .WRITE_MODE_B       ("no_change"),
      // Init
      .MEMORY_INIT_FILE   ("none"),
      .MEMORY_INIT_PARAM  ("0")
    ) u_mem0 (
      // Port A = write
      .clka   (clk),
      .ena    (1'b1),
      .wea    ({(VECW/8){wea}}),
      .addra  (addra),
      .dina   (dina),
      .douta  (/*unused*/),
      // Port B = read
      .clkb   (clk),
      .enb    (1'b1),
      .web    ({(VECW/8){1'b0}}),
      .addrb  (addrb_a),
      .dinb   ({VECW{1'b0}}),
      .doutb  (doutb_a),
      // misc
      .sleep  (1'b0),
      .rsta   (1'b0),
      .rstb   (1'b0),
      .regcea (1'b1),
      .regceb (1'b1),
      .injectsbiterra(1'b0),
      .injectdbiterra(1'b0),
      .sbiterrb(),
      .dbiterrb()
    );

    // ---- mem1: write on port A, read on port B (serves read port B) ----
    reg  [AW-1:0]        addrb_b_r;
    wire [AW-1:0]        addrb_b = rd_en_b ? rd_idx_b[AW-1:0] : addrb_b_r;
    wire [VECW-1:0]      doutb_b;

    xpm_memory_tdpram #(
      .MEMORY_SIZE        (N_MAX*VECW),
      .MEMORY_PRIMITIVE   ("ultra"),
      .CLOCKING_MODE      ("common_clock"),
      // Port A (write)
      .WRITE_DATA_WIDTH_A (VECW),
      .READ_DATA_WIDTH_A  (VECW),
      .ADDR_WIDTH_A       (AW),
      .READ_LATENCY_A     (READ_LAT),
      .WRITE_MODE_A       ("no_change"),
      // Port B (read)
      .WRITE_DATA_WIDTH_B (VECW),
      .READ_DATA_WIDTH_B  (VECW),
      .ADDR_WIDTH_B       (AW),
      .READ_LATENCY_B     (READ_LAT),
      .WRITE_MODE_B       ("no_change"),
      .MEMORY_INIT_FILE   ("none"),
      .MEMORY_INIT_PARAM  ("0")
    ) u_mem1 (
      .clka   (clk),
      .ena    (1'b1),
      .wea    ({(VECW/8){wea}}),
      .addra  (addra),
      .dina   (dina),
      .douta  (/*unused*/),
      .clkb   (clk),
      .enb    (1'b1),
      .web    ({(VECW/8){1'b0}}),
      .addrb  (addrb_b),
      .dinb   ({VECW{1'b0}}),
      .doutb  (doutb_b),
      .sleep  (1'b0),
      .rsta   (1'b0),
      .rstb   (1'b0),
      .regcea (1'b1),
      .regceb (1'b1),
      .injectsbiterra(1'b0),
      .injectdbiterra(1'b0),
      .sbiterrb(),
      .dbiterrb()
    );

    // -------- Read address + valid alignment --------
    // Pipeline depth = READ_LAT + 1 bits:
    //   XPM sees address at posedge T (combinational addrb).
    //   XPM doutb updates at posedge T+READ_LAT (output register fires).
    //   `vec_a <= doutb_a` (non-blocking) captures the value BEFORE that
    //   posedge, so vec_a is correct only from posedge T+READ_LAT+1 onward.
    //   Therefore vec_a_valid must also assert at T+READ_LAT+1, requiring
    //   a shift register one bit longer than READ_LAT.
    reg [READ_LAT:0] rd_a_pipe, rd_b_pipe;  // READ_LAT+1 bits
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addrb_a_r   <= {AW{1'b0}};
            addrb_b_r   <= {AW{1'b0}};
            rd_a_pipe   <= {(READ_LAT+1){1'b0}};
            rd_b_pipe   <= {(READ_LAT+1){1'b0}};
            vec_a       <= {VECW{1'b0}};
            vec_b       <= {VECW{1'b0}};
            vec_a_valid <= 1'b0;
            vec_b_valid <= 1'b0;
        end else begin
            if (rd_en_a) addrb_a_r <= rd_idx_a[AW-1:0];
            if (rd_en_b) addrb_b_r <= rd_idx_b[AW-1:0];

            rd_a_pipe <= {rd_a_pipe[READ_LAT-1:0], rd_en_a};
            rd_b_pipe <= {rd_b_pipe[READ_LAT-1:0], rd_en_b};

            vec_a       <= doutb_a;
            vec_b       <= doutb_b;
            vec_a_valid <= rd_a_pipe[READ_LAT];   // one cycle later than before
            vec_b_valid <= rd_b_pipe[READ_LAT];
        end
    end

`else
    // ---------- Fallback: inferred BRAM with two separate arrays ----------
    // Single-cycle synchronous read
    (* ram_style="block" *) reg [VECW-1:0] mem0 [0:N_MAX-1];
    (* ram_style="block" *) reg [VECW-1:0] mem1 [0:N_MAX-1];

    // Mirror writes
    always @(posedge clk) begin
        if (s_vec_tvalid && s_vec_tready) begin
            mem0[wptr] <= s_vec_tdata;
            mem1[wptr] <= s_vec_tdata;
        end
    end

    // sync read A (1-cycle)
    reg [AW-1:0] ra;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ra          <= {AW{1'b0}};
            vec_a_valid <= 1'b0;
            vec_a       <= {VECW{1'b0}};
        end else begin
            vec_a_valid <= rd_en_a;
            if (rd_en_a) ra <= rd_idx_a[AW-1:0];
            vec_a <= mem0[ra];
        end
    end

    // sync read B (1-cycle)
    reg [AW-1:0] rb;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rb          <= {AW{1'b0}};
            vec_b_valid <= 1'b0;
            vec_b       <= {VECW{1'b0}};
        end else begin
            vec_b_valid <= rd_en_b;
            if (rd_en_b) rb <= rd_idx_b[AW-1:0];
            vec_b <= mem1[rb];
        end
    end
`endif

endmodule
