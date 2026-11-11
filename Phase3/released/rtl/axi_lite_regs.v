// axi_lite_regs.v
// Minimal AXI4-Lite register block for control/status.
// W1P (write-one pulse) for START, RESET, FRAME_END.

// axi_lite_regs.v  -- fixed write timing (sample on write_accept)

`timescale 1ns / 1ps
module axi_lite_regs #(
    parameter integer ADDR_W = 12
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // AXI-Lite
    input  wire [ADDR_W-1:0]     s_axi_awaddr,
    input  wire                  s_axi_awvalid,
    output reg                   s_axi_awready,
    input  wire [31:0]           s_axi_wdata,
    input  wire [3:0]            s_axi_wstrb,
    input  wire                  s_axi_wvalid,
    output reg                   s_axi_wready,
    output reg  [1:0]            s_axi_bresp,
    output reg                   s_axi_bvalid,
    input  wire                  s_axi_bready,

    input  wire [ADDR_W-1:0]     s_axi_araddr,
    input  wire                  s_axi_arvalid,
    output reg                   s_axi_arready,
    output reg  [31:0]           s_axi_rdata,
    output reg  [1:0]            s_axi_rresp,
    output reg                   s_axi_rvalid,
    input  wire                  s_axi_rready,

    // Control out
    output reg                   start_pulse,
    output reg                   soft_reset_pulse,
    //output reg                   frame_end_pulse,

    output reg  [31:0]           n_raw,
    output reg  [7:0]            m_dim,
    output reg  [7:0]            tau_delay,
    output reg  [31:0]           eps2_q,
    output reg  [31:0]           l_min,
    output reg  [31:0]           v_min,

    // Status in
    input  wire [31:0]           n_actual,
    input  wire                  psr_in_ready,
    input  wire                  ing_busy,
    input  wire                  scan_busy,
    input  wire                  metrics_valid
);
    // Register map
    localparam REG_CONTROL  = 12'h000; // W: [0]=start, [1]=reset, [8]=frame_end (all W1P)
    localparam REG_STATUS   = 12'h004; // R: [0]=psr_in_ready [1]=ing_busy [2]=scan_busy [3]=metrics_valid
    localparam REG_NRAW     = 12'h008; // W
    localparam REG_MDIM     = 12'h00C; // W
    localparam REG_TAU      = 12'h010; // W
    localparam REG_EPS2     = 12'h014; // W
    localparam REG_LMIN     = 12'h018; // W
    localparam REG_VMIN     = 12'h01C; // W
    localparam REG_NACT     = 12'h020; // R

    wire wr_fire = s_axi_awvalid && s_axi_wvalid && s_axi_awready && s_axi_wready;
    wire rd_fire = s_axi_arvalid && s_axi_arready;
    reg [ADDR_W-1:0] awaddr_q; // latch write address
    // Write channel
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_bvalid <= 1'b0; s_axi_bresp <= 2'b00;
            awaddr_q <= {ADDR_W{1'b0}};
        end else begin
            s_axi_awready <= (~s_axi_awready) & s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid;
            s_axi_wready  <= (~s_axi_wready)  & s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid;
            // latch AW addr when AW handshake occurs (use stable latched address for write processing)
            if (~s_axi_awready && s_axi_awvalid) awaddr_q <= s_axi_awaddr;
            if (wr_fire) begin
                s_axi_bvalid <= 1'b1; s_axi_bresp <= 2'b00;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // Read channel
    reg [ADDR_W-1:0] araddr_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b0; s_axi_rvalid <= 1'b0; s_axi_rresp <= 2'b00; s_axi_rdata <= 32'd0;
        end else begin
            if (~s_axi_arready && s_axi_arvalid && ~s_axi_rvalid) begin
                s_axi_arready <= 1'b1; araddr_q <= s_axi_araddr;
            end else begin
                s_axi_arready <= 1'b0;
            end
            if (rd_fire) begin
                s_axi_rvalid <= 1'b1; s_axi_rresp <= 2'b00;
                case (araddr_q)
                    REG_STATUS: s_axi_rdata <= {28'd0, metrics_valid, scan_busy, ing_busy, psr_in_ready};
                    REG_NACT:   s_axi_rdata <= n_actual;
                    default:    s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    // Control + config registers
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_pulse <= 1'b0; soft_reset_pulse <= 1'b0; 
            n_raw <= 32'd0; m_dim <= 8'd1; tau_delay <= 8'd1; eps2_q <= 32'd0; l_min<=32'd2; v_min<=32'd2;
        end else begin
            start_pulse <= 1'b0; soft_reset_pulse <= 1'b0; 
            if (wr_fire) begin
                case (awaddr_q)
                    REG_CONTROL: begin
                        if (s_axi_wdata[0]) start_pulse <= 1'b1;
                        if (s_axi_wdata[1]) soft_reset_pulse <= 1'b1;
                    end
                    REG_NRAW:  n_raw     <= s_axi_wdata;
                    REG_MDIM:  m_dim     <= s_axi_wdata[7:0];
                    REG_TAU:   tau_delay <= s_axi_wdata[7:0];
                    REG_EPS2:  eps2_q    <= s_axi_wdata;
                    REG_LMIN:  l_min     <= s_axi_wdata;
                    REG_VMIN:  v_min     <= s_axi_wdata;
                    default: ;
                endcase
            end
        end
    end
endmodule 
