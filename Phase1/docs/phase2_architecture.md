# Phase 2: architecture specification for the dual-channel JRP

Status: decisions D1 to D8 signed off by Jay on 2026-10-20 (summary in section 11); Phase 3 implemented it (section 12 lists what changed). Author: Jay Tinsley (with Claude). Inputs: the Phase 1 golden
reference (this repository), the Li, Lai and Oberst RTL (Zenodo 10.5281/zenodo.20406392,
v2.0) and the v1 preprint (doi:10.21203/rs.3.rs-8760281/v1).

Evidence labels used below: **[RTL]** read from the released source, not simulated;
**[paper]** stated in the v1 preprint; **[P1]** established by a Phase 1 test or script;
**[est]** an estimate with a stated assumption (A1 to A5, section 8). Nothing marked
[est] has been measured on hardware.

## 1. Scope

Extend the single-channel streaming RP/RQA design to two simultaneously sampled channels, so
that it computes the joint recurrence plot

    JR(i, j) = Theta(eps_x - ||x_i - x_j||) * Theta(eps_y - ||y_i - y_j||)

and the JRQA metrics JRR, JDET, JLAM, Lmax, Vmax, ENTR without storing the recurrence matrix,
with deterministic latency, on a Zynq UltraScale+ XCZU4EV at 150 MHz. This document fixes the
PS/PL split, the interfaces, the cycle and resource budgets and the verification plan, and lists
the decisions that must be made before RTL work (Phase 3) starts.

Key conclusion: the JRP changes only the front half of the pipeline. The flag stream
`{i, j, flag}` that the RQA extractor consumes keeps its format, so the extractor is reused
unchanged (section 5.5), and the largest new cost is a second vector memory and a second
distance unit. The scan stays the full N x N grid of the released RTL (D1).

## 2. What the released single-channel design is

Reading the source shows the released RTL and the paper describe different machines. This
matters because the JRP must be specified against the one we can actually verify.

| # | Observation | Source |
|---|---|---|
| O1 | Two-phase operation: ingest all N samples into a vector memory, then scan pairs. Not a sliding window. | [RTL] `RPs_bruteforce.v` |
| O2 | Vector memory: two mirrored URAM copies (one per read port), 32 x MAX_M bits wide, N_MAX = 8192 deep. 20 URAM, matching Table 1 of the paper exactly. | [RTL], [paper], [P1] `phase2_budget.py` |
| O3 | Pair order: full N x N grid, i outer, j inner, including i = j (`grid_index_gen.v`). `cells_target = N*N`. | [RTL] |
| O4 | The compare orchestrator handles one pair at a time through a state machine: issue read, wait for the memory (about 3 cycles), run the distance unit (about 4 cycles), hand off. Roughly 10 to 12 cycles per pair, one lane. | [RTL], [est] A2 |
| O5 | The paper states one comparison per lane per cycle and `T_cmp = N(N-1)/(2 K f eta)`, i.e. the upper triangle only. At N = 8192 and 150 MHz that is 223.7 ms, matching the paper's reported 225 ms. The released RTL has no K parameter and would need about 4.9 s [est]. The paper's timing therefore comes from a pipelined, multi-lane design that is not in the release. This reading of the paper's formula was not re-checked against its full text (see D1). | [paper, unverified], [RTL], [P1] |
| O6 | Distance unit: exact integer arithmetic on Q8.24. `sum_k (a_k - b_k)^2 <= eps2 << 24`, where `eps2` is eps squared as an unsigned Q8.24 integer. No rounding anywhere. | [RTL], reproduced bit-exactly in [P1] `fixedpoint.py` |
| O7 | Embedding block: vector t is `[x[t], x[t-tau], ..., x[t-(m-1)tau]]`, newest sample first, first vector once (m-1)tau samples have arrived. MAX_M = 10, MAX_TAU = 16 in the top level instance. | [RTL] |
| O8 | Extractor counting: the cell (i, i) is non-recurrent everywhere. It is excluded from `rr_count` and breaks vertical lines. DET counts the strict upper triangle only (lines in the lower triangle are not counted). | [RTL] |
| O9 | Extractor outputs integers only: `rr_count`, `det_points`, `det_lines`, `l_max`, `lam_points`, `lam_lines`, `v_max`, plus DET and LAM histograms (bin = min(length, 8191)). All ratios are formed on the host. | [RTL] |
| O10 | The extractor clears both histograms (2 x 8192 cycles) at every frame start, and finalises with a column sweep (N cycles) and a diagonal sweep (about 5 cycles per diagonal). | [RTL], [est] A4 |
| O11 | The paper defines RR = (1/N^2) sum R_ij and DET, LAM over the total recurrence count, with no mention of excluding the main diagonal. The v1 hardware errors versus Python (DET below 2e-4, LAM below 4e-5) are also smaller than the O8 convention would give (LAM off by about 2e-4), so the hardware behind v1 probably counted the diagonal. The v2 spreadsheet matches Python to 1e-16. Which RTL produced it is unconfirmed. | [paper], [P1] |

Consequence for this project: **the specification below targets the v2 RTL behaviour (O8),
with the paper's performance model (O5).** The counting convention is the `rtl` mode of
`jrp.rqa.rqa_metrics`, with RR = rr_count / N^2.

## 3. Requirements

| ID | Requirement |
|---|---|
| R1 | Compute JR exactly (bit-exact flags against the Q8.24 golden model) for two channels with independent m, tau and eps. |
| R2 | JRQA counters bit-exact against `jrp.rqa.rtl_counters` for every golden case. |
| R3 | No N x N storage. State is O(N). |
| R4 | Deterministic latency: cycle count a function of N, m, tau, K only. |
| R5 | N up to 8192 vectors, m up to MAX_M, tau up to 16, at 150 MHz. |
| R6 | Fit the XCZU4EV with margin (target: URAM <= 60 %, LUT <= 80 %). |
| R7 | PS side stays simple: no per-pair work on the ARM cores. |
| R8 | Q8.24 metric error against float64 at most 1e-4 (met in [P1]: worst case 3.4e-5, ENTR). |

## 4. Architecture

![Dual-channel JRP architecture](../results/figures/phase2_architecture.png)

Figure: `results/figures/phase2_architecture.pdf` (generated by `scripts/phase2_figure.py`).
Green blocks are reused from the single-channel design, orange blocks are new or modified.

Data flow per frame:

1. **Ingest.** The PS writes `{y, x}` sample pairs (Q8.24, 64 bits per beat) to DDR and starts an
   AXI-DMA MM2S transfer. Each channel has its own embedding block (m, tau). Vectors are written
   to that channel's vector memory.
2. **Alignment.** Both memories hold vectors indexed by the time of their newest sample. A pair
   (i, j) reads x vectors at `i + base_x` and y vectors at `i + base_y`; alignment is two base
   registers (D2).
3. **Scan.** The pair generator emits the full N x N grid, row-major (i outer, j inner), as the
   released `grid_index_gen.v` does. K lanes each evaluate both distance tests in parallel and AND
   the results into one flag.
4. **Extract.** The flag stream feeds the RQA extractor, which updates run trackers and
   histograms. After the last pair, a finalisation sweep closes open runs.
5. **Read out.** The PS reads the integer counters and the used part of the histograms over
   AXI-Lite and forms the metrics (section 7).

## 5. Decisions and module specification

Each decision lists a recommendation and the evidence behind it. D1 to D5 need your sign-off
before Phase 3.

### D1. Scan strategy: full N x N grid (decided)

Stream every cell (i, j), i outer, j inner, including i = j, exactly as `grid_index_gen.v` does
(`cells_target = N*N`, O3). Reasons: it matches the released RTL, which is the machine we can
verify; the extractor is reused unchanged; and it keeps the JRP directly comparable with the
single-channel design. The cost is twice the cycles of a half scan (112 ms against 56 ms at
N = 4096, K = 1, section 8.1).

Recorded alternative, not chosen. Because R is symmetric and the cell (j, j) is non-recurrent
under the `rtl` convention, a scan of the strict upper triangle can reproduce every counter
exactly: vertical-run statistics are the column runs plus the row runs inside the upper
triangle, and `rr_count` doubles on the host. `tests/test_rtl_counters.py` verifies this on 11
symmetric matrices (`rtl_counters(..., scan="upper")`). It would need one row-run counter in the
extractor and `cells_target = N(N-1)/2`. It is a candidate optimisation for a later phase if the
cycle count becomes the bottleneck; it does not apply under the `paper` counting convention.

What the published paper says (Li, Lai and Oberst, Eur. Phys. J. Spec. Top. 2026, doi
10.1140/epjs/s11734-026-02434-4, read in full after Phase 2): the definitions use the full matrix
(Eq. 1 and 2, "the total number of distance operations is N^2", "scanning the entire N x N
recurrence matrix"), but the timing model (Eq. 14) counts C = N(N-1)/2 comparisons, and the
reported runtimes match that count at 150 MHz: 55.9 ms at N = 4096 and 223.7 ms at N = 8192 against
the reported 55 ms and 225 ms. So the published timing corresponds to half the pairs per lane. The
decision above stands (it follows the definitions and the released RTL), with this consequence: at K = 1
this design takes 111.5 ms at N = 4096, twice the published figure; K = 2 on the full scan gives the
published timing. The paper's K = 2 bound (Eq. 13) comes from its LUT, LUTRAM and URAM use.

### D2. Channel alignment: base-index registers, default end-aligned (decided)

Because vectors are stored and read by index (O1), aligning two channels with different (m, tau)
costs nothing but two registers. With `n_x = N - (m_x-1) tau_x` and `n_y` likewise, the joint
length is `n = min(n_x, n_y)` and

| mode | base_x | base_y | matches |
|---|---|---|---|
| end (default) | n_x - n | n_y - n | RTL embedding order; Phase 1 default `align="end"` |
| start | 0 | 0 | pyunicorn (cross-checked in [P1]) |

When m and tau are equal on both channels the modes coincide. This removes the alignment risk
from the datapath.

### D3. Input interface: one 64-bit AXI-Stream beat per sample pair (decided)

Pack `{y[31:0], x[31:0]}` per beat from one AXI-DMA MM2S channel. This keeps the channels
simultaneous by construction and needs one DMA channel. At 150 MHz one beat per cycle is 1.2 GB/s,
within a ZynqMP HP port. The alternative (two streams, two DMA channels, a synchroniser) adds
logic and a failure mode for no benefit. `TLAST` marks the last pair; `TKEEP` is all ones.

### D4. Threshold source (eps): both modes (decided)

The paper and Phase 1 set eps per channel as a percentage of the maximum embedded distance, which
needs a pass over all pairs. Options:

| option | cost | consistency with paper |
|---|---|---|
| A. PL pass 0: the lanes track max d^2 for both channels in one extra scan | +N^2/K cycles on the full scan (112 ms at N = 4096, K = 1) | exact |
| B. PS bounding-box rule: eps = p/100 x sqrt(m) for [0, 1] signals | none | differs from paper (an upper bound on the true max distance) |
| C. PS rule from signal spread, e.g. a multiple of the standard deviation | none | differs from paper |

Decision: implement A as an optional mode (its datapath is a comparator and a register per
channel in each lane, enabled by `CFG[2]`), use it for benchmarking against Phase 1, and use B or C
in streaming operation, where the extra pass defeats the latency goal. The PS writes `EPS2_X` and
`EPS2_Y` in both cases.

### D5. Resource configuration: MAX_M = 6, N_MAX = 8192 (decided)

URAM is the binding resource. One vector memory copy needs `ceil(32 MAX_M / 72) x ceil(N_MAX / 4096)`
blocks, and each channel has two mirrored copies (O2). This formula reproduces the 20 URAM of
Table 1 for the released design [P1].

| channels | MAX_M | N_MAX | URAM (of 48) | DSP (of 728) [est A3] |
|---|---|---|---|---|
| 1 (released) | 10 | 8192 | 20 (42 %) | 46 |
| 2 | 10 | 8192 | 40 (83 %) | 86 |
| 2 | 8 | 8192 | 32 (67 %) | 70 |
| 2 | 6 | 8192 | 24 (50 %) | 54 |
| 2 | 6 | 4096 | 12 (25 %) | 54 |

Decision: MAX_M = 6, N_MAX = 8192 (24 of 48 URAM, 50 %; the benchmark uses m = 5; the insect data may
need more, to be confirmed with the dataset, in which case MAX_M = 8 costs 32 URAM). MAX_M = 10 leaves no headroom at 83 %. Full table:
`results/csv/phase2_resource_budget.csv`.

LUTs are the unquantified risk. The released design uses 40,397 of 87,840 (46 %) at K = 1,
and the preprint gives no per-module split. If everything doubled, a JRP would exceed 90 %.
Phase 3 task 0 must be an out-of-context synthesis of the released modules to get the split
(section 10).

### D6. Counting convention: `rtl` with RR = rr_count / N^2

Fixed by the evidence in O8 and O11. RR denominator is N^2 as in Eq. 2 of the paper; DET and LAM
divide by `rr_count`. The host-side formulas are in section 7. They are verified against the
full-matrix definition to 1e-12 in `tests/test_rtl_counters.py`.

### D7. Histogram handling (decided)

The released extractor clears 2 x 8192 histogram bins at each frame start (109 us, O10) and the PS
would read up to 16,384 words over AXI-Lite. Decision: clear while the PS reads the previous
frame's result (double buffer or clear-on-read), and have the PS read only bins up to
`max(l_max, v_max)`; most frames use a small fraction. Histogram readout time over AXI-Lite is
unmeasured (A5) and should be measured in Phase 4.

### D8. Clock and lanes (decided)

150 MHz as in the paper. K = 1 first; K = 2 only if synthesis shows timing and LUT headroom (the
paper's own bound was K <= 2 for the single-channel design). A JRP lane contains two distance
units, so K = 2 means four.

### 5.1 Embedding block (x2)

Reuse `phase_space_reconstruction.v` per channel, unchanged except for:
`MAX_TAU` must cover the largest tau used (the top level instance sets 16; the register is 8 bits).
Each instance counts its own samples. Vectors are written to its channel's vector memory by
write pointer, so the memory index equals the order in which that channel produced vectors, with
vector 0 at sample (m-1) tau. Component order is newest first (O7); distances do not depend on it.

### 5.2 Vector memory (x2)

Reuse `vector_buffer.v` per channel (two mirrored URAM copies, two read ports, read latency 2).
The pair generator presents `i + base`, `j + base` to each memory.

### 5.3 Pair generator

Keep the order of `grid_index_gen.v` (i outer, j inner over the full n x n grid) and extend it to
emit K consecutive pairs per cycle for K lanes (K = 1 first, D8). The released module hands over one
pair per handshake; the new one streams without a per-pair handshake, as the pipelined orchestrator
(5.4) requires. Registers: `n`, `base_x`, `base_y`. The `N_BITS = 14` index limit allows n up to
16,384 (N_MAX is the real limit).

### 5.4 Lane: two distance units and an AND

Per lane, instantiate `distance_threshold_calculation.v` twice with separate `eps2` and `m_active`
and AND the two `rec_flag` outputs, with the shorter pipeline delayed to match. Both units are
fully pipelined (about 4 stages), so a lane accepts one pair per cycle. The released
orchestrator must be replaced by a pipelined one (O4, O5): issue reads every cycle, carry the `(i, j)`
tag through the read and compare latency in a shift register, and apply backpressure from the
extractor with a small FIFO rather than a handshake per pair. Flag format `{i, j, flag}` is unchanged.
Lanes write to the extractor through an arbiter that preserves row-major order within a row.

### 5.5 RQA extractor

Reuse `RQA_extractor_nobitmap.v` unchanged. With the full scan (D1) it already does what the JRP
needs: it ignores i = j for RR and LAM, counts DET on the strict upper triangle only, keeps one run
tracker per column and per diagonal, and finalises with a column sweep and a diagonal sweep (O8,
O10). The JRP only changes which flags arrive. Counter semantics are those of the released RTL:
`rr_count` = off-diagonal recurrences (both triangles), `det_*` from the upper triangle, `lam_*` from
all columns.

## 6. Interfaces

### 6.1 AXI-Stream (samples)

64-bit `TDATA = {y, x}`, each a signed Q8.24 value; `TVALID/TREADY/TLAST`. The PS normalises each
channel to [0, 1] before conversion, so values never approach the +-128 range limit. A saturation
in either channel is a PS-side error (the PS counts and reports it; the golden case
`edge_saturation` exercises the logging).

### 6.2 AXI-Lite control block (12-bit address, existing map plus additions)

| offset | name | access | existing / new |
|---|---|---|---|
| 0x000 | CONTROL: [0] start, [1] reset (a [8] frame_end bit is documented in the source comment but not decoded; the end of ingest comes from the embedding block) | W1P | existing |
| 0x004 | STATUS: [0] psr_in_ready, [1] ing_busy, [2] scan_busy, [3] metrics_valid | R | existing |
| 0x008 | N_RAW (samples per channel) | W | existing |
| 0x00C | M_X | W | existing (MDIM) |
| 0x010 | TAU_X | W | existing (TAU) |
| 0x014 | EPS2_X (Q8.24 of eps_x^2) | W | existing (EPS2) |
| 0x018 | LMIN | W | existing |
| 0x01C | VMIN | W | existing |
| 0x020 | N_ACTUAL (vectors) | R | existing |
| 0x024 | M_Y | W | new |
| 0x028 | TAU_Y | W | new |
| 0x02C | EPS2_Y | W | new |
| 0x030 | CFG: [0] reserved (scan_upper, not implemented, see D1), [1] align_start, [2] pass0_max_distance | W | new |
| 0x034 | BASE_X (vector index offset) | W | new |
| 0x038 | BASE_Y | W | new |
| 0x03C | N_JOINT (vectors per channel after alignment) | W | new |
| 0x040 | MAXD2_X (pass 0 result, if D4 option A) | R | new |
| 0x044 | MAXD2_Y | R | new |
| 0x048 | ID / version | R | new |

Note the released block returns 0 for every readable address except STATUS and N_ACTUAL; the
new read-back of configuration registers is useful for driver self-checks. The `BASE_*` and
`N_JOINT` values can be computed by the driver from m, tau and N, or by hardware from the
embedding counts; the driver option is simpler and is the recommendation.

### 6.3 AXI-Lite RQA window (17-bit address, existing)

Unchanged: 0x000 ID, 0x004 STATUS, 0x008/0x00C `rr_count`, 0x010/0x014 `det_points`,
0x018 `det_lines`, 0x01C `l_max`, 0x020/0x024 `lam_points`, 0x028 `lam_lines`, 0x02C `v_max`,
0x030 `cells_target`, 0x038 `cells_accepted`; DET histogram at 0x1000, LAM histogram after it
(4 bytes per bin). `cells_target` stays N*N, as in the released design.

### 6.4 Performance monitor

Reuse `axi_perf_mon.v` as is (6-bit AXI-Lite window); it timestamps load end, pairs end, cells end
and scan end, which is what the Phase 4 benchmarks need.

## 7. PS/PL split and host formulas

| Task | Where | Reason |
|---|---|---|
| Acquisition, mean removal, decimation | PS | irregular, low rate |
| Per-channel normalisation to [0, 1] and Q8.24 conversion with saturation log | PS | needs the window min and max; matches `jrp.fixedpoint.to_q824` |
| Delay and dimension selection (AMI, FNN) | PS, offline | run once per recording, not per frame (`jrp.embedding`) |
| Noise reduction (GHKSS) | PS | neighbour search and small eigenproblems; reference in `jrp.ghkss`; budget in section 8 |
| eps selection | PS (B or C) or PL pass 0 (A) | decision D4 |
| Embedding, distance, threshold, AND, run tracking, histograms | PL | the O(N^2) work |
| Register programming, DMA, readout | PS | control plane |
| Metrics from counters | PS | division and logarithms |

Host formulas (`jrp.rqa.metrics_from_counters`, tested against the full-matrix definition):

    RR   = rr / N^2                          (rr = rr_count as read; full scan)
    DET  = 2 det_points / rr
    LAM  = lam_points / rr
    Lmax = l_max,  Vmax = v_max
    ENTR = - sum_l p(l) ln p(l),  p(l) = DET histogram bin l / total lines  (l >= lmin)

N is the number of joint vectors `n`. The factor 2 in DET reflects that the hardware counts only the
upper triangle of a symmetric matrix. (With the optional half scan of D1, `rr_count` would also be
doubled.)

## 8. Budgets

Computed by `scripts/phase2_budget.py` (outputs in `results/csv/phase2_*.csv`).
Assumptions:

- A1: pipeline fill from first pair to first flag at the extractor is 12 cycles.
- A2: the released orchestrator takes 11 cycles per pair (idle 1, read about 3, distance about 4, handoff 2 to 3).
- A3: one 32 x 32 signed multiply uses 4 DSP48E2; a lane uses 4 x MAX_M plus 6 for control. This reproduces the 46 DSP of Table 1.
- A4: finalisation costs about 6 N cycles (column sweep N, diagonal sweep about 5 per diagonal).
- A5: an AXI-Lite single read takes 0.3 to 1 us; unmeasured.

### 8.1 Cycle budget per frame (ms at 150 MHz, n = joint vectors)

Total = ingest + histogram clear + compare + finalise. The decided design (D1) is the full scan, K = 1. Histogram clear is 16,384 cycles (0.11 ms)
and is not overlapped here (D7 removes it).

| n | released FSM, full scan [est A2] | **pipelined, full scan, K=1 (decided)** | pipelined, full scan, K=2 | pipelined, upper scan, K=1 (alternative) |
|---|---|---|---|---|
| 512 | 19.4 | 1.9 | 1.0 | 1.0 |
| 1024 | 77.1 | 7.1 | 3.7 | 3.6 |
| 2048 | 307.8 | 28.2 | 14.2 | 14.2 |
| 4096 | 1230.6 | **112.1** | 56.2 | 56.2 |
| 8192 | 4921.8 | **447.9** | 224.2 | 224.2 |

K = 2 on the full scan equals K = 1 on the upper scan. The JRP costs the same cycles as the single-channel RP at equal K: the two distance units run in
parallel inside a lane. The pass 0 option (D4 A) adds one more scan time to these totals.
PS readout of counters adds well under 1 ms; histogram readout is up to 16,384 AXI-Lite reads
(5 to 16 ms worst case [est A5]), which is why D7 reads only the used bins.

### 8.2 Against the measured Phase 1 software (same signals, rtl convention, eps = 50 %)

| n | CPU NumPy (ms) | GPU CuPy (ms) | FPGA K=1 full scan (ms) [est] | speed-up vs CPU |
|---|---|---|---|---|
| 512 | 23.5 | 20.6 | 1.9 | 12x |
| 1024 | 63.9 | 51.6 | 7.1 | 9x |
| 2048 | 197.7 | 175.2 | 28.2 | 7x |
| 4096 | 739.7 | 474.7 | 112.1 | 6.6x |
| 8192 | 2814.0 | 1818.7 | 447.9 | 6.3x |

With the full scan the estimated speed-up over the NumPy path is about 6 to 12x for one lane, which is
below the paper's "over ten times" at large N. K = 2 doubles these figures to about 13x at N = 4096
(section 8.1), which is the paper's own bound on K. The CPU and GPU totals here are measured; the
FPGA figures are estimates.

The CPU and GPU totals are dominated by the CPU-side RQA extraction (section "Benchmark notes" of
the README), so the comparison flatters neither side; it is the end to end figure the thesis needs.

### 8.3 GHKSS on the PS

GHKSS is not in the PL. Its cost scales with the neighbour search (about N log N with a k-d tree) and
one small m x m eigendecomposition per point. The Python reference runs 2000 points in about 0.4
to 3 s depending on iterations on the development machine, so the ARM A53 (several times slower per
core) would take seconds per frame. GHKSS is therefore an offline or low-rate preprocessing step,
not part of the real-time loop, unless a later phase accelerates it. Needs measurement in Phase 4.

### 8.4 Resources

See D5. LUT, LUTRAM, BRAM and timing closure are not predicted beyond the bound above; they need
synthesis.

## 9. Verification plan

Everything in `golden/` is produced by Phase 1 from the same integer model the RTL implements
(see `golden/*.json`). Files are `%08X`, one word per line, readable with `$readmemh`.

| Level | DUT | Stimulus | Check (pass = exact) |
|---|---|---|---|
| L1 | embedding block | `NAME_x.hex` | `NAME_vec_x.hex` (small cases), component 0 = newest |
| L1 | distance unit x2 + AND | vector files, `eps2_hex` from the JSON | `NAME_flags.hex` for each pair |
| L1 | pair generator | n | pair order of `grid_index_gen.v` (full grid, i outer, j inner) |
| L1 | extractor | `NAME_flags_packed.hex` as `{i, j, flag}` | integer counters and histograms in `expected_counters_full_scan` (the `_upper_scan` entries are for the optional half scan) |
| L2 | lanes + extractor | vector files | counters |
| L3 | top level | `NAME_x.hex`, `NAME_y.hex` through the AXIS port, AXI-Lite programming | counters, then host formulas equal `expected_metrics` to 1e-12 |

Golden cases: four benchmark signals (N = 128 with per-pair flags and N = 4096 packed), coupled
logistic pairs at c = 0, 0.1, 0.3, a mixed (m, tau, eps) case, and five edge cases
(`edge_all_recurrent`, `edge_no_recurrence`, `edge_m1_tau1`, `edge_max_embedding`, `edge_saturation`).
Still to add: an insect recording pair when the dataset arrives, and a long case near N_MAX = 8192.

Because the comparison is on integers produced by the RTL itself, no host formula, convention or
floating-point tolerance enters L1 to L3. The only float step is the host formula check in L3.

## 10. Risks, open questions and Phase 3 starting tasks

| # | Item | Action |
|---|---|---|
| 1 | LUT usage unknown per module; a second channel could exceed the budget. | Phase 3 task 0: out-of-context synthesis of the released modules; record per-module LUT, LUTRAM, DSP, URAM, Fmax. |
| 2 | The released orchestrator is not the performance design (O4, O5). | Build a pipelined orchestrator and lane (5.4); first milestone is 1 flag per cycle in simulation. |
| 3 | Which RTL version produced the v2 spreadsheet, and what the host divides RR by (O11). | Ask Li or Oberst. Not blocking: D6 follows the v2 source and the paper's Eq. 2. |
| 4 | eps source (D4), decided: both. | Build the pass 0 max-distance datapath (option A) as an optional mode; PS rule for streaming. |
| 5 | MAX_M for the insect data. | Confirm once the dataset arrives. |
| 6 | Fmax at K = 2 with four distance units. | Synthesis. |
| 7 | AXI-Lite readout time and GHKSS runtime on the ARM cores. | Measure in Phase 4. |
| 8 | Histogram clear and readout overlap (D7). | Design in Phase 3. |

## 11. Decisions (signed off by Jay, 2026-10-20)

| ID | Decision |
|---|---|
| D1 | Full N x N scan, as in the released RTL. Upper-triangle scan recorded as an alternative. |
| D2 | End-aligned default, base registers, `align_start` option. |
| D3 | One 64-bit AXIS beat per sample pair `{y, x}`. |
| D4 | Both: PL pass 0 for exact percent-of-max-distance eps (benchmarking), PS rule for streaming. |
| D5 | MAX_M = 6, N_MAX = 8192 (24 of 48 URAM). |
| D6 | `rtl` convention, RR = rr_count / N^2 (settled by the evidence). |
| D7 | Clear histograms during readout; read only the used bins. |
| D8 | 150 MHz, K = 1 first; K = 2 only if synthesis allows. |

Still open, none blocking Phase 3: which RTL version produced the v2 spreadsheet (ask Li or Oberst);
confirming the paper's own scan count and eps wording against its full text; MAX_M for the insect
data once the dataset arrives.

## 12. Changes made during Phase 3 (see `Phase3/docs/phase3_results.md`)

Implementing the design in RTL found problems in the released modules that sections 5.1, 5.2 and 5.5
had assumed could be reused unchanged. The decisions D1 to D8 stand; these modules were replaced or
derived instead (the released files are untouched):

| Section | Was | Now |
|---|---|---|
| 5.1 embedding block | released `phase_space_reconstruction` unchanged | `jrp_psr`: the released block corrupts vectors after its history buffer wraps (non-power-of-two depth); about 600 LUTs per channel instead of 9,425 |
| 5.2 vector memory | released `vector_buffer` unchanged | `jrp_vector_buffer`: read valid aligned with the data (released valid is one cycle late, hidden by one-read-at-a-time use) |
| 5.5 extractor | unchanged | derived: pipelined histogram update (the released queue drops events at one flag per cycle), 32-bit histogram counters (released 14-bit saturates at 16,383), block-RAM state memories |
| D5 resources | estimate 24 URAM, 54 DSP | routed: 24 URAM (50 %), 51 DSP (7 %), 37 block RAM (29 %), 7,758 LUTs (8.8 %) |
| D7 histograms | clear during readout, read used bins | not implemented in Phase 3: the extractor still clears both histograms (16,384 cycles) at frame start. Counters, bins and ENTR are bit-exact |
| 8.1 cycle budget | 112.1 ms at N = 4096, K = 1 | simulated: 16,720,264 cycles = 111.5 ms from START to metrics valid |
| D4 option A | optional pass 0 | not implemented; register bits reserved, PS-written EPS2 works |
