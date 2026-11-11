"""Phase 2: cycle and resource budget for the dual-channel JRP architecture.

Every number printed is computed here from formulas and RTL facts; assumptions are marked
(A#) in docs/phase2_architecture.md. Outputs results/csv/phase2_cycle_budget.csv and
results/csv/phase2_resource_budget.csv, and prints Markdown tables.

Facts taken from the Li et al. RTL / paper:
  f = 150 MHz (README), device XCZU4EV: 87,840 LUT, 57,600 LUTRAM, 48 URAM (288 Kb),
  128 BRAM, 728 DSP. Table 1 of the preprint (N_MAX = 8192, MAX_M = 10): 40,397 LUT,
  20 URAM, 17 BRAM, 46 DSP.
  Paper timing model: T_cmp = N (N - 1) / (2 K f eta). Paper result at N = 8192: about 225 ms.
Estimates (not measured): the released orchestrator FSM cycles per pair, extractor sweep
cycles, resource scaling for the second channel.
"""
import math
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
F_HZ = 150e6
HIST_K = 8192
PIPE_LAT = 12            # (A1) cycles from first pair to first flag at the extractor
FSM_CYCLES_PER_PAIR = 11  # (A2) released orchestrator: IDLE 1 + read 3 + DTC ~4 + out reg/handshake 2-3
DEVICE = dict(LUT=87840, LUTRAM=57600, URAM=48, BRAM=128, DSP=728)


def cycles(n, K, scan, engine):
    """Cycle budget (cycles) per phase for n embedded vectors and K lanes."""
    cells = n * n if scan == "full" else n * (n - 1) // 2
    ingest = n + 12                                  # one sample (pair) per cycle + PSR fill
    if engine == "released_fsm":
        compare = cells * FSM_CYCLES_PER_PAIR        # one lane, multi-cycle FSM per pair
    else:
        compare = math.ceil(cells / K) + PIPE_LAT    # pipelined, 1 flag per lane per cycle
    final = n + 5 * (n - 1)                          # LAM column sweep + DET diagonal sweep (RTL FSMs)
    hist_clear = 2 * HIST_K                          # ST_HIST_CLR, released RTL, per frame
    return dict(ingest=ingest, hist_clear=hist_clear, compare=compare, final=final,
                total=ingest + hist_clear + compare + final)


def cycle_table():
    rows = []
    for n in (512, 1024, 2048, 4096, 8192):
        for engine, scan, K in (("released_fsm", "full", 1), ("pipelined", "full", 1),
                                ("pipelined", "full", 2), ("pipelined", "upper", 1), ("pipelined", "upper", 2)):
            c = cycles(n, K, scan, engine)
            rows.append(dict(n=n, engine=engine, scan=scan, K=K, **{k: v for k, v in c.items()},
                             total_ms=c["total"] / F_HZ * 1e3, compare_ms=c["compare"] / F_HZ * 1e3))
    return pd.DataFrame(rows)


def uram_per_memory(max_m, n_max):
    """URAM blocks for one vector memory copy: 72-bit wide x 4096 deep primitives."""
    return math.ceil(32 * max_m / 72) * math.ceil(n_max / 4096)


def resource_table():
    rows = []
    for ch in (1, 2):
        for max_m in (10, 8, 6, 5):
            for n_max in (8192, 4096):
                uram = ch * 2 * uram_per_memory(max_m, n_max)   # 2 mirrored copies per channel
                dsp = ch * 4 * max_m + 6                         # (A3) 4 DSP48E2 per 32x32 multiply
                rows.append(dict(channels=ch, MAX_M=max_m, N_MAX=n_max, URAM=uram,
                                 URAM_pct=100 * uram / DEVICE["URAM"], DSP=dsp,
                                 DSP_pct=100 * dsp / DEVICE["DSP"]))
    return pd.DataFrame(rows)


def main():
    out = ROOT / "results" / "csv"
    out.mkdir(parents=True, exist_ok=True)
    ct, rt = cycle_table(), resource_table()
    ct.to_csv(out / "phase2_cycle_budget.csv", index=False)
    rt.to_csv(out / "phase2_resource_budget.csv", index=False)

    # sanity checks against the published numbers
    assert uram_per_memory(10, 8192) * 2 == 20, "Table 1 URAM (20) not reproduced"
    assert 4 * 10 + 6 == 46, "Table 1 DSP (46) not reproduced"
    paper_ms = 8192 * 8191 / 2 / F_HZ * 1e3
    print(f"check: paper model N=8192, K=1: {paper_ms:.1f} ms (paper reports about 225 ms)")

    show = ct.pivot_table(index="n", columns=["engine", "scan", "K"], values="total_ms").round(1)
    print("\nTotal time per frame (ms), 150 MHz:")
    print(show.to_string())
    print("\nResource budget (URAM = 48 and DSP = 728 available):")
    print(rt.round(1).to_string(index=False))

    # compare with measured CPU/GPU totals from the Phase 1 benchmark (rtl convention, eps 50 %)
    b = pd.read_csv(out / "benchmark_N_sweep.csv")
    b = b[b.series == "JRP_coupled_logistic"].pivot_table(index="N", columns="backend", values="T_total_mean_ms")
    # Decision D1 (signed off): full N x N scan, as in the released RTL. Upper scan kept for reference.
    f = ct[(ct.engine == "pipelined") & (ct.scan == "full") & (ct.K == 1)].set_index("n").total_ms
    fu = ct[(ct.engine == "pipelined") & (ct.scan == "upper") & (ct.K == 1)].set_index("n").total_ms
    cmp_ = pd.DataFrame({"CPU_ms": b["numpy"], "GPU_ms": b["cupy"], "FPGA_K1_full_ms": f,
                         "FPGA_K1_upper_ms": fu}).dropna()
    cmp_["speedup_vs_CPU"] = cmp_.CPU_ms / cmp_.FPGA_K1_full_ms
    cmp_["speedup_vs_CPU_upper"] = cmp_.CPU_ms / cmp_.FPGA_K1_upper_ms
    cmp_.round(1).to_csv(out / "phase2_vs_measured_cpu_gpu.csv")
    print("\nPipelined full-scan K=1 (decision D1) against measured JRP times (Phase 1, N = vectors):")
    print(cmp_.round(1).to_string())


if __name__ == "__main__":
    main()
