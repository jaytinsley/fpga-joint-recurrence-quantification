"""Diff src/jrp against the original Li, Lai and Oberst notebook on the eps and N sweeps.

The notebook's own code cells (1-5) are exec'd unmodified from the local copy of the
Zenodo repo (doi:10.5281/zenodo.20406392), so the reference tables come from their code.
Usage: python scripts/diff_vs_notebook.py [--backend numpy|cupy]
"""
import argparse
import json
import sys
import warnings
from pathlib import Path

import numpy as np
import pandas as pd

from jrp.pipeline import rp_rqa
from jrp.signals import (gen_harmonic_5_osc, gen_logistic, gen_lorenz_x_resampled,
                         gen_uwn)

import os
# Path to python_rp_vs_fpga.ipynb in a local copy of the Zenodo release (set LI_RELEASE to the folder holding it)
NB = Path(os.environ.get("LI_RELEASE", "fpga-rp-rqa-streaming-v2")) / "scripts" / "python_rp_vs_fpga.ipynb"
OUT = Path(__file__).resolve().parents[1] / "results" / "csv"
M, TAU, LMIN, VMIN = 5, 3, 2, 2
EPS_PCTS = [10, 20, 30, 40, 50, 60, 70, 80, 90]
LENGTHS = [512, 1024, 2048, 4096, 8192]
METRICS = ["RR", "DET", "LAM", "Lmax", "Vmax", "ENTR"]

GENS = {
    "UWN": lambda N: gen_uwn(N, seed=123),
    "Logistic(r=3.82843,x0=0.5)": lambda N: gen_logistic(N, 3.82843, 0.5, 100),
    "Lorenz_x(sigma=10,b=8/3,r=28)": lambda N: gen_lorenz_x_resampled(N, 100.0, 0.1),
    "Harmonic(5 cycles)": lambda N: gen_harmonic_5_osc(N, 100.0, cycles=5),
}


def load_notebook_namespace():
    nb = json.loads(NB.read_text(encoding="utf8"))
    ns = {}
    for i in (1, 2, 3, 4, 5):  # signals, embedding, RP + RQA, timing wrapper, sweeps
        exec("".join(nb["cells"][i]["source"]), ns)
    return ns


def mine_eps(name, backend):
    x = GENS[name](4096)
    rows = []
    for p in EPS_PCTS:
        met, _ = rp_rqa(x, M, TAU, p, LMIN, VMIN, include_main_diag=False, backend=backend)
        rows.append({"series": name, "eps_percent": p, **met})
    return pd.DataFrame(rows)


def mine_len(name, backend):
    rows = []
    for N in LENGTHS:
        met, _ = rp_rqa(GENS[name](N), M, TAU, 50.0, LMIN, VMIN, include_main_diag=False,
                        backend=backend)
        rows.append({"series": name, **met})
    return pd.DataFrame(rows)


def compare(ref, mine, keys, label):
    ref = ref.copy()
    ref["series"] = ref["series"].str.replace("σ", "sigma")
    m = ref.merge(mine, on=keys, suffixes=("_ref", "_mine"))
    assert len(m) == len(ref) == len(mine), f"{label}: row mismatch {len(m)}/{len(ref)}/{len(mine)}"
    rows = []
    for c in METRICS + ["eps"]:
        d = (m[c + "_mine"] - m[c + "_ref"]).abs()
        rows.append({"table": label, "column": c, "max_abs_diff": d.max(), "rows": len(d)})
    return pd.DataFrame(rows), m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", default="numpy")
    args = ap.parse_args()
    warnings.filterwarnings("ignore")
    OUT.mkdir(parents=True, exist_ok=True)

    ns = load_notebook_namespace()
    # The notebook series names use the Greek sigma; map ours onto theirs for the merge.
    ref_eps, ref_len, mine_e, mine_l = [], [], [], []
    for name, gen in GENS.items():
        nb_name = name.replace("sigma", "σ")
        print(f"[{name}] notebook eps sweep", flush=True)
        ref_eps.append(ns["run_benchmark_for_series"](nb_name, gen(4096), M, TAU, EPS_PCTS, LMIN, VMIN))
        print(f"[{name}] notebook N sweep", flush=True)
        ref_len.append(ns["run_length_sweep"](nb_name, gen, LENGTHS, M, TAU, LMIN, VMIN))
        print(f"[{name}] jrp ({args.backend})", flush=True)
        mine_e.append(mine_eps(name, args.backend))
        mine_l.append(mine_len(name, args.backend))

    ref_eps, ref_len = pd.concat(ref_eps, ignore_index=True), pd.concat(ref_len, ignore_index=True)
    mine_e, mine_l = pd.concat(mine_e, ignore_index=True), pd.concat(mine_l, ignore_index=True)

    s1, m1 = compare(ref_eps, mine_e, ["series", "eps_percent", "N"], "eps_sweep")
    s2, m2 = compare(ref_len, mine_l, ["series", "N"], "N_sweep")
    summary = pd.concat([s1, s2], ignore_index=True)
    summary.to_csv(OUT / f"diff_vs_notebook_{args.backend}.csv", index=False)
    m1.to_csv(OUT / f"diff_vs_notebook_{args.backend}_eps_rows.csv", index=False)
    m2.to_csv(OUT / f"diff_vs_notebook_{args.backend}_N_rows.csv", index=False)
    print(summary.to_string(index=False))
    worst = summary["max_abs_diff"].max()
    print(f"\nWorst absolute difference ({args.backend}): {worst:.3e}")
    sys.exit(0 if worst <= 1e-6 else 1)


if __name__ == "__main__":
    main()
