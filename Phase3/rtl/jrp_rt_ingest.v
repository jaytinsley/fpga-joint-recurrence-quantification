`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// jrp_rt_ingest.v
//   Raw-sample ring FIFO and frame sequencer in front of jrp_top (see docs/phase4_realtime_frontend_spec.md).
//   Samples {y, x} arrive on an AXI-Stream slave port (from AXI-DMA, optionally paced to a chosen sample
//   rate) and are written into a ring RAM. When N_RAW samples are available, the previous frame is finished
//   and its result has been acknowledged, the sequencer pulses ext_start and drains the window into jrp_top
//   (one beat every 3 cycles, negligible against the scan), then waits for the result. Samples keep arriving
//   during the scan and the readout.
//
//   Overrun policy (CTRL[3]): 0 = backpressure the stream when the ring is full, 1 = accept and discard,
//   count it, and mark the first sample stored after the gap (a window that spans a gap is flagged).
//   HOP (0 = N_RAW) is how far the window start moves after each frame; HOP < N_RAW gives overlapping windows.
//   Registers (byte offsets, 32 bit):
//     0x00 CTRL        RW [0] enable  [3] drop mode  | W pulses: [1] clear counters and flags  [2] ACK result
//     0x04 STATUS      R  [0] result_pending [1] overrun (sticky) [2] last window had a gap [3] busy
//                         [4] ring empty [5] last frame refused (cfg error, sticky)
//     0x08 HOP         RW 0x0C PERIOD RW (clocks per accepted sample, 0 or 1 = no pacing)
//     0x10 OCC R       0x14 OCC_MAX R   0x18 DROPPED R   0x1C FRAMES_DONE R   0x30 GAP_FRAMES R
//     0x20/0x24 T_READY lo/hi   0x28/0x2C T_RESULT lo/hi  (cycle counter when the window of the held result was ready / the result became valid)
// -----------------------------------------------------------------------------
module jrp_rt_ingest #(
    parameter integer DEPTH = 8192          // power of two
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

    input  wire [63:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,          // unused

    output wire [63:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,

    output reg         ext_start,             // one-cycle pulse to jrp_top
    input  wire        top_busy,
    input  wire        top_result,            // jrp_top metrics valid pulse
    input  wire        top_cfg_err,
    input  wire [31:0] n_raw,
    input  wire [63:0] cyc,                   // free-running cycle counter
    output wire        irq
);
    localparam integer AW = $clog2(DEPTH);
    localparam [2:0] S_IDLE = 3'd0, S_START = 3'd1, S_ADDR = 3'd2, S_WAIT = 3'd3, S_PRES = 3'd4, S_RES = 3'd5;

    // ---------------- AXI-Lite slave ----------------
    wire wr_fire = s_axi_awvalid && s_axi_wvalid && s_axi_awready && s_axi_wready;
    reg  [5:0] awaddr_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_bvalid <= 1'b0; s_axi_bresp <= 2'b00; awaddr_q <= 6'd0;
        end else begin
            s_axi_awready <= (~s_axi_awready) & s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid;
            s_axi_wready  <= (~s_axi_wready)  & s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid;
            if (~s_axi_awready && s_axi_awvalid) awaddr_q <= s_axi_awaddr;
            if (wr_fire) begin s_axi_bvalid <= 1'b1; s_axi_bresp <= 2'b00; end
            else if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
        end
    end

    reg        enable, drop_mode;
    reg [31:0] hop, period;
    reg        clr_p, ack_p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin enable <= 1'b0; drop_mode <= 1'b0; hop <= 32'd0; period <= 32'd0; clr_p <= 1'b0; ack_p <= 1'b0; end
        else begin
            clr_p <= 1'b0; ack_p <= 1'b0;
            if (wr_fire) case (awaddr_q[5:2])
                4'd0: begin enable <= s_axi_wdata[0]; drop_mode <= s_axi_wdata[3]; clr_p <= s_axi_wdata[1]; ack_p <= s_axi_wdata[2]; end
                4'd2: hop    <= s_axi_wdata;
                4'd3: period <= s_axi_wdata;
                default: ;
            endcase
        end
    end

    // ---------------- ring RAM and write side ----------------
    (* ram_style = "block" *) reg [64:0] ring [0:DEPTH-1];     // {gap, y, x}
    reg  [31:0] wcnt, rbase;
    reg         gap_pend;
    reg  [31:0] pace_cnt;
    wire [31:0] occ = wcnt - rbase;
    wire        have_space = occ < DEPTH;
    wire        tick = (period <= 32'd1) | (pace_cnt == 32'd0);
    assign s_axis_tready = tick & (have_space | drop_mode);
    wire acc   = s_axis_tvalid & s_axis_tready;
    wire store = acc & have_space;

    reg  [AW-1:0] rd_addr;
    reg  [64:0]   rd_q;
    always @(posedge clk) begin
        if (store) ring[wcnt[AW-1:0]] <= {gap_pend, s_axis_tdata};
        rd_q <= ring[rd_addr];
    end

    // ---------------- sequencer ----------------
    reg [2:0]  st;
    reg [2:0]  dly;
    reg [31:0] rcnt;
    reg        win_gap, frame_gap_q, win_t_set;
    reg        result_pending, overrun, cfg_error;
    reg [31:0] dropped, occ_max, frames_done, gap_frames;
    reg [63:0] t_ready, t_ready_res, t_result;     // t_ready_res: ready time of the window whose result is held
    wire [31:0] hop_eff = (hop == 32'd0) ? n_raw : hop;
    wire        win_ok  = enable && (n_raw != 32'd0) && (occ >= n_raw);
    wire        last_beat = (rcnt == n_raw - 32'd1);

    assign m_axis_tdata  = rd_q[63:0];
    assign m_axis_tvalid = (st == S_PRES);
    assign m_axis_tlast  = (st == S_PRES) && last_beat;
    assign irq = result_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wcnt <= 32'd0; rbase <= 32'd0; gap_pend <= 1'b0; pace_cnt <= 32'd0; st <= S_IDLE; dly <= 3'd0; rcnt <= 32'd0;
            win_gap <= 1'b0; frame_gap_q <= 1'b0; win_t_set <= 1'b0; result_pending <= 1'b0; overrun <= 1'b0; cfg_error <= 1'b0;
            dropped <= 32'd0; occ_max <= 32'd0; frames_done <= 32'd0; gap_frames <= 32'd0; t_ready <= 64'd0; t_ready_res <= 64'd0; t_result <= 64'd0;
            rd_addr <= {AW{1'b0}}; ext_start <= 1'b0;
        end else begin
            ext_start <= 1'b0;
            // input side
            if (acc) pace_cnt <= (period > 32'd1) ? period - 32'd1 : 32'd0;
            else if (pace_cnt != 32'd0) pace_cnt <= pace_cnt - 32'd1;
            if (store) begin wcnt <= wcnt + 32'd1; gap_pend <= 1'b0; end
            else if (acc) begin dropped <= dropped + 32'd1; overrun <= 1'b1; gap_pend <= 1'b1; end
            if (occ > occ_max) occ_max <= occ;

            case (st)
                S_IDLE: begin
                    if (win_ok && !win_t_set) begin t_ready <= cyc; win_t_set <= 1'b1; end
                    if (win_ok && !result_pending && !top_busy) begin
                        ext_start <= 1'b1; st <= S_START; dly <= 3'd0; rcnt <= 32'd0; win_gap <= 1'b0;
                        if (!win_t_set) t_ready <= cyc;
                        win_t_set <= 1'b0;
                    end
                end
                S_START: begin                                  // let jrp_top take the start before the first beat
                    dly <= dly + 3'd1;
                    if (dly == 3'd3) st <= S_ADDR;
                end
                S_ADDR: begin rd_addr <= (rbase + rcnt); st <= S_WAIT; end
                S_WAIT: st <= S_PRES;
                S_PRES: if (m_axis_tready) begin
                    if (rd_q[64] && rcnt != 32'd0) win_gap <= 1'b1;
                    rcnt <= rcnt + 32'd1;
                    if (last_beat) begin
                        frame_gap_q <= win_gap | (rd_q[64] && rcnt != 32'd0);
                        rbase <= rbase + hop_eff;
                        st <= S_RES;
                    end else st <= S_ADDR;
                end
                S_RES: begin
                    if (top_result) begin
                        result_pending <= 1'b1; frames_done <= frames_done + 32'd1; t_result <= cyc; t_ready_res <= t_ready;   // before the next window overwrites t_ready
                        if (frame_gap_q) gap_frames <= gap_frames + 32'd1;
                        st <= S_IDLE;
                    end else if (top_cfg_err) begin
                        result_pending <= 1'b1; cfg_error <= 1'b1; st <= S_IDLE;
                    end
                end
                default: st <= S_IDLE;
            endcase

            if (ack_p) result_pending <= 1'b0;
            if (clr_p) begin
                dropped <= 32'd0; overrun <= 1'b0; occ_max <= 32'd0; frames_done <= 32'd0; gap_frames <= 32'd0; cfg_error <= 1'b0;
            end
        end
    end

    // ---------------- read channel ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b0; s_axi_rvalid <= 1'b0; s_axi_rresp <= 2'b00; s_axi_rdata <= 32'd0;
        end else begin
            s_axi_arready <= (~s_axi_arready) & s_axi_arvalid & ~s_axi_rvalid;
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                case (s_axi_araddr[5:2])
                    4'd0:    s_axi_rdata <= {28'd0, drop_mode, 2'b00, enable};
                    4'd1:    s_axi_rdata <= {26'd0, cfg_error, (occ == 32'd0), (st != S_IDLE), frame_gap_q, overrun, result_pending};
                    4'd2:    s_axi_rdata <= hop;
                    4'd3:    s_axi_rdata <= period;
                    4'd4:    s_axi_rdata <= occ;
                    4'd5:    s_axi_rdata <= occ_max;
                    4'd6:    s_axi_rdata <= dropped;
                    4'd7:    s_axi_rdata <= frames_done;
                    4'd8:    s_axi_rdata <= t_ready_res[31:0];
                    4'd9:    s_axi_rdata <= t_ready_res[63:32];
                    4'd10:   s_axi_rdata <= t_result[31:0];
                    4'd11:   s_axi_rdata <= t_result[63:32];
                    4'd12:   s_axi_rdata <= gap_frames;
                    default: s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end
endmodule
