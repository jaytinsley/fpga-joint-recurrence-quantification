"""Task 9: CPU (NumPy) versus GPU (CuPy) benchmarks over the Li et al. sweeps.

eps sweep: eps = 10..90 % of max embedded distance, N = 4096.
N sweep:   N in {512, 1024, 2048, 4096, 8192}, eps = 50 %.
Series: the four Li et al. benchmark signals (single-channel RP, as in the paper) and two
dual-channel JRP pairs. m = 5, tau = 3, lmin = vmin = 2, "rtl" counting convention.
Timing rules are in src/jrp/bench.py. Results are appended per configuration, so an
interrupted run can be resumed (finished configurations are skipped).

Usage: python scripts/benchmark.py [--sweep eps|N|both] [--backends numpy cupy] [--repeats 5]
       python scripts/benchmark.py --plot-only
Keep the machine otherwise idle while this runs: host-side work is part of every timing.
"""
import os

os.environ.setdefault("OMP_NUM_THREADS", "1")       # as in the paper's notebook: fair CPU timing
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")

import argparse
import csv
import json
import platform
import sys
from datetime import datetime
from pathlib import Path

import numpy as np

from jrp import bench
from jrp.jrp import ChannelParams
from jrp.signals import (gen_coupled_logistic, gen_harmonic_5_osc, gen_logistic,
                         gen_lorenz_x_resampled, gen_uwn)

ROOT = Path(__file__).resolve().parents[1]
CSV_DIR, FIG_DIR = ROOT / "results" / "csv", ROOT / "results" / "figures"
M, TAU = 5, 3
EPS_PCTS = [10, 20, 30, 40, 50, 60, 70, 80, 90]
LENGTHS = [512, 1024, 2048, 4096, 8192]

SERIES = {  # name -> function N -> (x, y or None)
    "UWN": lambda n: (gen_uwn(n, seed=123), None),
    "Logistic": lambda n: (gen_logistic(n), None),
    "Lorenz_x": lambda n: (gen_lorenz_x_resampled(n, 100.0, 0.1), None),
    "Harmonic": lambda n: (gen_harmonic_5_osc(n, 100.0, 5), None),
    "JRP_coupled_logistic": lambda n: gen_coupled_logistic(n, 0.1),
    "JRP_independent_UWN": lambda n: (gen_uwn(n, seed=1000), gen_uwn(n, seed=2000)),
}
FIELDS = ["sweep", "series", "channels", "backend", "N", "n_vectors", "eps_percent", "eps_x", "eps_y",
          "T_maxdist_ms", "repeats"] + \
         [f"{s}_{k}_ms" for s in ("T_sig", "T_psr", "T_cmp", "T_rqa", "T_total") for k in ("mean", "std", "min")] + \
         ["RR", "DET", "LAM", "Lmax", "Vmax", "ENTR"]


def environment():
    env = {"date": datetime.now().isoformat(timespec="seconds"), "python": sys.version.split()[0],
           "numpy": np.__version__, "platform": platform.platform(), "cpu": platform.processor(),
           "m": M, "tau": TAU, "block": 1024, "lmin": 2, "vmin": 2, "convention": "rtl",
           "seeds": {"UWN": 123, "JRP_independent_UWN": [1000, 2000]}}
    try:
        import cupy as cp
        props = cp.cuda.runtime.getDeviceProperties(0)
        env.update(gpu=props["name"].decode(), gpu_memory_bytes=int(props["totalGlobalMem"]),
                   cupy=cp.__version__, cuda_runtime=cp.cuda.runtime.runtimeGetVersion(),
                   cuda_driver=cp.cuda.runtime.driverGetVersion())
    except Exception as e:  # no GPU: CPU only
        env["gpu"] = f"unavailable ({e})"
    return env


def done_keys(path):
    if not path.exists():
        return set()
    with open(path, newline="") as f:
        return {(r["series"], r["backend"], r["N"], r["eps_percent"]) for r in csv.DictReader(f)}


def run_sweep(sweep, backends, repeats, series_names):
    path = CSV_DIR / f"benchmark_{sweep}_sweep.csv"
    seen = done_keys(path)
    new = not path.exists()
    configs = ([(4096, p) for p in EPS_PCTS] if sweep == "eps" else [(n, 50) for n in LENGTHS])
    with open(path, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        if new:
            w.writeheader()
        for name in series_names:
            for n, pct in configs:
                x, y = SERIES[name](n)
                px = py = ChannelParams(M, TAU, eps_percent=float(pct))
                for backend in backends:
                    if (name, backend, str(n), str(pct)) in seen:
                        continue
                    ex, ey, t_md = bench.resolve_eps_absolute(x, y, px, py, 1024, backend)
                    r = bench.benchmark(x, y, ChannelParams(M, TAU, eps=ex), ChannelParams(M, TAU, eps=ey or ex),
                                        ex, ey, backend=backend, repeats=repeats)
                    row = {"sweep": sweep, "series": name, "channels": 1 if y is None else 2,
                           "backend": backend, "N": n, "eps_percent": pct, "eps_x": ex, "eps_y": ey,
                           "T_maxdist_ms": t_md, **{k: r[k] for k in r if k in FIELDS}}
                    w.writerow(row)
                    f.flush()
                    print(f"{sweep} {name:22s} {backend:5s} N={n:5d} eps={pct:2d}% "
                          f"T_total={r['T_total_mean_ms']:9.1f} ms  T_cmp={r['T_cmp_mean_ms']:8.1f} ms",
                          flush=True)


def plot():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import pandas as pd
    FIG_DIR.mkdir(parents=True, exist_ok=True)
    for sweep, xcol, xlab in (("eps", "eps_percent", "epsilon (% of max distance)"), ("N", "N", "signal length N")):
        p = CSV_DIR / f"benchmark_{sweep}_sweep.csv"
        if not p.exists():
            continue
        df = pd.read_csv(p)
        for stage, lab in (("T_total", "total time (ms)"), ("T_cmp", "compare stage time (ms)")):
            fig, axes = plt.subplots(2, 3, figsize=(9, 5), sharex=True)
            for ax, name in zip(axes.ravel(), SERIES):
                for backend, mk in (("numpy", "o"), ("cupy", "s")):
                    d = df[(df.series == name) & (df.backend == backend)].sort_values(xcol)
                    if len(d):
                        ax.errorbar(d[xcol], d[f"{stage}_mean_ms"], d[f"{stage}_std_ms"], marker=mk, ms=3,
                                    capsize=2, label="CPU (NumPy)" if backend == "numpy" else "GPU (CuPy)")
                ax.set_title(name, fontsize=8)
                ax.grid(True, ls="--", alpha=0.4)
                if sweep == "N":
                    ax.set_xscale("log", base=2)
                    ax.set_yscale("log")
            for ax in axes[1]:
                ax.set_xlabel(xlab)
            for ax in axes[:, 0]:
                ax.set_ylabel(lab)
            axes[0, 0].legend(fontsize=7)
            fig.tight_layout()
            fig.savefig(FIG_DIR / f"benchmark_{stage}_vs_{sweep}.pdf")
            plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sweep", choices=["eps", "N", "both"], default="both")
    ap.add_argument("--backends", nargs="+", default=["numpy", "cupy"])
    ap.add_argument("--repeats", type=int, default=5)
    ap.add_argument("--series", nargs="+", default=list(SERIES))
    ap.add_argument("--plot-only", action="store_true")
    a = ap.parse_args()
    CSV_DIR.mkdir(parents=True, exist_ok=True)
    if not a.plot_only:
        (CSV_DIR / "benchmark_environment.json").write_text(json.dumps(environment(), indent=1))
        for sw in (["eps", "N"] if a.sweep == "both" else [a.sweep]):
            run_sweep(sw, a.backends, a.repeats, a.series)
    plot()


if __name__ == "__main__":
    main()
