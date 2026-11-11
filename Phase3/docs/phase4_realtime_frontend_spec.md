# Phase 4 spec: DMA front end and raw-sample ring FIFO

Status: specification only. Nothing in this document is built or simulated yet.
Basis: `jrp_top` K=2 as verified on the board (55.7 ms per N = 4096 frame at 150 MHz).

## 1. Goal and non-goals

Goal: feed `jrp_top` from the PS through AXI-DMA, with a raw-sample FIFO in front so that samples
keep arriving while a frame is scanned, and report one set of JRQA metrics per window with no lost
samples. The result is real-time operation for non-overlapping windows (and, as an option,
sliding windows with a hop).

Non-goals: a second scan engine, a ping-pong vector buffer (6 copies x 6 URAM = 72 > 64 URAM on the
XCZU5EV, so it does not fit), changes to the extractor or scan engine.

## 2. What exists and what constrains the design

- `jrp_top` takes one AXI-Stream beat `{y[31:0], x[31:0]}` (Q8.24) per time step, `tlast` on the last
  beat of a frame, and a `start` pulse from the control registers (`jrp_axi_regs`).
- The embedding blocks write the vector buffers from address 0 on `frame_start`. The buffers are read
  for the whole scan, so a new frame cannot be ingested until the previous scan has finished.
- The counters and histograms are overwritten by the next frame (histogram clear at the start of the
  next scan). They must be read, or copied, before then.
- Today the stream source is `jrp_sample_feeder`, filled over JTAG-AXI. It is a bring-up helper only.

Consequence: the FIFO does not hold the window. It holds the samples that arrive while the previous
frame is scanned and read out. A window is drained into `jrp_top` at one beat per cycle (4096 cycles,
27 us), which is negligible against the 55.7 ms scan.

## 3. Block diagram

    DDR/OCM --> AXI DMA (MM2S) --64b AXIS--> [pacer] --> jrp_rt_ingest (ring RAM + frame sequencer)
                                                              |  64b AXIS, tlast, 1 beat/cycle
                                                              v
                                                         jrp_top (K = 2)  <-- AXI-Lite <-- PS (HPM)
                                                              |  irq (result ready)
                                                              v
                                                         PS: read counters, compute metrics

New: `jrp_rt_ingest`, an optional `pacer`, a PS + DMA block design. Changed: `jrp_top` gains an
`ext_start` input OR-ed with the register start pulse; `jrp_axil_decode` gains a sixth target;
`jrp_board_core` instantiates `jrp_rt_ingest` in place of (or beside, selected by a parameter)
`jrp_sample_feeder`.

## 4. jrp_rt_ingest

### 4.1 Ring RAM
- 8192 x 64 bit simple-dual-port block RAM (`xpm_memory_sdpram`), about 15 BRAM36.
- Absolute 32-bit counters: `wcnt` (samples written), `rbase` (absolute index of the first sample of
  the next window), `rcnt` (samples drained in the current window). RAM address = counter modulo 8192.
- Occupancy = `wcnt - rbase`. Free space = 8192 - occupancy.

### 4.2 Input and overrun policy (parameter `ON_FULL`)
- Mode 0, backpressure (DMA-fed, default): `s_axis_tready` = free space > 0. DMA stalls, nothing lost.
- Mode 1, drop and flag (paced or live source that cannot stall): when full, the sample is discarded,
  `dropped` increments and a sticky `overrun` bit sets. A window that contains a dropped sample is
  flagged invalid (`frame_gap` bit in the status of that frame) because the time axis is broken.

### 4.3 Frame sequencer
States: IDLE, WAIT_READY, DRAIN, WAIT_RESULT.
- IDLE to WAIT_READY: `enable` set and occupancy >= N_RAW.
- WAIT_READY to DRAIN: `jrp_top` idle (`ing_busy` and `scan_busy` low) and the previous result
  acknowledged (4.5). Pulse `ext_start` (equivalent of writing START, after the registers are set).
- DRAIN: send N_RAW beats starting at `rbase` into `jrp_top`, `tlast` on the last, honouring
  `tready`. On the last beat: `rbase += HOP`.
- WAIT_RESULT: wait for `metrics_valid`, then set `result_pending`, raise the interrupt, increment
  `frames_done`, capture timestamps (4.6). Return to IDLE.
- `HOP` register: HOP = N_RAW gives non-overlapping windows (default). HOP < N_RAW gives overlapping
  windows at no extra RAM cost, because the samples are still in the ring; it only needs
  N_RAW - HOP + fs x (T_scan + T_read) <= 8192.
- Parameters N_RAW, m, tau, eps, lmin/vmin, BASE_X/BASE_Y, N_JOINT stay in the existing `jrp_axi_regs`.
  They must not change while a frame is in flight; the sequencer latches nothing.

### 4.4 Pacer (test aid, parameterised in)
Releases one beat every `PERIOD` clock cycles (PERIOD = 150e6 / fs) from the DMA stream into the ring.
Emulates a sensor at a chosen sample rate while the data comes from DDR. `PERIOD = 0` bypasses it.
Pacing happens at the FIFO input, so overrun behaves as it would with a real ADC. Use mode 1 with it.

### 4.5 Result handshake (decision R1)
Frame k+1 does not start until the PS acknowledges frame k (write `ACK`, clears `result_pending`).
The PS reads the counters and only histogram bins up to max(l_max, v_max) + 1, then acks. While it
does so the ring keeps filling. The alternative is a shadow copy of the counters and histograms
(about 15 more BRAM36, no ack stall); not needed unless the readout proves slow.

### 4.6 AXI-Lite registers (new target at byte offset 0xA0000)
| Offset | Name | Access | Meaning |
|---|---|---|---|
| 0x00 | CTRL | W | [0] enable, [1] clear counters and flags, [2] ACK, [3] ON_FULL mode |
| 0x04 | STATUS | R | [0] result_pending, [1] overrun (sticky), [2] frame_gap (this frame), [3] draining, [4] ring empty |
| 0x08 | HOP | RW | window hop in samples |
| 0x0C | PERIOD | RW | pacer period in clocks, 0 = off |
| 0x10 | OCCUPANCY | R | `wcnt - rbase` now |
| 0x14 | OCC_MAX | R | high-water mark since clear |
| 0x18 | DROPPED | R | samples discarded |
| 0x1C | FRAMES_DONE | R | completed windows |
| 0x20 | T_WINDOW_FULL_LO/HI (0x20, 0x24) | R | free-running cycle counter when the window became complete |
| 0x28 | T_RESULT_LO/HI (0x28, 0x2C) | R | cycle counter at `metrics_valid` |

The cycle counter is the 64-bit counter already in `jrp_board_core`. End-to-end latency =
T_RESULT - T_WINDOW_FULL (expect 55.7 ms + 27 us + queueing).

## 5. DMA and PS block design

- Zynq UltraScale+ MPSoC with the ALINX board preset (DDR4 configured). Current builds run with DDR
  disabled, so this needs the vendor DDR settings. Risk R-DDR below.
- AXI DMA v7.1, MM2S only, stream width 64, memory-mapped width 64, max burst 256, length register
  width 26 bits (64 MB per transfer). Direct register mode: one long transfer for a whole recording
  (a 10 s recording at 20 kHz is 1.6 MB). Scatter-gather ring only if live capture into DDR is added.
- DMA master to `S_AXI_HP0_FPD`; control through an AXI SmartConnect from `M_AXI_HPM0_FPD` to the
  DMA `S_AXI_LITE` and to `jrp_board_core` (1 MB window, base e.g. 0xA0000000). The existing
  JTAG-to-AXI master stays on the same interconnect for debug.
- `pl_clk0` = 150 MHz, processor system reset, `result_irq` and DMA `mm2s_introut` to `pl_ps_irq0`.
- Data layout in memory: 8 bytes per time step, `{y, x}` little-endian, Q8.24, as produced by
  `Phase3/scripts/gen_hw_case.py`. The Python side writes a binary file; the host loads it with
  `xsdb dow -data`.
- Bare-metal Vitis standalone app on A53 core 0 first (xaxidma driver). No Linux needed for the capstone.
- Fallback with no DDR: source the data from PS OCM (256 KB, holds 32768 time steps) and DMA from there.

## 6. Capacity and rate budget

T_cycle = T_ingest (4096 cycles = 27 us) + T_scan (55.7 ms) + T_read (est. 1 to 3 ms, to be measured).

| N_RAW | T_scan | max sustained fs (non-overlap) | ring needed at that fs |
|---|---|---|---|
| 2048 | ~14 ms | ~130 kHz | ~2000 |
| 4096 | 55.7 ms | ~69 kHz (73 kHz with T_read = 0) | ~4100 |
| 8192 | ~223 ms | ~36 kHz | ~8200 (at the limit of the 8192 ring) |

Ring depth 8192 therefore covers N_RAW = 4096 with 2x headroom and N_RAW = 8192 just barely.
Results per second at N = 4096 are at most about 17. Bandwidth is not an issue: 8 B x 73 kHz = 0.6 MB/s
against a DMA capable of 1.2 GB/s.

## 7. Resource estimate (to be confirmed by a build)

Ring RAM about 15 BRAM36, DMA and interconnect about 4 to 6 BRAM and 4 to 6k LUT, sequencer and
registers under 1k LUT. Expected totals: BRAM 63 to about 85 of 144, URAM unchanged at 36 of 64,
LUT 11k to about 17k of 117k. Timing risk is the PS-PL interconnect at 150 MHz; the DMA-to-ring path
is a plain 64-bit stream.

## 8. Verification plan

1. RTL unit test `tb_rt_ingest`: random arrival gaps and bursts, backpressure and drop modes, HOP =
   N_RAW and HOP < N_RAW, full and empty edges, ack stall, ring wrap (wcnt > 8192). Check against a
   Python model of the window sequence.
2. System sim: `jrp_board_core` fed through an AXIS source model with the pacer on, several golden
   frames back to back; counters and histograms must match `jrp.rqa.rtl_counters` for each window.
3. Python: `export_stream_golden.py` cuts a long recording into the exact windows the hardware will
   see (N_RAW, HOP) and writes per-window expected counters, so the hardware log can be compared window
   by window.
4. Hardware, step 1: OCM or DDR to DMA to the ring, pacer off, 100 windows, all exact.
5. Hardware, step 2: rate sweep 10 kHz to 90 kHz with the pacer on. Expect zero drops and exact results
   up to the computed limit, and `overrun` set above it. Record OCC_MAX and latency.
6. Soak: at least 1000 windows at about 50 kHz, zero drops, every window exact.

## 9. Known limits and risks

- R-DDR: DDR4 bring-up needs the ALINX preset. If it is not available, use OCM (section 5).
- Results must be read within a few ms or the ack stalls the next window; the ring absorbs this up to its depth.
- Overlapping windows (HOP < N_RAW) still produce at most one result per T_cycle, so the hop is
  effectively bounded below by fs x T_cycle.
- Windows are independent. There is no incremental update of a sliding window.
- A change of m, tau or eps between windows needs the pipeline to be idle; not supported while enabled.

## 10. Decisions

1. Source: replayed recorded data at a chosen sample rate (pacer). Accepted by the student on the
   condition that the Li et al. evaluation did the same; to be confirmed against the paper text.
2. Windows: non-overlapping only (HOP = N_RAW). The HOP register stays in the design but is not used.
3. Memory: start from PS on-chip memory (OCM), which needs no DDR configuration. DDR only if a
   recording longer than 32768 time steps must be replayed.
4. Result handshake: acknowledge stall (R1), the simplest option.

## 11. Work plan

| Step | Content | Effort |
|---|---|---|
| A | `jrp_rt_ingest` RTL, `ext_start`, decoder target, `tb_rt_ingest`, board core sim | 2 to 3 days |
| B | PS + DMA block design, implementation, timing | 1 to 2 days |
| C | Bare-metal app, data loading, first hardware windows | 2 days |
| D | Streaming golden export, rate sweep, soak, report | 2 days |

## 12. Implementation status (step A)

Built and simulated, not yet on the board:
- `rtl/jrp_rt_ingest.v`: ring FIFO (65-bit entries: {gap, y, x}), frame sequencer, pacer, register block (section 4.6),
  interrupt. Drain rate is one beat per 3 cycles (about 12k cycles per N = 4096 window, 0.1 ms; irrelevant against the scan).
- `rtl/jrp_top.v`: new ports `ext_start`, `frame_busy`, `frame_done_pulse`, `frame_cfg_err`, `n_raw_o`. Tie `ext_start` low
  to keep the old AXI-Lite start. `jrp_board_core` and `tb_jrp_top` updated; K=1 and K=2 paths unchanged.
- `rtl/jrp_rt_core.v`: GENERATED by `scripts/derive_rt_core.py` from `jrp_board_core.v`. Same register map, target 3
  (0x60000) is the ingest block, AXI-Stream slave for the DMA, `irq` output.
- Tests: `tb/tb_rt_ingest.sv` (`scripts/sim_rt_ingest.ps1`) with a behavioural jrp_top model, and `tb/tb_rt_core.sv`
  (`scripts/sim_rt_core.ps1`) with the real core.
- Not done: PS and DMA block design, bare-metal software, streaming golden export, hardware run (steps B to D).
- Window gap flag: a sample stored after a discarded one carries a gap bit through the ring; a window whose second
  or later sample has the bit is flagged. Exact, no timing assumptions.
- Host rule: write N_RAW and the other control registers, then `RT.CTRL = enable`. Do not write the control START bit.
  After each result read the counters, then write `RT.CTRL = enable | ACK`.

## 13. Hardware result (steps B and C, JTAG-driven)

Bitstream `build/jrp_rt_board.xsa` (K = 2, 150 MHz): PS clock only, AXI DMA (MM2S, 64 bit, simple register mode) reading PS on-chip memory
through S_AXI_LPD, `jrp_rt_core` with the ring FIFO and frame sequencer. Setup WNS +0.908 ns, hold +0.011 ns, 12,291 LUT, 64.5 BRAM36,
36 URAM, 99 DSP (reports/rt_board_{timing,utilization}.rpt).

Test: `gen_rt_stream.py` (6 consecutive N_RAW = 4096 windows of a SYNTHETIC Lorenz x/z recording, m = 3, tau = 2, one fixed eps2 per channel,
distinct counters per window), samples written to OCM with `hw_ocm_load.tcl`, one DMA transfer of 196,608 bytes, sequencer enabled,
no START write and no sample feeder. `hw_rt_run.tcl` reads each result over JTAG-AXI, compares all 7 counters and every histogram bin
up to max(l_max, v_max) + 1, then acknowledges.

Result: 6 of 6 windows exact, DMA finished with no error bits, FRAMES_DONE 6, DROPPED 0, no gap frames, measured clock 149.99 MHz.
First result 65 ms after the DMA start (4096 samples ingested at full speed, then the 55.7 ms scan).

Not shown by this test: a rate sweep. The host reads the histograms over JTAG, which takes about 0.8 s per window, so the acknowledge
(section 4.5) arrives far later than the 55.7 ms scan, and the ring simply sits full (OCC_MAX 8192) with the DMA stalled. The ready-to-result
time of 858 ms in the log is that host delay, not the hardware. A paced rate test needs a fast acknowledge: PS software (bare-metal A53 reading
the counters over the LPD master port, microseconds per read) or shadow registers (decision 4 alternative).

## 14. Steady-state rate test (2026-10-30, bare-metal app `sw/rt_soak.elf`, K = 2, 150 MHz, N = 4096)

The 6-window stream is replayed for 300 to 1000 windows per rate; result k must equal golden window (k mod 6). The ring is emptied
between runs (let the transfer in flight finish, consume and acknowledge the windows, top up a partial window; a first version reset
the DMA mid-transfer, left it busy and misaligned the following runs, which was found with per-result window ids and ring occupancy
logging).

| Rate | Windows | Dropped | Ring peak | Result |
|---|---|---|---|---|
| 60 kHz | 1000 | 0 | 4100 | all exact |
| 65.2, 68.2, 71.4 kHz | 500 each | 0 | 4101 | all exact |
| 73.2 kHz | 500 | 686 (first at window 267) | 8192 | first 269 exact |
| 75.0 kHz | 500 | 49,032 (34) | 8192 | first 37 exact |
| 78.9 kHz | 500 | 159,319 (12) | 8192 | first 15 exact |
| 83.3 kHz | 500 | 282,091 (7) | 8192 | first 9 exact |
| full speed, backpressure | 300 | 0 | 8192 | all exact, 56.19 ms per window = 72.9 kHz |

Model: frame cycle seen by the sequencer = 8,400,922 (start to result) + about 27,600 (read and acknowledge by the program)
= 8.4286 M cycles = 56.19 ms. Backlog growth per window = cycle x fs - 4096 (15.5, 118, 340, 587 samples at 73.2, 75.0, 78.9, 83.3 kHz);
predicted first overflow after 264, 35, 12, 7 windows from a peak of 4101; observed 267, 34, 12, 7. Sustained limit 72.9 kHz
(73.1 kHz with a zero-time acknowledge). The first sweep's 73.2 kHz "no drop" figure was an artefact of the clean-up fault and is superseded.

## 15. m up to 10 build (2026-11-02): `build/jrp_rt_board_m10.xsa`

Same design as section 13/14 with `MAX_M = 10` (`build_rt_board.tcl -tclargs build 150 2 10`, separate project and `_m10` outputs; the m <= 6 build and its xsa are untouched).
Post-route, XCZU5EV, 150 MHz: 17,591 LUT (15 %), 24,330 FF, 64.5 BRAM tiles, 60 URAM (94 %), 163 DSP, setup WNS +0.890 ns, hold +0.011 ns.
The extra URAM is the wider vector memory: 320 bits x 8192 = 10 URAM per copy x 6 copies. No URAM margin is left for a larger N_MAX or K.

Simulation (MAX_M = 10, K = 2, `sim_rt_core.ps1 -MaxM 10`): `edge_max_embedding`, `jrp_mixedparams_small`, `edge_m1_tau1`, `bench_harmonic_small`, 3 windows each, exact.
Board (loaded with `hw_load.tcl xsa_rt_m10`, DMA path, `hw_rt_run.tcl`): `edge_max_embedding` (m = 10, tau = 16) x3, `jrp_mixedparams_small` x3, `edge_m1_tau1` x3,
`edge_saturation` x2, `bench_uwn_small` x3, `jrp_coupled_c0.3_small` x3, `bench_lorenz_x_full` x2 (N = 4096): all windows exact, 0 errors, clock 149.5 to 150.1 MHz.
Bare-metal rate sweep (`rt_app.elf`): identical to the m <= 6 build: exact at 0 (backpressure), 25, 50, 68, 83 kHz with no drops, overrun at 125 and 250 kHz.
The frame time does not depend on m (8,360,344 cycles). Note: the `ready-to-result` line printed by `hw_rt_run.tcl` reads the 64-bit timestamps non-atomically over JTAG and is unreliable; use the bare-metal log.

## 16. Insect data and independence baseline on the board (2026-11-02, m <= 10 build)

Data: `Capstone/cops_iridomyrmex.mat` (four separate 12 kHz recordings of 2,097,152 samples; `purpureus_wild` is a 0..1 ramp and is not used). Scripts: `Phase1/scripts/prepare_cops_pairs.py`,
`export_insect_golden.py ... --hw-max-m 10`, `Phase3/scripts/gen_rt_case.py`, `hw_rt_run.tcl`, `insect_report.py`.

Insect pairs (N = 4096 from 5.0 s, eps = 10 % of max distance, per-channel AMI/FNN): Darwin x lab ant (m,tau) (10,1)/(5,4); Griffith x lab ant (10,1)/(5,4); Darwin x Griffith (10,1)/(10,1).
All three: board counters and histograms = integer model, six metrics = float64 reference to six figures. Reports: `reports/insect_insect_*.md`.

Independence baseline: `scripts/gen_null_set.py` (random pairings, N = 1024, fixed 10 % single-channel recurrence rate), `sw/null_main.c` (`sw/build_null.ps1`, `scripts/hw_null_run.tcl`), `scripts/analyse_null.py`.
3 runs per pairing (joint, x only, y only). 288 pairings, 864 board runs of 3.5 ms: every count equal to the model. JRR/(RRx RRy): median 1.006 / 1.000 / 1.017 (Darwin-lab / Griffith-lab / Darwin-Griffith),
95 % range about 0.83 to 1.30. `reports/null_baseline.md`.
