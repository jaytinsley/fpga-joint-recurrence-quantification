"""Task 4: synthetic validation of the JRP pipeline.

(a) Two coupled logistic maps, coupling c swept from 0 (independent) to strong,
    averaged over 30 random initial-condition pairs (as the Li et al. 30-realisation study).
(b) Identical systems: JRP(x, x) must equal the single-channel RP exactly.
(c) Independent noise: JRR should be close to RR_x * RR_y.
Settings follow Li et al.: N = 4096, m = 5, tau = 3, eps = 50 % of max distance, lmin = vmin = 2.
Usage: python scripts/synthetic_validation.py [--workers 6]
"""
import os

# One math thread per worker process; without this the workers oversubscribe the CPU.
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "1")

import argparse
import json
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

from jrp.jrp import ChannelParams, embed_pair, recurrence_matrix_blocked, resolve_eps
from jrp.embedding import takens_embedding
from jrp.pipeline import jrp_rqa, rp_rqa
from jrp.signals import (gen_coupled_logistic, gen_harmonic_5_osc, gen_logistic,
                         gen_lorenz_x_resampled, gen_uwn)

ROOT = Path(__file__).resolve().parents[1]
CSV, FIG = ROOT / "results" / "csv", ROOT / "results" / "figures"
N, M, TAU, EPS_PCT = 4096, 5, 3, 50.0
COUPLINGS = [0.0, 0.02, 0.04, 0.06, 0.08, 0.10, 0.125, 0.15, 0.175, 0.20, 0.30]
N_REAL, SEED = 30, 2026
P = ChannelParams(M, TAU, eps_percent=EPS_PCT)


def _one(args):
    mode, r, c, x0, y0 = args
    x, y = gen_coupled_logistic(N, c, r=r, x0=x0, y0=y0, mode=mode)
    row = {"mode": mode, "r": r, "c": c, "x0": x0, "y0": y0}
    for conv in ("paper", "rtl"):
        m, _ = jrp_rqa(x, y, P, P, convention=conv)
        row.update({f"{k}_{conv}": m[k] for k in ("JRR", "JDET", "JLAM", "Lmax", "Vmax", "ENTR")})
    row["max_abs_xy"] = float(np.abs(x - y).max())
    # Dependence measure: JRR / (RR_x * RR_y) is 1 for independent systems and grows with
    # coupling. RR counts the main diagonal, like JRR_paper, so the two are consistent.
    Vx, Vy = embed_pair(x, y, P, P)
    row["RR_x"] = float(recurrence_matrix_blocked(Vx, resolve_eps(Vx, P)).mean())
    row["RR_y"] = float(recurrence_matrix_blocked(Vy, resolve_eps(Vy, P)).mean())
    row["JRR_ratio"] = row["JRR_paper"] / (row["RR_x"] * row["RR_y"])
    return row


def coupling_sweep(workers):
    rng = np.random.default_rng(SEED)
    ics = [(float(a), float(b)) for a, b in rng.uniform(0.1, 0.9, size=(N_REAL, 2))]
    jobs = [(mode, r, c, x0, y0) for mode in ("mutual", "drive") for r in (3.82843, 3.9)
            for c in COUPLINGS for x0, y0 in ics]
    with ProcessPoolExecutor(workers) as ex:
        df = pd.DataFrame(list(ex.map(_one, jobs, chunksize=4)))
    df.to_csv(CSV / "synthetic_coupled_logistic_raw.csv", index=False)
    cols = [c for c in df.columns if c.endswith(("_paper", "_rtl"))] + ["RR_x", "RR_y", "JRR_ratio", "max_abs_xy"]
    g = df.groupby(["mode", "r", "c"])[cols]
    summ = g.mean().add_suffix("_mean").join(g.std(ddof=1).add_suffix("_std")).reset_index()
    summ.to_csv(CSV / "synthetic_coupled_logistic_summary.csv", index=False)
    return df, summ, ics


def plot_coupling(summ):
    keys = (("JRR_paper", "JRR"), ("JDET_paper", "JDET"), ("JRR_ratio", "JRR / (RR_x RR_y)"))
    fig, axes = plt.subplots(2, 3, figsize=(9, 5), sharex=True)
    for row_ax, mode in zip(axes, ("mutual", "drive")):
        for ax, (key, lab) in zip(row_ax, keys):
            for r in sorted(summ.r.unique()):
                s = summ[(summ["mode"] == mode) & (summ.r == r)]
                ax.errorbar(s.c, s[f"{key}_mean"], s[f"{key}_std"], marker="o", ms=3, capsize=2,
                            label=f"r = {r:g}")
            ax.set_ylabel(lab)
            ax.set_title(f"{mode} coupling", fontsize=8)
            ax.grid(True, ls="--", alpha=0.4)
    for ax in axes[1]:
        ax.set_xlabel("coupling c (dimensionless)")
    axes[0, 0].legend(fontsize=7)
    fig.tight_layout()
    fig.savefig(FIG / "synthetic_coupling_sweep.pdf")
    plt.close(fig)


def identical_systems():
    sig = {"UWN": gen_uwn(N, seed=123), "Logistic": gen_logistic(N),
           "Lorenz_x": gen_lorenz_x_resampled(N), "Harmonic": gen_harmonic_5_osc(N)}
    rows = []
    for name, x in sig.items():
        mj, JR = jrp_rqa(x, x, P, P, convention="paper")
        ms, R = rp_rqa(x, M, TAU, EPS_PCT, include_main_diag=False)
        rows.append({"series": name, "matrices_equal": bool(np.array_equal(JR, R)),
                     "max_abs_metric_diff": max(abs(mj["JRR"] - ms["RR"]), abs(mj["JDET"] - ms["DET"]),
                                                abs(mj["JLAM"] - ms["LAM"]), abs(mj["ENTR"] - ms["ENTR"]),
                                                abs(mj["Lmax"] - ms["Lmax"]), abs(mj["Vmax"] - ms["Vmax"]))})
    df = pd.DataFrame(rows)
    df.to_csv(CSV / "synthetic_identical_systems.csv", index=False)
    return df


def independent_noise():
    rows = []
    for seed in range(5):
        x, y = gen_uwn(N, seed=1000 + seed), gen_uwn(N, seed=2000 + seed)
        for pct in (10, 20, 30, 40, 50, 60, 70, 80, 90):
            p = ChannelParams(M, TAU, eps_percent=float(pct))
            mj, _ = jrp_rqa(x, y, p, p, convention="paper")
            rx, _ = rp_rqa(x, M, TAU, pct)
            ry, _ = rp_rqa(y, M, TAU, pct)
            rows.append({"seed_x": 1000 + seed, "seed_y": 2000 + seed, "eps_percent": pct,
                         "RR_x": rx["RR"], "RR_y": ry["RR"], "JRR": mj["JRR"],
                         "RR_x_times_RR_y": rx["RR"] * ry["RR"]})
    df = pd.DataFrame(rows)
    df["abs_diff"] = (df.JRR - df.RR_x_times_RR_y).abs()
    df["ratio"] = df.JRR / df.RR_x_times_RR_y
    df.to_csv(CSV / "synthetic_independent_noise.csv", index=False)
    return df


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workers", type=int, default=6)
    a = ap.parse_args()
    CSV.mkdir(parents=True, exist_ok=True)
    FIG.mkdir(parents=True, exist_ok=True)
    ident = identical_systems()
    print("identical systems:\n", ident.to_string(index=False), flush=True)
    noise = independent_noise()
    print("independent noise: max abs(JRR - RRx*RRy) =", noise.abs_diff.max(),
          " ratio range", noise.ratio.min(), noise.ratio.max(), flush=True)
    df, summ, ics = coupling_sweep(a.workers)
    plot_coupling(summ)
    (CSV / "synthetic_validation_meta.json").write_text(json.dumps(
        {"seed": SEED, "n_realisations": N_REAL, "initial_conditions_x0_y0": ics, "N": N, "m": M,
         "tau": TAU, "eps_percent": EPS_PCT, "couplings": COUPLINGS}, indent=1))
    pd.set_option("display.width", 250)
    print(summ[["mode", "r", "c", "JRR_paper_mean", "JDET_paper_mean", "JLAM_paper_mean",
                "JRR_ratio_mean", "JRR_ratio_std", "max_abs_xy_mean"]].round(4).to_string(index=False))


if __name__ == "__main__":
    main()
