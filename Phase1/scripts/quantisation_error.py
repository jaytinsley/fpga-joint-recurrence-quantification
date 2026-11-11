"""Phase 1 exit criterion: Q8.24 quantisation alone keeps metric error within 1e-4 of float64.

Both sides use the same ("rtl") counting convention, so the only difference is Q8.24:
float64 metrics from the float RP versus metrics from the integer RTL model.
Ratio metrics (RR, DET, LAM, ENTR) are compared by absolute error. Lmax and Vmax are
integers, so they are reported as absolute and relative error.
Cases: four benchmark signals x eps 10..90 % (N = 4096) and coupled logistic JRPs.
Usage: python scripts/quantisation_error.py [--workers 6]
"""
import os

# One math thread per worker process; without this the workers oversubscribe the CPU.
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "1")

import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

from jrp.golden import integer_jrp
from jrp.jrp import ChannelParams
from jrp.pipeline import jrp_rqa, rp_rqa
from jrp.rqa import rqa_metrics
from jrp.signals import (gen_coupled_logistic, gen_harmonic_5_osc, gen_logistic,
                         gen_lorenz_x_resampled, gen_uwn)

ROOT = Path(__file__).resolve().parents[1]
N, M, TAU = 4096, 5, 3
SIGNALS = {"UWN": lambda: gen_uwn(N, seed=123), "Logistic": lambda: gen_logistic(N),
           "Lorenz_x": lambda: gen_lorenz_x_resampled(N, 100.0, 0.1),
           "Harmonic": lambda: gen_harmonic_5_osc(N, 100.0, 5)}
KEYS = ("RR", "DET", "LAM", "ENTR")


def _row(label, pct, f, q):
    row = {"case": label, "eps_percent": pct}
    for k in KEYS:
        row[f"err_{k}"] = abs(f[k] - q[k])
    for k in ("Lmax", "Vmax"):
        row[f"abs_err_{k}"] = abs(f[k] - q[k])
        row[f"rel_err_{k}"] = abs(f[k] - q[k]) / max(f[k], 1)
    row["flags_differing"] = None
    return row


def single(args):
    name, pct = args
    x = SIGNALS[name]()
    fm, Rf = rp_rqa(x, M, TAU, pct, include_main_diag=False)
    fm = rqa_metrics(Rf, convention="rtl")
    p = ChannelParams(M, TAU, eps_percent=float(pct))
    Rq, *_ = integer_jrp(x, None, p, p)
    qm = rqa_metrics(Rq, convention="rtl")
    r = _row(name, pct, fm, qm)
    r["flags_differing"] = int((Rf != Rq).sum())
    return r


def dual(args):
    c, pct = args
    x, y = gen_coupled_logistic(N, c)
    p = ChannelParams(M, TAU, eps_percent=float(pct))
    fm, JR = jrp_rqa(x, y, p, p, convention="rtl", normalise=False)
    fm = {"RR": fm["JRR"], "DET": fm["JDET"], "LAM": fm["JLAM"], "ENTR": fm["ENTR"],
          "Lmax": fm["Lmax"], "Vmax": fm["Vmax"]}
    Rq, *_ = integer_jrp(x, y, p, p)
    qm = rqa_metrics(Rq, convention="rtl")
    r = _row(f"JRP_coupled_c{c:g}", pct, fm, qm)
    r["flags_differing"] = int((JR != Rq).sum())
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workers", type=int, default=6)
    a = ap.parse_args()
    jobs_s = [(n, p) for n in SIGNALS for p in (10, 20, 30, 40, 50, 60, 70, 80, 90)]
    jobs_d = [(c, p) for c in (0.0, 0.1, 0.3) for p in (30, 50, 70)]
    with ProcessPoolExecutor(a.workers) as ex:
        rows = list(ex.map(single, jobs_s)) + list(ex.map(dual, jobs_d))
    df = pd.DataFrame(rows)
    out = ROOT / "results" / "csv"
    out.mkdir(parents=True, exist_ok=True)
    df.to_csv(out / "quantisation_error_q824.csv", index=False)
    ratio_max = df[[f"err_{k}" for k in KEYS]].max()
    print(df.round(8).to_string(index=False))
    print("\nmax abs error over all cases:\n", ratio_max.to_string())
    print("max relative error Lmax/Vmax:", df.rel_err_Lmax.max(), df.rel_err_Vmax.max())
    print("max flags differing out of", (N - (M - 1) * TAU) ** 2, ":", df.flags_differing.max())

    fig, ax = plt.subplots(figsize=(4.5, 3))
    s = df[df.case.isin(SIGNALS)]
    for name in SIGNALS:
        d = s[s.case == name]
        ax.semilogy(d.eps_percent, d[[f"err_{k}" for k in KEYS]].max(axis=1).clip(lower=1e-18),
                    marker="o", ms=3, label=name)
    ax.axhline(1e-4, color="gray", ls="--", lw=1)
    ax.set_xlabel("epsilon (% of max distance)")
    ax.set_ylabel("max |error| of RR, DET, LAM, ENTR")
    ax.grid(True, ls="--", alpha=0.4)
    ax.legend(fontsize=7)
    fig.tight_layout()
    (ROOT / "results" / "figures").mkdir(parents=True, exist_ok=True)
    fig.savefig(ROOT / "results" / "figures" / "quantisation_error_q824.pdf")


if __name__ == "__main__":
    main()
