`timescale 1ns / 1ps
// Self-checking embedding test. Drives N samples (Q8.24 hex file) through the embedding block
// and checks every emitted vector against the definition v[t] = {x[t], x[t-tau], ..., x[t-(m-1)tau]}
// (component 0 = newest), for t = (m-1)tau .. N-1. Works with the released phase_space_reconstruction
// and with jrp_psr (same ports). +SAMPLES=<hex file> +NS=<count> +M=<m> +TAU=<tau>
module tb_psr_check;
    parameter integer MAX_M   = 6;
    parameter integer MAX_TAU = 16;
    localparam integer DW = 32;

    reg clk = 0, rst_n = 0;
    always #3.333 clk = ~clk;

    string file;
    integer ns, m, tau;
    initial begin
        if (!$value$plusargs("SAMPLES=%s", file)) begin $display("FAIL: +SAMPLES missing"); $finish; end
        if (!$value$plusargs("NS=%d", ns)) begin $display("FAIL: +NS missing"); $finish; end
        if (!$value$plusargs("M=%d", m)) m = 5;
        if (!$value$plusargs("TAU=%d", tau)) tau = 3;
    end

    reg [31:0] x [0:(1<<16)-1];
    reg [DW-1:0] data_in; reg data_valid, data_last, frame_start;
    wire data_ready, vector_valid, ingest_done;
    wire [DW*MAX_M-1:0] vector_out;
    wire [31:0] n_actual;
    reg [7:0] m_dim, tau_delay; reg [31:0] n_target;

    `PSR_DUT #(.DATA_WIDTH(DW), .MAX_M(MAX_M), .MAX_TAU(MAX_TAU)) dut (
        .clk(clk), .rst_n(rst_n), .data_in(data_in), .data_valid(data_valid), .data_last(data_last),
        .data_ready(data_ready), .m_dim(m_dim), .tau_delay(tau_delay),
        .vector_out(vector_out), .vector_valid(vector_valid), .vector_ready(1'b1),
        .frame_start(frame_start), .ingest_done_pulse(ingest_done), .n_actual(n_actual), .n_target(n_target));

    integer i, k, t, errors, nvec, t_next;
    always @(posedge clk) if (rst_n && vector_valid) begin
        t = (m-1)*tau + nvec;        // time index of the newest sample of this vector
        for (k = 0; k < m; k = k + 1) begin
            if (vector_out[k*DW +: DW] !== x[t - k*tau]) begin
                errors = errors + 1;
                if (errors < 8) $display("vector %0d (t=%0d) comp %0d: got %h want %h", nvec, t, k,
                                         vector_out[k*DW +: DW], x[t - k*tau]);
            end
        end
        for (k = m; k < MAX_M; k = k + 1)
            if (vector_out[k*DW +: DW] !== 32'd0) begin errors = errors + 1; if (errors < 8) $display("comp %0d not zero", k); end
        nvec = nvec + 1;
    end

    initial begin
        errors = 0; nvec = 0; data_valid = 0; data_last = 0; frame_start = 0; data_in = 0;
        #1; $readmemh(file, x);
        m_dim = m; tau_delay = tau; n_target = ns;
        repeat (5) begin @(posedge clk); #1; end
        rst_n = 1;
        repeat (3) begin @(posedge clk); #1; end
        frame_start = 1; @(posedge clk); #1; frame_start = 0;
        for (i = 0; i < ns; i = i + 1) begin
            data_in = x[i]; data_valid = 1; data_last = (i == ns-1);
            @(posedge clk); #1;
            while (!data_ready) begin @(posedge clk); #1; end
        end
        data_valid = 0; data_last = 0;
        repeat (20) begin @(posedge clk); #1; end
        if (nvec != ns - (m-1)*tau) begin errors = errors + 1; $display("VECTOR COUNT: got %0d want %0d", nvec, ns - (m-1)*tau); end
        if (errors == 0) $display("PASS PSR %s: %0d vectors, m=%0d tau=%0d", file, nvec, m, tau);
        else             $display("FAIL PSR %s: %0d errors over %0d vectors (m=%0d tau=%0d)", file, errors, nvec, m, tau);
        $finish;
    end
endmodule
