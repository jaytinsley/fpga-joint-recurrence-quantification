
// tdp_bram_fw.v
// Generic true dual-port RAM (synchronous read, 1-cycle latency)
// with cross-port write-first forwarding (A<->B).
`timescale 1ns / 1ps
module tdp_bram_fw #(
  parameter integer W  = 32,           // data width
  parameter integer AW = 14            // address width (depth = 2^AW)
)(
  input  wire              clk,

  // Port A (write/read)
  input  wire              wea,
  input  wire [AW-1:0]     addra,
  input  wire [W-1:0]      dina,
  output reg  [W-1:0]      douta,

  // Port B (write/read)
  input  wire              web,
  input  wire [AW-1:0]     addrb,
  input  wire [W-1:0]      dinb,
  output reg  [W-1:0]      doutb
);
  
  (* ram_style = "block" *) reg [W-1:0] mem [0:(1<<AW)-1];

  // Port A: synchronous write & read with cross-port forwarding
  always @(posedge clk) begin
    if (wea) mem[addra] <= dina;
    if (web && (addrb == addra)) douta <= dinb;
    else                          douta <= mem[addra];
  end

  // Port B: synchronous write & read with cross-port forwarding
  always @(posedge clk) begin
    if (web) mem[addrb] <= dinb;
    if (wea && (addra == addrb)) doutb <= dina;
    else                          doutb <= mem[addrb];
  end
endmodule
