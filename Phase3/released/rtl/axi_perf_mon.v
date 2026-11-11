// axi_perf_mon.v
// 64-bit cycle counter + latched timestamps for phases
// AXI-Lite map (word offsets):
// 0x00 CONTROL W1P: [0]=start, [1]=clear
// 0x04 STATUS  R  : [0]=armed, [1]=done
// 0x10/14 CYCLE_LO/HI
// 0x18/1C T_START_LO/HI
// 0x20/24 T_LOAD_LO/HI
// 0x28/2C T_PAIRS_LO/HI
// 0x30/34 T_CELLS_LO/HI
// 0x38/3C T_SCAN_LO/HI

module axi_perf_mon #(
  parameter integer C_S_AXI_ADDR_WIDTH = 6,
  parameter integer C_S_AXI_DATA_WIDTH = 32
)(
  input  wire                         clk,
  input  wire                         rst_n,

  input  wire                         load_end_pulse,
  input  wire                         pairs_end_pulse,
  input  wire                         cells_end_pulse,
  input  wire                         scan_end_pulse,
  
  // NEW: DTC timing pulses (1-cycle)
  input  wire                         dtc_start_pulse,
  input  wire                         dtc_end_pulse,
  
  output reg                          start_pulse_out,

  // AXI-Lite slave
  input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
  input  wire                          s_axi_awvalid,
  output reg                           s_axi_awready,
  input  wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
  input  wire [C_S_AXI_DATA_WIDTH/8-1:0] s_axi_wstrb,
  input  wire                          s_axi_wvalid,
  output reg                           s_axi_wready,
  output reg  [1:0]                    s_axi_bresp,
  output reg                           s_axi_bvalid,
  input  wire                          s_axi_bready,

  input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
  input  wire                          s_axi_arvalid,
  output reg                           s_axi_arready,
  output reg [C_S_AXI_DATA_WIDTH-1:0]  s_axi_rdata,
  output reg  [1:0]                    s_axi_rresp,
  output reg                           s_axi_rvalid,
  input  wire                          s_axi_rready
);
  reg [63:0] cycle_ctr;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) cycle_ctr <= 64'd0; else cycle_ctr <= cycle_ctr + 1'b1;
  end

  reg [63:0] t_start, t_load, t_pairs, t_cells, t_scan;
  // DTC timestamps and duration
  reg [63:0] t_dtc_start;
  reg [63:0] t_dtc_end;

  reg armed, done;

  wire wr_fire = s_axi_awvalid && s_axi_wvalid && s_axi_awready && s_axi_wready;

  reg do_start, do_clear;
  
  wire [31:0] dtc_cycles   = (t_dtc_end > t_dtc_start) ? (t_dtc_end - t_dtc_start) : 32'd0;
  wire [31:0] total_cycles = (t_scan    > t_start    ) ? (t_scan    - t_start    ) : 32'd0;

  always @(*) begin
    do_start = 1'b0; do_clear = 1'b0;
    if (wr_fire && (s_axi_awaddr[5:2]==4'h0)) begin
      do_start = s_axi_wdata[0];
      do_clear = s_axi_wdata[1];
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      start_pulse_out <= 1'b0; armed<=1'b0; done<=1'b0;
      t_start<=0; t_load<=0; t_pairs<=0; t_cells<=0; t_scan<=0;
      t_dtc_start <= 64'd0; t_dtc_end <= 64'd0; 
    end else begin
      start_pulse_out <= 1'b0;
      if (do_clear) begin
        t_start<=0; t_load<=0; t_pairs<=0; t_cells<=0; t_scan<=0; armed<=1'b0; done<=1'b0;
        // clear dtc stamps too
        t_dtc_start <= 64'd0; t_dtc_end <= 64'd0; 
      end
      if (do_start) begin
        start_pulse_out <= 1'b1;
        t_start <= cycle_ctr;
        t_load<=0; t_pairs<=0; t_cells<=0; t_scan<=0;
        t_dtc_start <= 64'd0; t_dtc_end <= 64'd0; 
        armed <= 1'b1; done <= 1'b0;
      end
      if (armed && (t_load==0)  && load_end_pulse)  t_load  <= cycle_ctr;
      if (armed && (t_pairs==0) && pairs_end_pulse) t_pairs <= cycle_ctr;
      if (armed && (t_cells==0) && cells_end_pulse) t_cells <= cycle_ctr;
      if (armed && (t_dtc_start==0) && dtc_start_pulse) t_dtc_start <= cycle_ctr;
      if (armed && (t_dtc_end  ==0) && dtc_end_pulse  ) t_dtc_end   <= cycle_ctr;
      if (armed && (t_scan==0)  && scan_end_pulse) begin
        t_scan <= cycle_ctr; done <= 1'b1; armed <= 1'b0;
      end
    end
  end

  // AXI-Lite write
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_axi_awready<=1'b0; s_axi_wready<=1'b0; s_axi_bvalid<=1'b0; s_axi_bresp<=2'b00;
    end else begin
      s_axi_awready <= (~s_axi_awready) && s_axi_awvalid && s_axi_wvalid && ~s_axi_bvalid;
      s_axi_wready  <= (~s_axi_wready)  && s_axi_awvalid && s_axi_wvalid && ~s_axi_bvalid;
      if (wr_fire) begin s_axi_bvalid<=1'b1; s_axi_bresp<=2'b00; end
      else if (s_axi_bvalid && s_axi_bready) s_axi_bvalid<=1'b0;
    end
  end

  // AXI-Lite read
  reg [C_S_AXI_ADDR_WIDTH-1:0] araddr_r;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_axi_arready<=1'b0; s_axi_rvalid<=1'b0; s_axi_rresp<=2'b00; s_axi_rdata<=0;
    end else begin
      if (~s_axi_arready && s_axi_arvalid && ~s_axi_rvalid) begin
        s_axi_arready<=1'b1; araddr_r<=s_axi_araddr;
      end else s_axi_arready<=1'b0;

      if (s_axi_arready && s_axi_arvalid && ~s_axi_rvalid) begin
        s_axi_rvalid<=1'b1; s_axi_rresp<=2'b00;
        case (araddr_r[5:2])
          4'h1: s_axi_rdata <= cycle_ctr[31:0];
          4'h5: s_axi_rdata <= cycle_ctr[63:32];
          4'h6: s_axi_rdata <= t_start[31:0];
          4'h7: s_axi_rdata <= t_start[63:32];
          4'h8: s_axi_rdata <= t_load[31:0];
          4'h9: s_axi_rdata <= t_load[63:32];
          4'hA: s_axi_rdata <= t_pairs[31:0];
          4'hB: s_axi_rdata <= t_pairs[63:32];
          4'hC: s_axi_rdata <= t_cells[31:0];
          4'hD: s_axi_rdata <= t_cells[63:32];
          4'hE: s_axi_rdata <= t_scan[31:0];
          4'hF: s_axi_rdata <= t_scan[63:32];
          //DTC duration (low/high) mapped to word idx 2/3 -> offsets 0x08/0x0C
          4'h2: s_axi_rdata <= dtc_cycles;     
          4'h3: s_axi_rdata <= total_cycles;   
          4'h0: s_axi_rdata <= {30'd0, done, armed};
          default: s_axi_rdata <= 32'h0;
        endcase
      end else if (s_axi_rvalid && s_axi_rready) s_axi_rvalid<=1'b0;
    end
  end
endmodule