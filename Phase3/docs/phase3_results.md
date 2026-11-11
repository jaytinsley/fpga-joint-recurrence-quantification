# Phase 3: results

Implements `Phase1/docs/phase2_architecture.md`. Everything below was run on this machine with
Vivado 2026.1 (xsim for simulation, out-of-context synthesis and place-and-route for the XCZU4EV).
Not run on hardware: timing is from the routed design, not from a board.

## 1. What was built

| Module | Origin |
|---|---|
| `jrp_top` | new |
| `jrp_pair_gen`, `jrp_lane`, `jrp_scan_engine` | new: one pair per cycle over the full N x N grid, two distance units and an AND |
| `jrp_axi_regs` | derived from `axi_lite_regs` (y-channel registers, alignment bases, read-back, error bits) |
| `jrp_psr` | replaces `phase_space_reconstruction` (finding 2) |
| `jrp_vector_buffer` | derived from `vector_buffer` (finding 1) |
| `jrp_rqa_extractor`, `jrp_rqa_extractor_axi` | generated from the released extractor by `scripts/derive_extractor.py` (findings 3, 5) |
| `jrp_tdp_bram_fw` | replaces `tdp_bram_fw` (finding 5) |
| `distance_threshold_calculation`, `axi_perf_mon` | released, unchanged |

## 2. Verification against the Phase 1 golden vectors

All comparisons are on integers produced by the Phase 1 model of the RTL; nothing is compared with
a tolerance.

| Level | What | Result |
|---|---|---|
| Embedding block, N = 4096 | every vector against the definition, m = 1 to 10, tau up to 16 | pass (released block: fails) |
| Scan engine | every pair flag in order, 13 golden cases (single channel, coupled, mixed m/tau/eps, five edge cases incl. m = 10 and saturation), plus a delayed start | 13 of 13 pass; one flag per cycle; latency 10 cycles |
| Scan engine + extractor | 7 counters and both 8192-bin histograms over AXI-Lite, 13 cases | 13 of 13 pass with the derived extractor; the released extractor fails 12 of 13 |
| Whole `jrp_top`, small cases | registers and sample stream in, counters and histograms out, 13 cases | 13 of 13 pass |
| Whole `jrp_top`, N = 4096 | 6 cases, 16,679,056 pairs each | 6 of 6 pass |

Frame time for N = 4096 (4084 joint vectors): 16,720,264 cycles from START to metrics valid, which is
the 16,679,056-pair scan plus the 16,384-cycle histogram clear plus about 24,800 cycles of embedding
and finalisation (111 ms at 150 MHz). Matches the Phase 2 estimate of 112.1 ms for the pipelined full
scan at K = 1.

## 3. Resources and timing (routed, XCZU4EV, 150 MHz target)

| | Phase 2 estimate | Synthesis, first design | Routed, final |
|---|---|---|---|
| LUTs | not estimated (risk: above 90 %) | 27,457 (31 %) | 7,758 (8.8 %) |
| URAM | 24 (50 %) | 24 | 24 (50 %) |
| DSP | 54 | 51 | 51 (7 %) |
| Block RAM tiles | not estimated | 15 | 37 (29 %) |
| Flip-flops | not estimated | 10,597 | 10,098 (5.8 %) |
| Setup slack at 6.667 ns | | +2.44 (synthesis estimate) | +0.322 ns |
| Hold slack | | | +0.020 ns |
| Estimated Fmax | | | about 157 MHz |

Routing is clean (no failing endpoints, no routing errors). The critical path is now the block RAM
read into the extractor counters. The margin is thin (0.32 ns), so any added logic on the extractor
counters needs a re-check. The released single-channel top synthesises to 32,368 LUTs, 20 URAM, 46 DSP
(URAM and DSP match the paper's Table 1).

## 4. Findings in the released RTL

The released files are untouched; each fix is a separate module. Whether the published hardware had the
same behaviour is unknown, and is a question for the authors.

1. **`vector_buffer`: read valid is one cycle later than the data.** Hidden by the released
   orchestrator, which issues one read and waits. Breaks any pipelined use.
2. **`phase_space_reconstruction` corrupts vectors after its history buffer wraps.** The depth
   (MAX_M - 1) * MAX_TAU is 144 in the released top level, not a power of two, but the read address is
   plain subtraction modulo 2^PTRW. 728 of 4084 vectors are undefined at N = 4096. Inputs shorter than
   144 samples never wrap.
3. **The extractor drops histogram events at one flag per cycle.** The DET histogram update is a
   4-cycle read-modify-write behind a 2-entry queue that overwrites when full; the overflow counters never
   count. The integer counters stay right, the histograms (and ENTR) do not. 12 of 13 golden cases fail.
4. **`HIST_W = 14` saturates every histogram bin at 16,383.** Invisible on small inputs and on signals
   with few lines; wrong for any noisy or chaotic signal at N = 4096 (the UWN signal has 936,715 diagonal
   lines of length 2). The RAM words are already 32 bits wide, so the fix is the parameter: `HIST_W = 32`.
5. **The state memories do not map to block RAM.** The released `tdp_bram_fw` allows two write and two
   read ports with cross-port bypass; Vivado reports the `block` attribute infeasible and builds
   15,360 LUTs of distributed RAM, which was also the critical timing path (98 % routing delay).
6. **The released testbenches are not a regression suite:** one no longer elaborates, one only prints.

The released PSR bug (2) and the saturation (4) mean the released source cannot reproduce correct
N = 4096 metrics with ENTR, yet the paper reports Python-level agreement. Either the published
bitstream came from a different revision, or those results were not produced with this source.

## 5. Open items

- Run on the board: nothing here has executed on hardware. Timing is a routed estimate.
- Optional pass 0 (exact percent-of-max-distance eps, decision D4 option A) is not implemented. The
  register bits (`CFG[2]`, `MAXD2_X/Y`) are reserved and read as zero. The streaming mode (PS writes
  `EPS2_X/Y`) works.
- K = 2 lanes (decision D8) not attempted; the critical path margin is 0.32 ns at K = 1.
- Insect recording pair: still waiting for the dataset (Phase 1 open item).
- `soft_reset_pulse` is decoded but not wired, as in the released top level.
- Not tested: a back-pressured sample stream (`tvalid` gaps are exercised only by the 1-beat-per-cycle
  driver), simultaneous AXI-Lite access during a scan, and two frames back to back.
- `axi_perf_mon` is connected but its counters are not checked.
- Ask Li or Oberst: which RTL revision produced the published results (findings 2 to 4).

## 6. Comparison with the published paper (Eur. Phys. J. Spec. Top. 2026, doi 10.1140/epjs/s11734-026-02434-4)

Read after Phase 3. Open access, CC BY 4.0.

| Topic | Paper | This project |
|---|---|---|
| Scan | definitions use the full N x N matrix; timing model Eq. 14 uses N(N-1)/2 and the measured 55 ms (N = 4096) and 225 ms (N = 8192) match N(N-1)/2 at 150 MHz | full N x N: 111.5 ms at N = 4096, K = 1; K = 2 would match the paper's timing |
| RR, DET, LAM | RR = (1/N^2) sum R; DET and LAM divided by sum R; no exclusion of the main diagonal or of a triangle is mentioned | `rtl` convention (diagonal excluded). The paper's reported FPGA errors (DET below 1.2e-4, LAM below 4.0e-5) are smaller than the roughly 2.5e-4 this convention differs by, so the published hardware probably counted like Python |
| eps | eps^2 programmed through AXI-Lite; swept as 10 to 90 % of the maximum embedded distance | same; the paper does not say how the maximum distance is obtained |
| Embedding buffer | depth m*tau, read address (wptr - k*tau) mod (m*tau) (Eq. 10, B2), with a worked wrap example | the released RTL has no modulo, so it does not implement the paper's own equation (finding 2); `jrp_psr` follows the equation's behaviour |
| Histograms | in BRAM or URAM; counter width and saturation not stated | released `HIST_W = 14` saturates; `jrp_top` uses 32 (finding 4) |
| Table 1 | 40,397 LUT (46 %), 24,701 LUTRAM (43 %), 20 URAM (41.7 %); DSP and BRAM low | released top synthesises to 32,368 LUT, 15,360 LUTRAM, 20 URAM; new design 7,758 LUT, 24 URAM, 51 DSP, 37 BRAM |
| Parallel lanes | K_max = 2 from min(57,600/24,701, 48/20, 87,840/40,397); K = 2 halves the runtime | K = 1 built; a second lane would double URAM with the current mirrored memories |
| Multi-bank memory | K banks, each holding distinct embedding components | not the released RTL (single lane, two mirrored copies) |
| Benchmark settings | N up to 8192, m = 5, tau = 3, lmin = vmin = 2, 4 signals, 30 logistic realisations | same |
| Power | 3.539 W on-chip (Vivado estimate), 0.79 J per run at N = 8192; CPU 41.48 J | not measured here |

Fixed-point format, maximum embedding dimension and delay, and how the maximum distance is found are
not stated in the text. The paper's Zenodo record (10.5281/zenodo.20406392) is the released source
studied here; the paper's own results and that source disagree on the points above.

## 7. Hardware results (ALINX AXU5EVB-P V2.0, XCZU5EV-2I)

Run on 2026-10-28 through the Vivado JTAG-to-AXI master (ALINX AL321 cable), boot mode JTAG, PS initialised
with the generated `psu_init` (clock only, DDR and peripherals off), PL loaded with `build/jrp_board.bit`
(volatile, nothing written to flash). Design: `jrp_board_core` = `jrp_top` + sample feeder + clock counter,
MAX_M = 6, PL clock 96.97 MHz requested 100 MHz (measured 96.7 to 97.2 MHz against wall-clock time; this
confirms the 33.333 MHz PS reference clock). Routed on the part: 9,075 LUT, 54 BRAM, 24 URAM, 51 DSP,
setup slack +1.63 ns, hold +0.013 ns.

| Run | Result |
|---|---|
| Small golden cases, 12 runnable, original order | 12 of 12 pass |
| Small golden cases, reverse order | 12 of 12 pass |
| Full-length N = 4096 cases (16,679,056 pairs each), 6 | 6 of 6 pass |
| `edge_max_embedding` (m = 10) | not run: this bitstream is MAX_M = 6 |

"Pass" means the 7 integer counters, `cells_accepted` and every histogram bin up to max(l_max, v_max) + 1
equal the Phase 1 golden values (bins above that are zero by construction).

Cycle counts read from the hardware performance monitor equal the simulation exactly: for a 116-vector case,
scan start to last pair 29,843, to last flag 29,851, flags to metrics valid 581. A full N = 4096 case
takes 172.2 to 172.4 ms from scan start to metrics valid at the measured clock, which is 111.44 ms at
150 MHz (16,715,850 cycles including the 16,384-cycle histogram clear). The simulation figure was 111.5 ms.
The `T_START` stamp is written by a separate host JTAG transaction, so start-to-scan-start and the
performance monitor total include host latency (about 4.5 ms); use scan start to metrics valid.

### Finding 7 (found on the board): the released final column sweep clears the wrong column

On hardware the case `edge_m1_tau1` failed when run after other cases: vertical-line counters were off by
one extra line of length 18 (`lam_points` 65 against 47, `lam_lines` 23 against 22, `v_max` 18 against 3,
one extra count in LAM histogram bin 18). Every single-frame simulation passed, because a simulation starts
with empty memories. Reproduced in simulation by running the same cases back to back
(`scripts/sim_board_multi.ps1`).

Cause: the released `RQA_extractor_nobitmap.v` final sweep reads column j, but the state RAM returns that data
one cycle after the address register is loaded, and the sweep clears `finalize_j_prev`, which is already
the next column. Open runs are therefore left in the column state memory (clears landed on columns 57, 64, 82
when columns 56, 63, 81 were open). The counters of the frame are still right (they use the data), but a later
frame that uses the same frame ID and is longer than the frame in between, as the IDs alternate, finds stale
open runs and closes and counts them. The same bug exists with the released state memory, so it is a property
of the released extractor, not of the replacement RAM.

Fix, in the derived extractor: clear the address whose data is being used (`lam_raddr_d`, the address register
delayed by one cycle). Checked by a 36-frame back-to-back stress run in simulation (zero errors), the 13-case
simulation regression (all pass, identical cycle counts) and the hardware runs above.

### Reproducing the hardware runs

1. Boot mode JTAG (SW1 = 0000), board powered, cable connected. Read-only check: `xsdb scripts/hw_bootmode.tcl`.
2. Load (volatile): from `Phase3/build`, `xsdb ../scripts/hw_load.tcl` (checks the boot pins first).
3. One case: `python scripts/gen_hw_case.py <case>`, then `vivado -mode batch -source ../scripts/hw_axi_run.tcl
   -tclargs <case>` from `build`. All cases: `scripts/run_all_hw.ps1 [-Small] [-Full] [-Reverse]`.
4. The block design and bitstream: `vivado -mode batch -source ../scripts/build_board.tcl -tclargs bd 100`, then
   `... -tclargs build 100` (about an hour).

### Still open after the hardware runs

- m = 10 on hardware needs a MAX_M = 10 bitstream (the case passes in simulation).
- The design runs at about 97 MHz here. Timing closes at 150 MHz on this part in the out-of-context run
  (+0.60 ns), but a 150 MHz board build and run has not been done.
- Samples come from an on-chip RAM filled over JTAG; the PS plus AXI-DMA path (the real Phase 4 architecture)
  is not built. This design has no DDR, so the board's SD-card Linux image is not used.
- Power was not measured.

### 150 MHz board build (built, not yet run on the board)

Same design with the PS asked for 150 MHz: the PS produces 149.9985 MHz (VCO 1500 MHz divided by 10). Full board
system (PS, JTAG-to-AXI master, `jrp_board_core`) on the XCZU5EV-2I: setup slack +0.619 ns at 6.667 ns, hold
+0.013 ns, no failing endpoints, 9,095 LUT, 54 BRAM, 24 URAM, 51 DSP. Estimated Fmax about 165 MHz. Critical path:
the DET state memory (a 16,384-deep memory spread over cascaded RAMB36 blocks) into the `det_lines` counter
enable (17 logic levels, 7 of them the RAM cascade). Saved as `build/jrp_board_150mhz.xsa` (reports
`board150_timing.rpt`, `board150_utilization.rpt`). A full N = 4096 frame is 16,715,850 cycles = 111.4 ms at this clock.
Running it on the board is the remaining step (load with `hw_load.tcl` after unpacking this XSA into `build/xsa`).

### 150 MHz run on the board (2026-10-29)

`build/jrp_board_150mhz.xsa` loaded and run: measured PL clock 150.00 MHz (150.0 to 150.4 MHz across runs, against
wall-clock time). 30 of 30 runs pass: 12 small cases in each of two orders and the 6 full-length N = 4096 cases
(`edge_max_embedding` skipped, MAX_M = 6), counters and histograms bit-exact against the golden vectors.
Measured scan phase (scan start to metrics valid) for a full N = 4096 frame, 16,679,056 pairs: 111.3 to 111.4 ms,
the same 16,715,850 cycles as before, now at 150 MHz. A 116-vector case takes 0.203 ms. Compared with the paper's
single-channel figure of about 55 ms at N = 4096 (N(N-1)/2 pairs at K = 1), this design is 2.0x slower because it
scans the full N x N matrix on one lane; K = 2 would match it. Logs: `build/hw150_*.log`.

## 8. K = 2: two cells per cycle (matches the paper's timing)

`jrp_top` has a parameter `K` (default 1). `K = 2` evaluates the two adjacent cells (i, j0) and (i, j0 + 1) of a row
in every cycle, so the full N x N grid (decision D1 unchanged) takes ceil(N/2) x N cycles.

| Block | K = 2 design |
|---|---|
| `jrp_pair_gen_k2` | beat = (i, j0 even, valid1); one beat per cycle; one beat per 2 cycles when n <= 2 |
| `jrp_vector_buffer3` | third read port: A = row vector i, B = j0, C = j0 + 1 (three mirrored URAM copies per channel) |
| `jrp_scan_engine_k2` | two `jrp_lane` (4 distance units); beat `{i, j0, f1, f0, v1}` |
| `jrp_rqa_extractor_k2` (+ `_axi`, generated by `derive_extractor_k2_axi.py`) | see below |

Extractor: the two cells of a beat never share a column or a diagonal, so the state memories are banked by parity:
columns A (even j) and B (odd j); diagonals d = j - i - 1, bank d[0], address d >> 1 (which cell uses which diagonal
bank alternates with the parity of j0 - i). One read-modify-write per bank per cycle. The per-cell run logic is the
released one, written once as `jrp_run_cell`. DET and LAM histograms are held twice (one RAM per lane,
`jrp_hist_unit`); a host read returns the sum. Other changes versus the K = 1 extractor: final sweeps are pipelined
(about 2N cycles instead of about 4N), the four histogram RAMs are cleared in parallel (8,192 cycles instead of 16,384),
events are registered before the counters, and the diagonal state RAM is half the size (d >= 0 only).
Limit: dependent beats must be at least 2 apart, which holds for n >= 3; n <= 2 is handled by the pair generator.

Verification (simulation, bit-exact against the Phase 1 integer model):
- extractor alone, 154 random recurrence matrices (n = 1 to 12, 17 to 129; iid, random walk, bands, all ones, none,
  asymmetric), back to back in one run, also with random idle cycles between beats: 0 failures
- whole `jrp_top` K = 2, 13 small golden cases (incl. m = 10): all pass
- `jrp_board_core` K = 2, 12 frames back to back including `edge_m1_tau1` four times (finding 7 pattern): 0 errors
- full-length N = 4096, six golden cases through `jrp_top` K = 2: 6 of 6 pass, all 8,360,344 cycles

Frame time (start to metrics valid): 8,360,344 cycles = 55.7 ms at 150 MHz (K = 1: 16,715,850 = 111.4 ms). The paper
reports about 55 ms at N = 4096, 150 MHz.

Out-of-context implementation on the XCZU5EV-2 at 150 MHz: 9,571 LUT, 12,764 FF, 46 BRAM, 36 URAM, 99 DSP,
WNS +1.33 ns, hold +0.021 ns (K = 1: 7,758 LUT, 24 URAM, 51 DSP).

K = 2 board build (AXU5EVB-P, 150 MHz, saved as `build/jrp_board_k2_150mhz.xsa`, reports `reports/board_k2_*.rpt`):
10,978 LUT, 63 BRAM, 36 URAM, 99 DSP, setup WNS +0.455 ns, hold +0.011 ns. Not yet run on the board.
Run: `xsdb hw_load.tcl` from `build` after unpacking the xsa into `build/xsa`, then `run_all_hw.ps1 -Small`, `-Small -Reverse`, `-Full`.
