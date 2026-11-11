"""Embedding study of purpureus_lab (single separate recording, 12 kHz) in the style recommended by Marwan et al. (2007, 2011).

For several candidate segments: AMI curve and first minimum (delay), false nearest neighbours vs m (Theiler window = autocorrelation
time), noise estimate, the three threshold rules (fixed recurrence rate, percent of diameter, 5 sigma noise), a state-space plot of the
embedding and its recurrence plot, and single-channel RQA. Writes results/figures/purpureus_lab_embedding.png and prints a table.
Usage: python scripts/embed_purpureus_lab.py [--start-s 5.0] [--n 4096] [--decimate 1]
"""
import argparse
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy.io import loadmat
from scipy.signal import decimate as sp_decimate

from jrp.embedding import ami, first_local_minimum, fnn_fractions, takens_embedding
from jrp.jrp import recurrence_matrix_blocked
from jrp.rqa import rqa_metrics

ROOT = Path(__file__).resolve().parents[1]
FS = 12000


def acf_time(x):
    x = x - x.mean()
    c = np.correlate(x, x, "full")[len(x) - 1:]
    c /= c[0]
    k = np.flatnonzero(c < 1 / np.e)
    return int(k[0]) if len(k) else len(x) // 10


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--start-s", type=float, default=5.0)
    a.add_argument("--n", type=int, default=4096)
    a.add_argument("--decimate", type=int, default=1)
    a.add_argument("--maxm", type=int, default=10)
    args = a.parse_args()
    d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)
    full = d["purpureus_lab"].astype(np.float64)
    fs = FS / args.decimate
    if args.decimate > 1:
        full = sp_decimate(full, args.decimate, ftype="fir", zero_phase=True)
    s0 = int(args.start_s * fs)
    x = full[s0:s0 + args.n]
    x = (x - x.min()) / (x.max() - x.min())
    # observational noise from the quietest tenth of 64-sample blocks (std of first differences / sqrt 2)
    blocks = x[: len(x) // 64 * 64].reshape(-1, 64)
    sig_noise = float(np.median(np.std(np.diff(blocks, axis=1), axis=1)) / np.sqrt(2))
    th = acf_time(x)
    mi = ami(x, maxtau=60, bins=32)
    tau = first_local_minimum(mi)
    tau = tau if tau > 0 else int(np.argmin(mi[1:]) + 1)
    dims = list(range(1, args.maxm + 1))
    fnn = fnn_fractions(x, tau, dims, window=max(th, (args.maxm - 1) * tau // 2))
    ok = np.flatnonzero(fnn < 0.05)
    m = dims[ok[0]] if len(ok) else args.maxm
    print(f"segment {args.start_s}s +{args.n} samples at {fs:g} Hz, scaled to [0,1]")
    print(f"noise sigma (quiet-block estimate) {sig_noise:.5f}; ACF 1/e time {th} samples; AMI first min tau {tau}")
    print("FNN fraction by m:", " ".join(f"{m_}:{f:.3f}" for m_, f in zip(dims, fnn)))
    print(f"chosen m = {m}")
    V = takens_embedding(x, m, tau)
    n = len(V)
    # distance sample for thresholds
    idx = np.random.default_rng(0).choice(n, 800, replace=False)
    D = np.sqrt(((V[idx][:, None, :] - V[idx][None, :, :]) ** 2).sum(-1))
    dmax = D.max()
    iu = np.triu_indices(len(idx), 1)
    pairs = D[iu]
    rules = {"RR=1%": np.percentile(pairs, 1), "RR=5%": np.percentile(pairs, 5), "RR=10%": np.percentile(pairs, 10),
             "10% of max": 0.10 * dmax, "5% of max": 0.05 * dmax, "5 sigma noise": 5 * sig_noise * np.sqrt(m)}
    print(f"max sampled distance {dmax:.4f}")
    rows = []
    for k, eps in rules.items():
        R = recurrence_matrix_blocked(V, eps)
        met = rqa_metrics(R, lmin=2, vmin=2, theiler=(m - 1) * tau) if "theiler" in rqa_metrics.__code__.co_varnames else rqa_metrics(R, lmin=2, vmin=2)
        rr = R.mean()
        rows.append((k, eps, rr, met))
        print(f"{k:14s} eps {eps:.4f}  RR {rr:.4f}  DET {met.get('DET', float('nan')):.3f}  LAM {met.get('LAM', float('nan')):.3f}  "
              f"Lmax {met.get('Lmax', met.get('L_max', float('nan')))}")
    fig = plt.figure(figsize=(13, 8))
    ax = fig.add_subplot(2, 3, 1); ax.plot(np.arange(len(mi)), mi, "o-", ms=3); ax.axvline(tau, c="r", ls="--"); ax.set_title(f"AMI (tau={tau})"); ax.set_xlabel("lag")
    ax = fig.add_subplot(2, 3, 2); ax.plot(dims, fnn, "o-"); ax.axhline(0.05, c="k", ls=":"); ax.axvline(m, c="r", ls="--"); ax.set_title(f"false nearest neighbours (m={m})"); ax.set_xlabel("m")
    ax = fig.add_subplot(2, 3, 3); t = np.arange(len(x)) / fs; ax.plot(t, x, lw=0.5); ax.set_title("segment (scaled)"); ax.set_xlabel("s")
    # state space: first three components of the embedding, and PCA projection
    Vc = V - V.mean(0)
    U, S, Wt = np.linalg.svd(Vc, full_matrices=False)
    P = Vc @ Wt[:3].T
    ax = fig.add_subplot(2, 3, 4, projection="3d"); ax.plot(P[:, 0], P[:, 1], P[:, 2], lw=0.3); ax.set_title(f"state space, first 3 PCs (m={m}, tau={tau})")
    ax = fig.add_subplot(2, 3, 5); ax.plot(S ** 2 / (S ** 2).sum(), "o-"); ax.set_title("embedding singular spectrum"); ax.set_xlabel("component")
    ax = fig.add_subplot(2, 3, 6); R = recurrence_matrix_blocked(V, rules["RR=5%"]); ax.imshow(R[:1500, :1500], cmap="binary", origin="lower"); ax.set_title("RP, RR=5% rule (first 1500)")
    fig.tight_layout()
    out = ROOT / "results" / "figures" / "purpureus_lab_embedding.png"
    fig.savefig(out, dpi=130)
    print("figure", out)


if __name__ == "__main__":
    main()
