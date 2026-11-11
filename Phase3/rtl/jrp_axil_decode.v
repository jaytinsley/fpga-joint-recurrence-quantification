`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// jrp_axil_decode.v
//   AXI4-Lite 1-to-5 decoder, one transaction at a time (no outstanding transactions), for the
//   bring-up design. Address bits [19:17] select the target; the target sees the low bits:
//     0 control block  (12-bit)   1 RQA counters + histograms (17-bit)   2 performance monitor (6-bit)
//     3 sample feeder  (6-bit)    4 clock counter (read only, see jrp_board_core)
//   Writes have priority over reads. Responses of the selected target are passed back.
// -----------------------------------------------------------------------------
module jrp_axil_decode (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [19:0] s_awaddr, input  wire s_awvalid, output reg  s_awready,
    input  wire [31:0] s_wdata,  input  wire [3:0] s_wstrb, input wire s_wvalid, output reg s_wready,
    output reg  [1:0]  s_bresp,  output reg  s_bvalid, input wire s_bready,
    input  wire [19:0] s_araddr, input  wire s_arvalid, output reg s_arready,
    output reg  [31:0] s_rdata,  output reg  [1:0] s_rresp, output reg s_rvalid, input wire s_rready,

    // shared downstream channel signals (fanned out to all targets) and per-target selects
    output reg  [16:0] m_awaddr, output reg [31:0] m_wdata, output reg [3:0] m_wstrb,
    output reg  [16:0] m_araddr,
    output reg  [4:0]  m_awvalid, output reg [4:0] m_wvalid, output reg [4:0] m_arvalid,
    output reg  [4:0]  m_bready,  output reg [4:0] m_rready,
    input  wire [4:0]  m_awready, input  wire [4:0] m_wready,
    input  wire [4:0]  m_bvalid,  input  wire [4:0] m_arready, input wire [4:0] m_rvalid,
    input  wire [9:0]  m_bresp_flat,      // 2 bits per target
    input  wire [159:0] m_rdata_flat,     // 32 bits per target
    input  wire [9:0]  m_rresp_flat
);
    localparam [3:0] IDLE = 0, WR_ISSUE = 1, WR_RESP = 2, WR_DONE = 3, RD_ISSUE = 4, RD_RESP = 5, RD_DONE = 6;
    reg [3:0]  st;
    reg [2:0]  sel;
    reg        aw_done, w_done;

    wire [2:0] sel_w = s_awaddr[19:17];
    wire [2:0] sel_r = s_araddr[19:17];

    wire [31:0] rdata_sel = m_rdata_flat[sel*32 +: 32];
    wire [1:0]  rresp_sel = m_rresp_flat[sel*2 +: 2];
    wire [1:0]  bresp_sel = m_bresp_flat[sel*2 +: 2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= IDLE; sel <= 3'd0; aw_done <= 1'b0; w_done <= 1'b0;
            s_awready <= 1'b0; s_wready <= 1'b0; s_bresp <= 2'b00; s_bvalid <= 1'b0;
            s_arready <= 1'b0; s_rdata <= 32'd0; s_rresp <= 2'b00; s_rvalid <= 1'b0;
            m_awaddr <= 17'd0; m_wdata <= 32'd0; m_wstrb <= 4'd0; m_araddr <= 17'd0;
            m_awvalid <= 5'd0; m_wvalid <= 5'd0; m_arvalid <= 5'd0; m_bready <= 5'd0; m_rready <= 5'd0;
        end else begin
            s_awready <= 1'b0; s_wready <= 1'b0; s_arready <= 1'b0;
            case (st)
                IDLE: begin
                    if (s_awvalid && s_wvalid) begin
                        sel <= sel_w; m_awaddr <= s_awaddr[16:0]; m_wdata <= s_wdata; m_wstrb <= s_wstrb;
                        s_awready <= 1'b1; s_wready <= 1'b1;
                        aw_done <= 1'b0; w_done <= 1'b0;
                        m_awvalid <= (5'd1 << sel_w); m_wvalid <= (5'd1 << sel_w);
                        st <= WR_ISSUE;
                    end else if (s_arvalid) begin
                        sel <= sel_r; m_araddr <= s_araddr[16:0];
                        s_arready <= 1'b1;
                        m_arvalid <= (5'd1 << sel_r);
                        st <= RD_ISSUE;
                    end
                end
                WR_ISSUE: begin
                    if (m_awready[sel] && m_awvalid[sel]) begin m_awvalid <= 5'd0; aw_done <= 1'b1; end
                    if (m_wready[sel]  && m_wvalid[sel])  begin m_wvalid  <= 5'd0; w_done  <= 1'b1; end
                    if ((aw_done || (m_awready[sel] && m_awvalid[sel])) &&
                        (w_done  || (m_wready[sel]  && m_wvalid[sel]))) begin
                        m_bready <= (5'd1 << sel);
                        st <= WR_RESP;
                    end
                end
                WR_RESP: begin
                    if (m_bvalid[sel]) begin
                        m_bready <= 5'd0; s_bresp <= bresp_sel; s_bvalid <= 1'b1; st <= WR_DONE;
                    end
                end
                WR_DONE: begin
                    if (s_bvalid && s_bready) begin s_bvalid <= 1'b0; st <= IDLE; end
                end
                RD_ISSUE: begin
                    if (m_arready[sel] && m_arvalid[sel]) begin
                        m_arvalid <= 5'd0; m_rready <= (5'd1 << sel); st <= RD_RESP;
                    end
                end
                RD_RESP: begin
                    if (m_rvalid[sel]) begin
                        m_rready <= 5'd0; s_rdata <= rdata_sel; s_rresp <= rresp_sel; s_rvalid <= 1'b1;
                        st <= RD_DONE;
                    end
                end
                RD_DONE: begin
                    if (s_rvalid && s_rready) begin s_rvalid <= 1'b0; st <= IDLE; end
                end
                default: st <= IDLE;
            endcase
        end
    end
endmodule
