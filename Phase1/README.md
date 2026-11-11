# Phase 1: software baseline and golden reference (FPGA JRP capstone)

Double-precision Python pipeline for joint recurrence plots (JRP) and JRQA metrics. It is the
numerical ground truth for the RTL. It also holds the insect analysis scripts (GHKSS filtering,
embedding, determinism study) that feed the board runs.

## Setup

```
python -m uv venv .venv --python <python 3.12>
python -m uv pip install --python .venv\Scripts\python.exe -r requirements.txt
python -m uv pip install --python .venv\Scripts\python.exe -e .
.venv\Scripts\python.exe -m pytest -q
```

`pyunicorn` builds from source on Windows. It needs Visual Studio Build Tools 2022 with the C++ workload
and a Windows 11 SDK. The final GHKSS results use the `ghkss` package from PyPI (in `requirements.txt`);
`src/jrp/ghkss.py` also keeps a pure-Python reference implementation (slow, not validated against TISEAN).

## Layout

| Path | Content |
|---|---|
| `src/jrp/signals.py` | benchmark signals (Li et al.) and coupled logistic pairs |
| `src/jrp/embedding.py` | Takens embedding, AMI delay, FNN dimension |
| `src/jrp/distance.py`, `jrp.py` | blocked distances, RP and JRP (`joint_recurrence_blocked`) |
| `src/jrp/rqa.py` | RQA/JRQA metrics, `paper` and `rtl` counting conventions |
| `src/jrp/fixedpoint.py`, `golden.py` | Q8.24 model of the RTL compare stage, golden vector export |
| `src/jrp/ghkss.py` | GHKSS noise reduction reference |
| `src/jrp/bench.py` | per-stage CPU/GPU timing |
| `src/jrp/insect.py` | loader and preprocessing for insect channel pairs |
| `scripts/` | sweeps, validation, benchmarks, golden export |
| `golden/` | exported testbench vectors, see below |
| `results/csv`, `results/figures` | outputs (figures are PDF) |

Reused code (signal generators, embedding, blocked distance, RP and RQA metrics) comes from
Li, Lai and Oberst (2026), Zenodo doi:10.5281/zenodo.20406392, MIT licence. Each ported file
says so.

## Decisions to know about

1. **Two counting conventions** (`rqa_metrics(..., convention=)`).
   `paper` is the Li et al. Python reference: the main diagonal is excluded from diagonal
   lines only. `rtl` is what `RQA_extractor_nobitmap.v` computes: the cell i == j is
   non-recurrent everywhere (it splits vertical lines and is not in the RR count), and RR =
   rr_count / N^2, the denominator in Eq. 2 of the Li et al. preprint (the RTL only reports
   rr_count, so this is the paper's formula, not something read from the hardware; a fully
   recurrent plot gives (N-1)/N). DET and LAM divide by rr_count (Eqs. 3 and 4). The Li et al.
   FPGA spreadsheet matches `paper`, not this RTL file, to 1e-16, and the v1 preprint reports
   FPGA errors of 2e-4 (DET) and 4e-5 (LAM), so its hardware probably counted the main
   diagonal. Source of the mismatch unconfirmed: ask the authors. Golden vectors use `rtl`.
2. **eps** is a percentage of the maximum embedded pairwise distance, per channel.
3. **Channel alignment** with different (m, tau): vectors are paired by newest sample
   (`align="end"`), as the RTL does. Component order inside a vector does not matter for
   distances; golden vector files use the RTL order (newest first).
4. **Chaotic signals:** golden vectors store the actual samples. Never regenerate a logistic or
   Lorenz signal from a seed on another machine. Read initial conditions from files with
   `float_precision="round_trip"`.
5. **Multi-process scripts** set one BLAS thread per worker. Without this they oversubscribe
   the CPU and run more than ten times slower.

6. **pyunicorn conventions** (found by cross-checking, pyunicorn 1.0.0). Euclidean metric with
   absolute thresholds gives identical JRP matrices. RR, LAM, Vmax, Lmax and ENTR equal our
   `paper` convention; pyunicorn's DET divides by the recurrence points off the main diagonal
   (equal to our `rtl` DET). Floating-point results agree to about 1e-11, so tests use 1e-9.
   With different (m, tau) per channel pyunicorn pairs vectors by their first sample
   (`align="start"`), while the RTL embedding block implies pairing by newest sample
   (`align="end"`, our default). Phase 2 must pick one: `start` needs one channel's vectors
   delayed in hardware.

## Golden vector format

Q8.24 signed 32-bit two's complement, round to nearest, saturate (saturations are logged in
the JSON). All text files are `%08X`, one word per line, for `$readmemh`. Per case `NAME`:

- `NAME_x.hex`, `NAME_y.hex`: input samples (already normalised to [0, 1]).
- `NAME_flags.hex`: one word per pair (0 or 1), order of `grid_index_gen.v`: i outer, j inner,
  full n x n grid including i == j. Small cases only (n <= 256).
- `NAME_flags_packed.hex`: 32 flags per word, pair p in bit p % 32 of word p // 32.
- `NAME_vec_x.hex`, `NAME_vec_y.hex`: embedded vectors, m words each, newest sample first.
- `NAME.json`: N, m, tau, eps (float, Q8.24 `eps2`, percent), source and seeds, saturation
  events, SHA-256 of each file, expected metrics (rtl convention).

The RTL compare is reproduced exactly: `sum_k (a_k - b_k)^2 <= eps2 << 24` in integers, with
`eps2 = round(eps^2 * 2^24)`.

## Phase 1 exit criteria

| Criterion | Result |
|---|---|
| Single-channel results reproduce Li et al. within 1e-6 | exact (30-realisation CSV and eps/N sweeps, NumPy and CuPy): `scripts/diff_vs_notebook.py`, `tests/test_single_channel.py` |
| JRP passes unit tests, behaves on coupled and uncoupled pairs | `tests/test_jrp.py`, `tests/test_synthetic.py`, `scripts/synthetic_validation.py` |
| Independent cross-check agrees | pyunicorn 1.0.0 `JointRecurrencePlot`: same matrices, same metrics up to the convention differences in decision 6 (`tests/test_pyunicorn_crosscheck.py`); also an independent re-implementation (`tests/test_independent_crosscheck.py`) |
| Golden vectors for four benchmark signals and one insect pair | four signals, coupled pairs done; insect pair pending data |
| CPU and GPU timing CSVs and figures | `scripts/benchmark.py` |
| Q8.24 quantisation within 1e-4 of float64 | max error 3.4e-5 (ENTR); `scripts/quantisation_error.py` |

## Benchmark notes (results/csv/benchmark_*.csv, results/figures/benchmark_*.pdf)

Stage definitions and timing rules: `src/jrp/bench.py`. Machine: i5-12600K, RTX 3070 Ti.

- The compare stage (distance and threshold) is 4x to 10x faster on the GPU at N >= 4096
  (best case at N = 4096: about 17 ms against 150 ms for one channel, 300 ms for a JRP).
- The GPU compare time is bimodal in these runs: about 17 ms in some configurations and
  80 to 110 ms in others, independent of eps and signal. The CPU is stable. The likely cause is
  the GPU clocking down during the CPU-side RQA stage between runs; this was not verified.
  Use the `_min_ms` columns for steady-state GPU compare time, and the means for the
  end-to-end figure.
- T_rqa is the same CPU code on both backends and dominates T_total (about 0.3 to 0.6 s at
  N = 4096, 1.6 to 1.9 s at N = 8192), so end-to-end speed-up is only 1.1x to 1.7x. Speeding
  up the RQA stage (numba, or on the GPU) is needed before the GPU total says much.

## Phase 2 (architecture specification)

`docs/phase2_architecture.md` is the specification: what the released RTL really is, the
dual-channel JRP architecture, interfaces, register map, cycle and resource budgets, the verification
plan and the decisions needed. Supporting files:

- `scripts/phase2_budget.py` computes the cycle and resource budgets (`results/csv/phase2_*.csv`).
- `scripts/phase2_figure.py` draws the block diagram (`results/figures/phase2_architecture.pdf`).
- `jrp.rqa.rtl_counters` gives the integer counters the RTL extractor must report, for the full
  scan and the optional upper-triangle scan; `jrp.rqa.metrics_from_counters` holds the host
  formulas. Both are in the golden JSON (`expected_counters_*`), so RTL checks compare integers.
- `tests/test_rtl_counters.py` proves that the upper-triangle scan gives exactly the same counters
  as the full scan, which would halve the cycle count. Decision D1 chose the full scan (as in the
  released RTL), so this stays as a documented optimisation.

## Open items

- Insect dataset: confirm simultaneously recorded channel pairs, format, sampling rate.
- GHKSS versus TISEAN `ghkss`: TISEAN not installed.
- Ask Li or Oberst which RTL version produced the published FPGA results (point 1 above).
