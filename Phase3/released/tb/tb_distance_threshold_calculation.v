`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2025/07/02 10:32:36
// Design Name: 
// Module Name: tb_distance_threshold_calculation
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

module tb_distance_threshold_calculation;

    // Parameters
    localparam DATA_WIDTH = 32;
    localparam MAX_M      = 5;

    // DUT Ports
    reg                          clk;
    reg                          rst_n;
    reg  [DATA_WIDTH*MAX_M-1:0]  vec_a;
    reg  [DATA_WIDTH*MAX_M-1:0]  vec_b;
    reg                          vec_valid;
    wire                         vec_ready;

    reg  [DATA_WIDTH-1:0]        eps2;
    wire                         rec_flag;
    wire                         rec_valid;
    reg                          rec_ready;

    // Clock generation
    always #5 clk = ~clk;  // 100 MHz

    // Instantiate DUT
    distance_threshold_calculation #(
        .DATA_WIDTH(DATA_WIDTH),
        .MAX_M(MAX_M)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .vec_a(vec_a),
        .vec_b(vec_b),
        .vec_valid(vec_valid),
        .vec_ready(vec_ready),
        .eps2(eps2),
        .rec_flag(rec_flag),
        .rec_valid(rec_valid),
        .rec_ready(rec_ready)
    );

    // Simulation control
    initial begin
        $display("Start Simulation");

        clk = 0;
        rst_n = 0;
        vec_valid = 0;
        rec_ready = 1;
        #20;
        rst_n = 1;
        #20;

        // --------------------------
        // Test Case 1: small distance, rec_flag should be 1
        vec_a = {to_fixed(4), to_fixed(3),to_fixed(2),to_fixed(1), to_fixed(1)};
        vec_b = {to_fixed(5), to_fixed(3),to_fixed(2),to_fixed(1), to_fixed(1)};
        eps2 = to_fixed(4);  // threshold = 4
        vec_valid = 1;
        #10;
        vec_valid = 0;

        // Wait for result
        wait (rec_valid);
        $display("rec_flag (should be 1): %d", rec_flag);
        #20;

        // --------------------------
        // Test Case 2: large distance, rec_flag should be 0
        vec_b = {to_fixed(11), to_fixed(3),to_fixed(2),to_fixed(1),to_fixed(1)};
        eps2 = to_fixed(25);  // threshold = 25
        vec_valid = 1;
        #10;
        vec_valid = 0;

        // Wait for result
        wait (rec_valid);
        $display("rec_flag (should be 0): %d", rec_flag);
        #10;

        $display("Simulation Complete");
        $finish;
    end

    // Function to convert integer to fixed-point (Q8.24)
    function [DATA_WIDTH-1:0] to_fixed;
        input integer val;
        begin
            to_fixed = val <<< 24;
        end
    endfunction

endmodule
