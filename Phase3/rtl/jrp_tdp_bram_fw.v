`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// jrp_tdp_bram_fw.v
//   Replaces the released tdp_bram_fw.v (Li, Lai and Oberst 2026, Zenodo
//   10.5281/zenodo.20406392, MIT) for the RQA extractor's column and diagonal state memories.
//   Same ports and same behaviour for the way the extractor uses it: port A writes, port B reads
//   with a one-cycle read latency, and a read of the address being written in the same cycle
//   returns the new data (write-first forwarding).
//
//   Why: the released template allows a write on both ports and a read on both ports with
//   cross-port bypass wrapped around the array. Vivado reports "Infeasible attribute ram_style =
//   block ... trying to implement using LUTRAM" and builds the memories from 15,360 LUTs of
//   distributed RAM, which is also the critical path of the routed design (98 % routing delay,
//   write data fanned out to about 96 RAM cells).
//   Here the array is a plain simple dual-port RAM (one write port, one registered-output read
//   port) and the bypass is two registers and a multiplexer after the RAM, so it maps to block RAM.
//   The extractor ties web to 0 and leaves douta unconnected, so the second write port and the
//   port A read are not implemented (web and dinb are ignored, douta reads as zero).
// -----------------------------------------------------------------------------
module jrp_tdp_bram_fw #(
    parameter integer W  = 32,
    parameter integer AW = 14
)(
    input  wire              clk,

    input  wire              wea,
    input  wire [AW-1:0]     addra,
    input  wire [W-1:0]      dina,
    output wire [W-1:0]      douta,   // not implemented, reads as 0

    input  wire              web,     // ignored: tie to 0
    input  wire [AW-1:0]     addrb,
    input  wire [W-1:0]      dinb,    // ignored
    output wire [W-1:0]      doutb
);
    (* ram_style = "block" *) reg [W-1:0] mem [0:(1<<AW)-1];
    reg [W-1:0] rdata;
    reg [W-1:0] din_q;
    reg         bypass;

    always @(posedge clk) begin
        if (wea) mem[addra] <= dina;
        rdata  <= mem[addrb];
        din_q  <= dina;
        bypass <= wea && (addra == addrb);
    end

    assign doutb = bypass ? din_q : rdata;
    assign douta = {W{1'b0}};
endmodule
