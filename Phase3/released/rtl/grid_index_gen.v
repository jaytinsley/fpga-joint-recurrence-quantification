`timescale 1ns / 1ps
module grid_index_gen #(
  parameter integer N_BITS = 14
)(
  input  wire               clk,
  input  wire               rst_n,
  input  wire               start_pulse,
  input  wire [31:0]        N,
  output reg  [N_BITS-1:0]  i_out,
  output reg  [N_BITS-1:0]  j_out,
  output reg                valid,
  input  wire               ready,
  output reg                done_pulse
);
  localparam S_IDLE=2'd0, S_RUN=2'd1, S_DONE=2'd2;
  reg [1:0] st;
  reg [31:0] n_reg;
  reg [N_BITS-1:0] i, j;

  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      st<=S_IDLE; n_reg<=0; i<=0; j<=0;
      valid<=1'b0; done_pulse<=1'b0; i_out<=0; j_out<=0;
    end else begin
      done_pulse<=1'b0;
      case(st)
        S_IDLE: begin
          valid<=1'b0;
          if(start_pulse) begin
            n_reg<=N[31:0];
            i<=0; j<=0;
            st<= (N!=0) ? S_RUN : S_DONE;
          end
        end
        S_RUN: begin
          if(!valid) begin
            i_out<=i; j_out<=j; valid<=1'b1;
          end else if(valid && ready) begin
            valid<=1'b0;
            if (j + 1 < n_reg[N_BITS-1:0]) begin
              j<=j+1'b1;
            end else begin
              j<=0;
              if (i + 1 < n_reg[N_BITS-1:0]) i<=i+1'b1;
              else st<=S_DONE;
            end
          end
        end
        S_DONE: begin
          valid<=1'b0; done_pulse<=1'b1; st<=S_IDLE;
        end
      endcase
    end
  end
endmodule
