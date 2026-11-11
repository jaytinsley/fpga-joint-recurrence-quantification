`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// jrp_hist_unit.v
//   One histogram RAM with the pipelined increment of jrp_rqa_extractor (Phase 3 change to the
//   released RMW FSM): accepts one event per cycle.
//     e0: event register, its bin is the RAM read address (read latency 1)
//     e1: RAM data available; take the newest value for the bin (forward the write presented
//         this cycle or last cycle), add one (saturating at HIST_W bits), present the write
//   The K = 2 extractor holds two units per histogram, one per lane; the host-visible bin is the
//   sum of the two. An external read (rd_en) must only be issued while `busy` is low.
// -----------------------------------------------------------------------------
module jrp_hist_unit #(
    parameter integer HIST_K = 8192,
    parameter integer HIST_W = 32
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     ev_v,       // event this cycle
    input  wire [$clog2(HIST_K)-1:0] ev_idx,    // its bin
    input  wire                     clr_we,     // clear write
    input  wire [$clog2(HIST_K)-1:0] clr_addr,
    input  wire                     rd_en,      // external read
    input  wire [$clog2(HIST_K)-1:0] rd_idx,
    output wire [31:0]              rd_data,    // valid the cycle after rd_en
    output wire                     busy
);
    localparam integer AW = $clog2(HIST_K);
    localparam integer MW = 32;

    reg              e0_v, e1_v, w2_v, we;
    reg  [AW-1:0]    e0_idx, e1_idx, w2_idx, waddr;
    reg  [MW-1:0]    w2_data, wdata;
    wire [MW-1:0]    rdata;

    wire [AW-1:0] raddr = rd_en ? rd_idx : e0_idx;

    xpm_memory_sdpram #(
      .MEMORY_SIZE(HIST_K*MW), .MEMORY_PRIMITIVE("block"), .CLOCKING_MODE("common_clock"),
      .WRITE_DATA_WIDTH_A(MW), .BYTE_WRITE_WIDTH_A(8), .ADDR_WIDTH_A(AW),
      .READ_DATA_WIDTH_B(MW), .ADDR_WIDTH_B(AW), .READ_LATENCY_B(1), .ECC_MODE("no_ecc")
    ) u_ram (
      .clka(clk), .ena(1'b1), .wea({(MW/8){we}}), .addra(waddr), .dina(wdata),
      .clkb(clk), .enb(1'b1), .addrb(raddr), .doutb(rdata),
      .sleep(1'b0), .regceb(1'b1),
      .injectsbiterra(1'b0), .injectdbiterra(1'b0), .sbiterrb(), .dbiterrb());

    assign rd_data = rdata;
    assign busy    = e0_v | e1_v | we | w2_v;

    wire [MW-1:0] fwd = (we   && waddr  == e1_idx) ? wdata :
                        (w2_v && w2_idx == e1_idx) ? w2_data : rdata;
    wire [MW-1:0] inc = (&fwd[HIST_W-1:0]) ? fwd : (fwd + {{(MW-1){1'b0}}, 1'b1});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            e0_v <= 1'b0; e1_v <= 1'b0; w2_v <= 1'b0; we <= 1'b0;
            e0_idx <= {AW{1'b0}}; e1_idx <= {AW{1'b0}}; w2_idx <= {AW{1'b0}}; waddr <= {AW{1'b0}};
            w2_data <= {MW{1'b0}}; wdata <= {MW{1'b0}};
        end else begin
            we     <= 1'b0;
            e0_v   <= ev_v;  e0_idx <= ev_idx;
            e1_v   <= e0_v;  e1_idx <= e0_idx;
            w2_v   <= we;    w2_idx <= waddr; w2_data <= wdata;
            if (clr_we) begin
                we <= 1'b1; waddr <= clr_addr; wdata <= {MW{1'b0}};
            end
            if (e1_v) begin
                we <= 1'b1; waddr <= e1_idx; wdata <= inc;
            end
        end
    end
endmodule
