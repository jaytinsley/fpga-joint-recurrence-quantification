`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2025/07/01 11:46:53
// Design Name: 
// Module Name: tb_phase_space_reconstruction
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module tb_phase_space_reconstruction;

    parameter DATA_WIDTH = 32;
    parameter MAX_M = 10;
    parameter MAX_TAU = 128;
    
    reg clk;
    reg rst_n;

    reg  [DATA_WIDTH-1:0] data_in;
    reg  data_valid;
    wire data_ready;

    reg  [7:0] m_dim;
    reg  [7:0] tau_delay;

    wire [DATA_WIDTH*MAX_M-1:0] vector_out;
    wire vector_valid;
    reg  vector_ready;

    // Instantiate DUT
    phase_space_reconstruction #(
        .DATA_WIDTH(DATA_WIDTH),
        .MAX_M(MAX_M),
        .MAX_TAU(MAX_TAU)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(data_in),
        .data_valid(data_valid),
        .data_ready(data_ready),
        .m_dim(m_dim),
        .tau_delay(tau_delay),
        .vector_out(vector_out),
        .vector_valid(vector_valid),
        .vector_ready(vector_ready)
    );

    // Clock generation
    always #5 clk = ~clk;

    // Stimulus
    integer i;
    initial begin
        $display("Starting Phase-Space Reconstruction Test...");
        
        clk = 0;
        rst_n = 0;
        data_in = 0;
        data_valid = 0;
        m_dim = 3;
        tau_delay = 2;
        vector_ready = 1;

        // Reset
        #20;
        rst_n = 1;

        // Send input data
        #10;
        for (i = 0; i < 30; i = i + 1) begin
            @(posedge clk);
            if (data_ready) begin
                data_in <= i;
                data_valid <= 1;
            end else begin
                data_valid <= 0;
            end
        end
        data_valid <= 0;

        // Wait to finish
        #200;
        $finish;
    end
    integer j;
    // Monitor output
    always @(posedge clk) begin
        if (vector_valid) begin
            $display("Time %t: vector_out_valid! Vector =", $time);
            for (j = 0; j < MAX_M; j = j + 1) begin
                $display("  [%0d] = %0d", j, vector_out[j*DATA_WIDTH +: DATA_WIDTH]);
            end
        end
    end

endmodule
