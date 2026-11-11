`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// jrp_axi_regs.v
//   AXI4-Lite control block for the dual-channel JRP. Derived from the released axi_lite_regs.v
//   (Li, Lai and Oberst 2026, Zenodo 10.5281/zenodo.20406392, MIT): same write and read channel
//   structure and the same first nine registers; adds the y-channel registers, alignment bases
//   and read-back of every configuration register (decision D2/D3, docs/phase2_architecture.md 6.2).
//
//   0x000 CONTROL  W1P  [0] start  [1] soft reset
//   0x004 STATUS   R    [0] psr_in_ready [1] ing_busy [2] scan_busy [3] metrics_valid
//                       [4] lost_err (a flag was lost) [5] align_err (pipeline misaligned)
//                       [6] cfg_err (base + n exceeds a channel's vector count)
//   0x008 N_RAW    RW   samples per channel
//   0x00C M_X      RW   0x010 TAU_X   RW   0x014 EPS2_X  RW (eps_x^2, unsigned Q8.24)
//   0x018 LMIN     RW   0x01C VMIN    RW
//   0x020 N_ACTUAL R    joint vectors in the current frame (as written to N_JOINT)
//   0x024 M_Y      RW   0x028 TAU_Y   RW   0x02C EPS2_Y  RW
//   0x030 CFG      RW   [1] align_start (informational; the driver computes BASE_*)
//                       [2] pass0_max_distance (reserved, not implemented yet, D4 option A)
//   0x034 BASE_X   RW   memory index of joint vector 0, channel x
//   0x038 BASE_Y   RW
//   0x03C N_JOINT  RW   joint vectors per channel after alignment
//   0x040 MAXD2_X  R    reserved for pass 0 (reads 0)      0x044 MAXD2_Y  R  (reads 0)
//   0x048 ID       R    0x4A525031 ("JRP1")
//   0x04C NX_VEC   R    vectors produced by embedding block x    0x050 NY_VEC  R
// -----------------------------------------------------------------------------
module jrp_axi_regs #(
    parameter integer ADDR_W = 12
)(
    input  wire                  clk,
    input  wire                  rst_n,

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

    output reg                   start_pulse,
    output reg                   soft_reset_pulse,
    output reg  [31:0]           n_raw,
    output reg  [7:0]            m_x,
    output reg  [7:0]            tau_x,
    output reg  [31:0]           eps2_x,
    output reg  [7:0]            m_y,
    output reg  [7:0]            tau_y,
    output reg  [31:0]           eps2_y,
    output reg  [31:0]           l_min,
    output reg  [31:0]           v_min,
    output reg  [31:0]           cfg,
    output reg  [31:0]           base_x,
    output reg  [31:0]           base_y,
    output reg  [31:0]           n_joint,

    input  wire                  psr_in_ready,
    input  wire                  ing_busy,
    input  wire                  scan_busy,
    input  wire                  metrics_valid,
    input  wire                  lost_err,
    input  wire                  align_err,
    input  wire                  cfg_err,
    input  wire [31:0]           nx_vec,
    input  wire [31:0]           ny_vec
);
    localparam [11:0] REG_CONTROL = 12'h000, REG_STATUS = 12'h004, REG_NRAW = 12'h008, REG_MX = 12'h00C,
                      REG_TAUX = 12'h010, REG_EPS2X = 12'h014, REG_LMIN = 12'h018, REG_VMIN = 12'h01C,
                      REG_NACT = 12'h020, REG_MY = 12'h024, REG_TAUY = 12'h028, REG_EPS2Y = 12'h02C,
                      REG_CFG = 12'h030, REG_BASEX = 12'h034, REG_BASEY = 12'h038, REG_NJOINT = 12'h03C,
                      REG_MAXD2X = 12'h040, REG_MAXD2Y = 12'h044, REG_ID = 12'h048,
                      REG_NXVEC = 12'h04C, REG_NYVEC = 12'h050;

    wire wr_fire = s_axi_awvalid && s_axi_wvalid && s_axi_awready && s_axi_wready;
    wire rd_fire = s_axi_arvalid && s_axi_arready;
    reg [ADDR_W-1:0] awaddr_q, araddr_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_bvalid <= 1'b0; s_axi_bresp <= 2'b00;
            awaddr_q <= {ADDR_W{1'b0}};
        end else begin
            s_axi_awready <= (~s_axi_awready) & s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid;
            s_axi_wready  <= (~s_axi_wready)  & s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid;
            if (~s_axi_awready && s_axi_awvalid) awaddr_q <= s_axi_awaddr;
            if (wr_fire) begin
                s_axi_bvalid <= 1'b1; s_axi_bresp <= 2'b00;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b0; s_axi_rvalid <= 1'b0; s_axi_rresp <= 2'b00; s_axi_rdata <= 32'd0;
            araddr_q <= {ADDR_W{1'b0}};
        end else begin
            if (~s_axi_arready && s_axi_arvalid && ~s_axi_rvalid) begin
                s_axi_arready <= 1'b1; araddr_q <= s_axi_araddr;
            end else begin
                s_axi_arready <= 1'b0;
            end
            if (rd_fire) begin
                s_axi_rvalid <= 1'b1; s_axi_rresp <= 2'b00;
                case (araddr_q)
                    REG_STATUS: s_axi_rdata <= {25'd0, cfg_err, align_err, lost_err, metrics_valid, scan_busy, ing_busy, psr_in_ready};
                    REG_NRAW:   s_axi_rdata <= n_raw;
                    REG_MX:     s_axi_rdata <= {24'd0, m_x};
                    REG_TAUX:   s_axi_rdata <= {24'd0, tau_x};
                    REG_EPS2X:  s_axi_rdata <= eps2_x;
                    REG_LMIN:   s_axi_rdata <= l_min;
                    REG_VMIN:   s_axi_rdata <= v_min;
                    REG_NACT:   s_axi_rdata <= n_joint;
                    REG_MY:     s_axi_rdata <= {24'd0, m_y};
                    REG_TAUY:   s_axi_rdata <= {24'd0, tau_y};
                    REG_EPS2Y:  s_axi_rdata <= eps2_y;
                    REG_CFG:    s_axi_rdata <= cfg;
                    REG_BASEX:  s_axi_rdata <= base_x;
                    REG_BASEY:  s_axi_rdata <= base_y;
                    REG_NJOINT: s_axi_rdata <= n_joint;
                    REG_ID:     s_axi_rdata <= 32'h4A52_5031;
                    REG_NXVEC:  s_axi_rdata <= nx_vec;
                    REG_NYVEC:  s_axi_rdata <= ny_vec;
                    default:    s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_pulse <= 1'b0; soft_reset_pulse <= 1'b0;
            n_raw <= 32'd0; m_x <= 8'd1; tau_x <= 8'd1; eps2_x <= 32'd0;
            m_y <= 8'd1; tau_y <= 8'd1; eps2_y <= 32'd0;
            l_min <= 32'd2; v_min <= 32'd2; cfg <= 32'd0;
            base_x <= 32'd0; base_y <= 32'd0; n_joint <= 32'd0;
        end else begin
            start_pulse <= 1'b0; soft_reset_pulse <= 1'b0;
            if (wr_fire) begin
                case (awaddr_q)
                    REG_CONTROL: begin
                        if (s_axi_wdata[0]) start_pulse <= 1'b1;
                        if (s_axi_wdata[1]) soft_reset_pulse <= 1'b1;
                    end
                    REG_NRAW:   n_raw   <= s_axi_wdata;
                    REG_MX:     m_x     <= s_axi_wdata[7:0];
                    REG_TAUX:   tau_x   <= s_axi_wdata[7:0];
                    REG_EPS2X:  eps2_x  <= s_axi_wdata;
                    REG_LMIN:   l_min   <= s_axi_wdata;
                    REG_VMIN:   v_min   <= s_axi_wdata;
                    REG_MY:     m_y     <= s_axi_wdata[7:0];
                    REG_TAUY:   tau_y   <= s_axi_wdata[7:0];
                    REG_EPS2Y:  eps2_y  <= s_axi_wdata;
                    REG_CFG:    cfg     <= s_axi_wdata;
                    REG_BASEX:  base_x  <= s_axi_wdata;
                    REG_BASEY:  base_y  <= s_axi_wdata;
                    REG_NJOINT: n_joint <= s_axi_wdata;
                    default: ;
                endcase
            end
        end
    end
endmodule
