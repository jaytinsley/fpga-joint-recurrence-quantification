`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// jrp_sample_feeder.v
//   Bring-up helper for running jrp_top from the Vivado hardware manager (JTAG-to-AXI) without a
//   DMA or DDR: a sample RAM that the host fills over AXI-Lite, and a streamer that sends the
//   stored {y, x} pairs into the jrp_top AXI-Stream input at one beat per cycle.
//   Not part of the architecture (the PS + AXI-DMA path replaces it); only used for the board test.
//
//   Registers (32-bit, word addressed, byte address in brackets):
//     0x00 CONTROL   W: [0] start streaming COUNT beats from address 0   [1] reset write pointer
//     0x04 STATUS    R: [0] streaming  [1] done (sticky, cleared by start)  [31:16] write pointer
//     0x08 COUNT     RW number of beats to stream (<= DEPTH)
//     0x0C X_DATA    RW staging register for the x sample
//     0x10 Y_DATA    W  writing it stores {Y_DATA_written, X_DATA} at the write pointer and
//                       increments the pointer
//     0x14 CYCLES    R  cycles from start to the last beat accepted (stream duration)
//   One beat = {y[31:0], x[31:0]}; TLAST on the last beat.
// -----------------------------------------------------------------------------
module jrp_sample_feeder #(
    parameter integer DEPTH = 8192
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [5:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [5:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    output wire [63:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast
);
    localparam integer AW = $clog2(DEPTH);

    (* ram_style = "block" *) reg [63:0] mem [0:DEPTH-1];
    reg [AW:0]   wptr;
    reg [31:0]   count, x_stage, cycles;
    reg          streaming, done, started_flag;

    wire wr_fire = s_axi_awvalid && s_axi_wvalid && s_axi_awready && s_axi_wready;
    reg  [5:0] awaddr_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_bvalid <= 1'b0; s_axi_bresp <= 2'b00;
            awaddr_q <= 6'd0;
        end else begin
            s_axi_awready <= (~s_axi_awready) & s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid;
            s_axi_wready  <= (~s_axi_wready)  & s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid;
            if (~s_axi_awready && s_axi_awvalid) awaddr_q <= s_axi_awaddr;
            if (wr_fire) begin s_axi_bvalid <= 1'b1; s_axi_bresp <= 2'b00; end
            else if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
        end
    end

    // ---- sample RAM: write port from the register interface, read port for the streamer ----
    reg                 mem_we;
    reg  [AW-1:0]       mem_waddr;
    reg  [63:0]         mem_wdata;
    always @(posedge clk) if (mem_we) mem[mem_waddr] <= mem_wdata;

    reg  [AW:0]         rd_idx;       // next beat to read
    reg  [63:0]         rd_data;
    reg                 rd_valid;     // rd_data holds a beat not yet accepted
    wire                accept = m_axis_tvalid && m_axis_tready;
    assign m_axis_tdata = rd_data;
    assign m_axis_tlast = m_axis_tvalid && (rd_idx == count[AW:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= 0; count <= 32'd0; x_stage <= 32'd0; cycles <= 32'd0;
            streaming <= 1'b0; done <= 1'b0; mem_we <= 1'b0; mem_waddr <= 0; mem_wdata <= 64'd0;
            rd_idx <= 0; rd_data <= 64'd0; m_axis_tvalid <= 1'b0;
        end else begin
            mem_we <= 1'b0;
            if (wr_fire) begin
                case (awaddr_q[5:2])
                    4'd0: begin
                        if (s_axi_wdata[1]) wptr <= 0;
                        if (s_axi_wdata[0]) begin
                            streaming <= 1'b1; done <= 1'b0; rd_idx <= 0; cycles <= 32'd0;
                        end
                    end
                    4'd2: count   <= s_axi_wdata;
                    4'd3: x_stage <= s_axi_wdata;
                    4'd4: begin
                        mem_we <= 1'b1; mem_waddr <= wptr[AW-1:0]; mem_wdata <= {s_axi_wdata, x_stage};
                        wptr <= wptr + 1'b1;
                    end
                    default: ;
                endcase
            end
            if (streaming) begin
                cycles <= cycles + 1;
                // one RAM read latency: present the beat one cycle after its address
                if (!m_axis_tvalid || m_axis_tready) begin
                    if (rd_idx < count[AW:0]) begin
                        rd_data <= mem[rd_idx[AW-1:0]];
                        m_axis_tvalid <= 1'b1;
                        rd_idx <= rd_idx + 1'b1;
                    end else begin
                        m_axis_tvalid <= 1'b0;
                    end
                end
                if (accept && (rd_idx == count[AW:0])) begin
                    streaming <= 1'b0; done <= 1'b1; m_axis_tvalid <= 1'b0;
                end
            end
        end
    end

    // ---- read channel ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b0; s_axi_rvalid <= 1'b0; s_axi_rresp <= 2'b00; s_axi_rdata <= 32'd0;
        end else begin
            s_axi_arready <= (~s_axi_arready) & s_axi_arvalid & ~s_axi_rvalid;
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                case (s_axi_araddr[5:2])
                    4'd1:    s_axi_rdata <= {{(16-(AW+1)){1'b0}}, wptr, 14'd0, done, streaming};
                    4'd2:    s_axi_rdata <= count;
                    4'd3:    s_axi_rdata <= x_stage;
                    4'd5:    s_axi_rdata <= cycles;
                    default: s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end
endmodule
