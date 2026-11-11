"""Proposal pipeline on cops_iridomyrmex.mat: GHKSS filter -> segment -> per-channel (tau, m) -> fixed-recurrence-rate threshold -> golden case.

Per series: an 8192-sample context starting 2048 samples before the analysis window is GHKSS-filtered (dimension 5, delay 1, q 4,
8 iterations: the proposal's m=3, d=1, q=4 with the smallest vector dimension that admits q=4; see docs), then the 4096-sample window is
cut and scaled to [0,1]. The threshold of each channel is the distance at which 5% of its own embedded pairs recur (Marwan et al. 2007;
AccRQA: RR 1-5%), passed as an absolute eps. Pairs of SEPARATE recordings, so the joint plot is a validation and baseline, not coupling.
Usage: python scripts/export_filtered_pairs.py [--start-s 5.0] [--rr 0.05] [--hw-max-m 10]
Writes golden/insect_f_<a>_<b>.* and data/filtered/<series>_s<start>.npy
"""
import argparse
import json
from pathlib import Path

import numpy as np
from scipy.io import loadmat
from scipy.spatial.distance import pdist

from jrp.embedding import select_dim, select_tau, takens_embedding
from jrp.ghkss import ghkss
from jrp.golden import export_case
from jrp.jrp import ChannelParams

ROOT = Path(__file__).resolve().parents[1]
FS, N, CTX_PRE, CTX = 12000, 4096, 2048, 8192
SERIES = {"darwin": "acinaciformis_Darwin", "griffith": "acinaciformis_Griffith", "lab": "purpureus_lab", "wild": "purpureus_wild"}
PAIRS = [("lab", "wild"), ("darwin", "griffith"), ("darwin", "lab"), ("griffith", "lab"), ("darwin", "wild"), ("griffith", "wild")]


def filtered_window(full, s0, cache):
    if cache.exists():
        return np.load(cache)
    ctx = full[s0 - CTX_PRE:s0 - CTX_PRE + CTX].astype(float)
    lo, hi = ctx.min(), ctx.max()
    y = ghkss((ctx - lo) / (hi - lo), m=5, tau=1, q=4, k_min=30, iterations=8)
    seg = y[CTX_PRE:CTX_PRE + N]
    np.save(cache, seg)
    return seg


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--start-s", type=float, default=5.0)
    a.add_argument("--rr", type=float, default=0.05)
    a.add_argument("--hw-max-m", type=int, default=10)
    a.add_argument("--no-filter", action="store_true")
    a.add_argument("--ghkss", default=None, help="use the PyPI-ghkss filtered full series for 'dim,q' (data/filtered_full), e.g. 3,2")
    a.add_argument("--target-eps", type=float, default=0.3, help="scale each channel so its threshold is about this")
    args = a.parse_args()
    d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)
    s0 = int(args.start_s * FS)
    (ROOT / "data" / "filtered").mkdir(parents=True, exist_ok=True)
    sig, sel = {}, {}
    for k, nm in SERIES.items():
        if args.no_filter:
            x = d[nm][s0:s0 + N].astype(float)
        elif args.ghkss:
            dim, q = (int(v) for v in args.ghkss.split(","))
            x = np.load(ROOT / "data" / "filtered_full" / f"{nm}_d{dim}q{q}.npy")[s0:s0 + N]
        else:
            x = filtered_window(d[nm], s0, ROOT / "data" / "filtered" / f"{nm}_s{s0}.npy")
        x = (x - x.min()) / (x.max() - x.min())
        tau = min(select_tau(x, maxtau=40), 16)
        m = min(select_dim(x, tau, max_dim=10, window=max(10, 3 * tau)), args.hw_max_m)
        V = takens_embedding(x, m, tau)
        eps = float(np.quantile(pdist(V), args.rr))
        # Q8.24 stores eps^2 with resolution 6e-8: a threshold of 0.004 would be coarse. Metrics do not depend on scale, so
        # scale the channel (and eps) to a threshold of about 0.3, within the +/-128 sample range (gain at most 100).
        gain = float(np.clip(args.target_eps / eps, 1.0, 100.0))
        x, eps = x * gain, eps * gain
        sig[k], sel[k] = x, dict(series=nm, tau=int(tau), m=int(m), eps=eps, gain=gain)
        print(f"{k:9s} tau {tau:2d} m {m:2d} gain {gain:6.1f} eps(RR {args.rr:.0%}) {eps:.5f}", flush=True)
    tag = "insect_u" if args.no_filter else ("insect_g" + args.ghkss.replace(",", "") if args.ghkss else "insect_f")
    for ka, kb in PAIRS:
        x, y = sig[ka], sig[kb]
        px = ChannelParams(sel[ka]["m"], sel[ka]["tau"], eps=sel[ka]["eps"])
        py = ChannelParams(sel[kb]["m"], sel[kb]["tau"], eps=sel[kb]["eps"])
        name = f"{tag}_{ka}_{kb}"
        src = {"dataset": "cops_iridomyrmex.mat (separate recordings)", "fs_Hz": FS, "start_s": args.start_s,
               "filter": "none" if args.no_filter else (f"PyPI ghkss 1.0.3 dim,q={args.ghkss} delay1 iter8 k30 maxnorm, 16384-sample batches" if args.ghkss else "ghkss dim5 delay1 q4 iter8"), "target_rr": args.rr}
        side = export_case(name, ROOT / "golden", x, y, px, py, lmin=2, vmin=2, source=src)
        (ROOT / "golden" / f"{name}_selection.json").write_text(json.dumps({"x": sel[ka], "y": sel[kb], "source": src}, indent=2))
        print(name, side["expected_metrics"], flush=True)


if __name__ == "__main__":
    main()
