# Phase 3: RTL for the dual-channel JRP

Implements `Phase1/docs/phase2_architecture.md` (decisions D1 to D8): full N x N scan, two
channels in one 64-bit AXI-Stream beat, MAX_M = 6, N_MAX = 8192, 150 MHz target on the XCZU4EV.
Tools: Vivado 2026.1 at `C:\AMDDesignTools\2026.1\Vivado\bin` (xsim and synthesis). Not on PATH.

## Layout

| Path | Content |
|---|---|
| `released/` | Verbatim copy of the released single-channel RTL and testbenches (Li, Lai and Oberst 2026, Zenodo 10.5281/zenodo.20406392, MIT). Never edited. |
| `rtl/` | New and derived modules, each crediting what it derives from. |
| `tb/` | Self-checking SystemVerilog testbenches driven by the Phase 1 golden vectors. |
| `scripts/` | Simulation and synthesis runners. |
| `reports/` | Synthesis reports and CSV summaries of the simulation runs. |
| `build/` | Generated, safe to delete. |

## Modules

| Module | Status |
|---|---|
| `jrp_top` | new: AXIS `{y, x}` in, AXI-Lite control, RQA window, perf monitor |
| `jrp_axi_regs` | derived from `axi_lite_regs`: y-channel registers, bases, read-back, error bits |
| `jrp_psr` | replaces `phase_space_reconstruction` (see finding 2) |
| `jrp_vector_buffer` | derived from `vector_buffer` (see finding 1) |
| `jrp_pair_gen`, `jrp_lane`, `jrp_scan_engine` | new: pipelined full-grid scan, two distance units and an AND |
| `jrp_rqa_extractor`, `jrp_rqa_extractor_axi` | generated from the released extractor by `scripts/derive_extractor.py` (findings 3, 5) |
| `jrp_tdp_bram_fw` | replaces `tdp_bram_fw`, maps to block RAM (finding 5) |
| `distance_threshold_calculation`, `axi_perf_mon` | released, unchanged |

## Findings in the released RTL

Found by simulating the released modules at full rate against the Phase 1 integer model. The
released files are untouched; each fix is a separate derived module.

1. **`vector_buffer` read valid is one cycle late.** A request in cycle T returns data in T+3 and
   asserts `valid` in T+4. The released orchestrator hides this by issuing one read and waiting
   (the address register holds the data). With one read per cycle every valid pairs with the next
   request's data. `jrp_vector_buffer` aligns them.
2. **`phase_space_reconstruction` corrupts vectors after its history buffer wraps.** The buffer has
   (MAX_M-1)*MAX_TAU entries (144 in the released top level) but the read address is a plain
   PTRW-bit subtraction, which is only right for a power-of-two depth. Reads then land on
   unwritten locations: in simulation 728 of 4084 vectors are `x` at N = 4096, first at vector 134.
   Cases with fewer than 144 samples never wrap and pass. `jrp_psr` uses a shift register and
   passes at N = 4096 for m = 1 to 10 and tau up to 16.
3. **The extractor loses histogram events at one flag per cycle.** The DET histogram is updated
   by a 4-cycle read-modify-write fed by a 2-entry queue; a third event overwrites the second and
   the overflow counters are never incremented. Counters (`det_lines`, `lam_lines`, ...) stay
   correct but the histograms, and so ENTR, do not. 12 of the 13 golden cases fail with the
   released extractor; none with the derived one (one event per cycle, forwarding between
   consecutive updates of the same bin).
4. **`HIST_W = 14` saturates every histogram bin at 16,383 lines.** Invisible on small inputs; wrong for
   noisy or chaotic signals at N = 4096 (936,715 diagonal lines of length 2 for the UWN signal). `jrp_top`
   uses `HIST_W = 32`; the RAM words were already 32 bits wide.
5. **The state memories do not map to block RAM.** The released `tdp_bram_fw` is built from 15,360 LUTs of
   distributed RAM (Vivado: "Infeasible attribute ram_style = block") and is the critical timing path.
   `jrp_tdp_bram_fw` is a simple dual-port RAM with the bypass outside the array: 27,064 LUTs become 7,758.
6. **The final column sweep clears the wrong column.** Found on the board: running frames back to back,
   stale open runs left in the column state memory are counted by a later frame (a single-frame simulation
   never shows it). The derived extractor clears the address the data came from. See `docs/phase3_results.md`
   finding 7 and section 7 (hardware results).
7. **The released testbenches are not usable as regression.** The distance unit testbench no longer
   elaborates (ports renamed), the embedding one only prints vectors.

Whether the published hardware had the same behaviour is unknown: the paper's N = 4096 results
match Python, which an embedding block with finding 2 could not give. Ask the authors which source
produced the published bitstream.

## Reproducing the checks

All commands from `Phase3/scripts` in PowerShell. Golden vectors come from `Phase1/golden`.

| Check | Command |
|---|---|
| Embedding, full length | `.\sim_psr.ps1 -Samples bench_logistic_full_x.hex -Ns 4096 -M 5 -Tau 3 -Module jrp` (`-Module released` shows finding 2) |
| Scan engine, per-pair flags, all cases | `.\run_all_scan.ps1` |
| Scan engine + extractor, counters and histograms | `.\run_all_extract.ps1` (derived and released extractor) |
| Whole top level | `.\sim_top.ps1 -Case jrp_mixedparams_small`, `.\run_all_top.ps1 [-Small] [-Full]`, `.\rerun_full.ps1 -Cases a,b` |
| Place and route (timing) | `vivado -mode batch -source ../scripts/impl_jrp.tcl -tclargs 6 6.667 impl_m6` (from `build/`) |
| Synthesis of the released modules | `vivado -mode batch -source ../scripts/synth_released.tcl` (from `build/`) |
| Synthesis of the new design | `vivado -mode batch -source ../scripts/synth_jrp.tcl -tclargs jrp_top 6 jrp_top_m6` |

Batch files treat `=` as an argument separator, so `name=value` arguments are quoted in the
scripts. Run Vivado commands through `cmd /c` from Bash, or directly from PowerShell.

## Hardware (ALINX AXU5EVB-P)

The design runs on the board: 30 of 30 runs pass (12 small cases in each of two orders, 6 full-length N = 4096
cases), counters and histograms bit-exact against the golden vectors, 111.4 ms per N = 4096 frame at 150 MHz
equivalent. Scripts: `scripts/build_board.tcl`, `hw_bootmode.tcl`, `hw_load.tcl`, `gen_hw_case.py`,
`hw_axi_run.tcl`, `run_all_hw.ps1`. Details and reproduction: `docs/phase3_results.md` section 7.
