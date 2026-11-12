# FPGA joint recurrence plot and JRQA accelerator

Code for the capstone project *FPGA-Based Joint Recurrence Plot Generation for Real-Time Analysis of Insect Vibroacoustic Dynamics*
(Jay Tinsley, UTS; supervisor A/Prof Sebastian Oberst). It extends the single-channel streaming RP/RQA design of Li, Lai and Oberst (2026)
to two channels (joint recurrence) on an ALINX AXU5EVB-P board (Zynq UltraScale+ XCZU5EV).

What it does: a dual-channel Verilog design that computes the joint recurrence plot and the JRQA measures (RR, DET, LAM, Lmax, Vmax, ENTR) in
streaming form without storing the N x N matrix. A Python reference defines the numerical ground truth and generates the test vectors. The
repository contains the programs only: no recordings, test vectors, results, bitstreams or build output.

## Layout

The directory names `Phase1` and `Phase3` are kept because the scripts refer to each other by relative path.

| Path | Content |
|---|---|
| `Phase1/` | Python reference (`src/jrp`), tests, and scripts for golden vectors, benchmarks, GHKSS filtering and the embedding and determinism analyses. See `Phase1/README.md`. |
| `Phase1/docs/phase2_architecture.md` | The architecture specification and design decisions D1 to D8. |
| `Phase3/` | Verilog (`rtl/`), testbenches (`tb/`), simulation, Vivado and board scripts (`scripts/`), and the bare-metal program (`sw/`). See `Phase3/README.md`. |
| `Phase3/docs/` | Design notes: hardware results and the real-time front-end specification. |
| `Phase3/released/` | Verbatim copy of the released single-channel RTL of Li et al. (MIT licence), used for comparison. Never edited. |

The folders `Phase1/golden`, `Phase1/data`, `Phase1/results`, `Phase3/reports` and `Phase3/build` are empty (a `.gitkeep` holds each) and are filled
by the scripts. `Phase3/sw/null_tables.h`, which `build_null.ps1` needs, is also generated (by `Phase3/scripts/gen_null_set.py`).

## Requirements

- Python 3.12 and the packages in `Phase1/requirements.txt` (`pyunicorn` needs Visual Studio Build Tools to compile; `ghkss` is the PyPI GHKSS filter).
- For simulation and board work: Vivado and Vitis 2026.1 (scripts expect `C:\AMDDesignTools\2026.1`; edit the top of the `.ps1`, `.tcl` and `.sh` files if yours differs), PowerShell, and an AXU5EVB-P board on JTAG.

## Running it

1. **Python reference.** From `Phase1`: create a virtual environment, install `requirements.txt` and the package (`pip install -e .`), then run `pytest -q`.
2. **Golden vectors.** `python scripts/export_golden.py` writes the integer test vectors into `Phase1/golden/` (large). `scripts/benchmark.py`, `scripts/quantisation_error.py` and `scripts/synthetic_validation.py` give the CPU/GPU timings and the fixed-point error. `scripts/benchmark_gpu_rqa.py` times the CuPy pipeline with the RQA extraction on the GPU (`src/jrp/rqa_gpu.py`), `scripts/gpu_power.py` measures the GPU card power, `scripts/benchmark_pyrqa.py` times PyRQA (needs `pip install pyrqa pyopencl` and an OpenCL GPU), and `scripts/cpu_gpu_fpga_figure.py` and `scripts/time_vs_n_figure.py` draw the comparison figures (frame time at N=4096 and against N, with PyRQA).
3. **Simulation.** From `Phase3/scripts` in PowerShell: `.\run_all_scan.ps1`, `.\run_all_extract.ps1`, `.\run_all_top.ps1`, `.\sim_rt_core.ps1` (see `Phase3/README.md`).
4. **Board builds.** `build_board.tcl` (register-driven build) and `build_rt_board.tcl` (real-time build with the DMA front end, `MAX_M` 6 or 10), run with Vivado in batch mode from `Phase3/build`. The bare-metal program is built with `sw/build.ps1`.
5. **Board runs.** `hw_load.tcl` loads a bitstream, `run_all_hw.ps1` runs the test cases, and `hw_sw_run.tcl` runs the bare-metal program and the rate tests. Details are in `Phase3/docs/`.
6. **Insect analysis (needs your own recordings).** Put a MATLAB file `cops_iridomyrmex.mat` with four series (`purpureus_lab`, `purpureus_wild`, `acinaciformis_Darwin`, `acinaciformis_Griffith`, 12 kHz) in the repository root. Then, from `Phase1`:
   `python scripts/filter_all_series.py` (GHKSS filtering),
   `python scripts/determinism_study.py` (single-channel determinism with and without filtering),
   `python scripts/simultaneity_test.py` (aligned against offset windows),
   `python scripts/export_filtered_pairs.py --ghkss 3,2` and `python scripts/export_window_cases.py` (golden cases for the board),
   and on the board `Phase3/scripts/run_filtered_pairs.sh` and `run_window_cases.sh` (run from `Phase3/build`), then `python scripts/collate_board_windows.py`.
   Footstep-resolved test: `python scripts/termite_noise_test.py` (band-pass, decimation, surrogates), `python scripts/termite_footstep_regroup.py` (envelope footstep detector),
   `python scripts/export_termite_cases.py` (60 golden cases), the same board script `run_window_cases.sh` with the names in `golden/termite_cases.txt` (strip carriage returns, for example `tr -d '\r'`), then `python scripts/collate_termite_cases.py`.
   The wild ant is added with `python scripts/termite_noise_test_wild.py` and `python scripts/export_termite_cases.py wild` (writes `golden/termite_cases_wild.txt`); `collate_termite_cases.py` picks both up.

## Data

The insect recordings (laser Doppler vibrometer, 12 kHz) belong to the work of Oberst, Lai and Evans (2026) and are not public, so none are included.

## Credits and licence

- Li, C., Lai, J. C. S. and Oberst, S. (2026), *Real-time recurrence plot and quantification analysis on FPGA for embedded nonlinear dynamics*,
  Eur. Phys. J. Spec. Top., doi:10.1140/epjs/s11734-026-02434-4. Released code: doi:10.5281/zenodo.20406392 (MIT). Parts of `Phase1/src` and `Phase3/rtl` are ported or derived from it and say so in their headers.
- GHKSS noise reduction: the `ghkss` package (https://pypi.org/project/ghkss/), after Grassberger, Hegger, Kantz, Schaffrath and Schreiber (1993) and the TISEAN package.
- Licence: MIT, see `LICENSE`.
