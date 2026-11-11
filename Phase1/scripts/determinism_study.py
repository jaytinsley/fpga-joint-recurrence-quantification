"""Which recordings are more or less deterministic? Single-channel recurrence analysis of the four series, with and without GHKSS noise reduction.

For each series (lab ant, wild ant, Darwin termite, Griffith termite) and each condition (unfiltered, GHKSS (dim,q) from the PyPI ghkss package):
30 windows of 4096 samples (10 s to 155 s, every 5 s), scaled to [0,1], common embeddings, threshold = 5% recurrence rate per window,
lmin = vmin = 2, hardware (rtl) convention, no Theiler corridor. A single channel is the joint plot of a channel with itself.
Each window is paired with one phase-randomised surrogate (same amplitude spectrum, random phases); the excess DET = DET - DET(surrogate)
removes what the power spectrum alone explains.
Writes results/determinism_study.{md,csv} and results/figures/determinism_study.png.
"""
import csv
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy.io import loadmat
from scipy.spatial.distance import pdist
from scipy.stats import mannwhitneyu

from jrp.embedding import takens_embedding
from jrp.jrp import ChannelParams
from jrp.pipeline import jrp_rqa

ROOT = Path(__file__).resolve().parents[1]
FS, N = 12000, 4096
SERIES = {"lab ant": "purpureus_lab", "wild ant": "purpureus_wild", "Darwin termite": "acinaciformis_Darwin", "Griffith termite": "acinaciformis_Griffith"}
STARTS = [int((10 + 5 * k) * FS) for k in range(30)]
EMB = [(5, 4), (3, 3)]
CONDS = [None, (3, 2), (4, 3), (5, 4)]
PRIMARY = (3, 2)


def cname(c):
    return "unfiltered" if c is None else f"GHKSS d{c[0]} q{c[1]}"


def phase_randomise(x, rng):
    X = np.fft.rfft(x)
    ph = rng.uniform(0, 2 * np.pi, len(X)); ph[0] = 0
    if len(x) % 2 == 0:
        ph[-1] = 0
    return np.fft.irfft(np.abs(X) * np.exp(1j * ph), n=len(x))


def det(x, m, tau):
    x = (x - x.min()) / (x.max() - x.min())
    eps = float(np.quantile(pdist(takens_embedding(x, m, tau)), 0.05))
    p = ChannelParams(m, tau, eps=eps)
    r, _ = jrp_rqa(x, x, p, p, lmin=2, vmin=2, convention="rtl", normalise=False)
    return r


def one(args):
    x, (m, tau), seed = args
    rng = np.random.default_rng(seed)
    r = det(x, m, tau)
    s = det(phase_randomise(x, rng), m, tau)
    return r["JDET"], r["JLAM"], r["Lmax"], r["ENTR"], s["JDET"]


def main():
    d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)
    full = {}
    for name, var in SERIES.items():
        raw = d[var].astype(float)
        lo, hi = raw.min(), raw.max()
        full[(name, None)] = (raw - lo) / (hi - lo)
        for c in CONDS[1:]:
            full[(name, c)] = np.load(ROOT / "data" / "filtered_full" / f"{var}_d{c[0]}q{c[1]}.npy")
    del d
    jobs, keys = [], []
    for (name, c), x in full.items():
        for st in STARTS:
            for e in EMB:
                jobs.append((x[st:st + N].copy(), e, 1000 * list(SERIES).index(name) + st // FS)); keys.append((name, c, st / FS, e))
    with ProcessPoolExecutor(max_workers=4) as ex:
        res = list(ex.map(one, jobs, chunksize=8))
    with open(ROOT / "results" / "determinism_study.csv", "w", newline="") as f:
        w = csv.writer(f); w.writerow(["series", "condition", "start_s", "m", "tau", "DET", "LAM", "Lmax", "ENTR", "DET_surrogate"])
        for (n, c, s, e), r in zip(keys, res):
            w.writerow([n, cname(c), s, e[0], e[1], *r])

    def get(n, c, e):
        return np.array([r for (nn, cc, s, ee), r in zip(keys, res) if nn == n and cc == c and ee == e])

    out = ["# Determinism study: single-channel recurrence, with and without GHKSS (PyPI ghkss 1.0.3)", "",
           "30 windows of 4096 samples per series (10 s to 155 s every 5 s), 5% recurrence rate, one phase-randomised surrogate per window.",
           "Median [first, third quartile]. Excess DET = DET minus the DET of the phase-randomised surrogate. One recording per series.", ""]
    names = list(SERIES)
    for e in EMB:
        for c in CONDS:
            out += [f"## m={e[0]}, tau={e[1]}, {cname(c)}", "", "| series | DET | LAM | ENTR | Lmax | surrogate DET | excess DET |", "|---|---|---|---|---|---|---|"]
            for n in names:
                a = get(n, c, e)
                q = lambda v: f"{np.median(v):.3f} [{np.percentile(v, 25):.3f}, {np.percentile(v, 75):.3f}]"
                out.append(f"| {n} | {q(a[:, 0])} | {q(a[:, 1])} | {q(a[:, 3])} | {np.median(a[:, 2]):.0f} | {q(a[:, 4])} | {q(a[:, 0] - a[:, 4])} |")
            out.append("")
    # pairwise comparisons on the primary embedding and the primary filter plus unfiltered
    out += ["## Pairwise comparison of DET (m=5, tau=4): fraction of window pairs where the first series has the larger DET, and Mann-Whitney p", "",
            "Windows overlap in time and are not independent, so the p values are descriptive only.", "",
            "| pair | " + " | ".join(cname(c) for c in CONDS) + " |", "|---|" + "---|" * len(CONDS)]
    pairs = [("lab ant", "wild ant"), ("Darwin termite", "Griffith termite"), ("lab ant", "Darwin termite"), ("lab ant", "Griffith termite"),
             ("wild ant", "Darwin termite"), ("wild ant", "Griffith termite")]
    for a, b in pairs:
        cells = []
        for c in CONDS:
            x, y = get(a, c, EMB[0])[:, 0], get(b, c, EMB[0])[:, 0]
            u, p = mannwhitneyu(x, y, alternative="two-sided")
            cells.append(f"{u / (len(x) * len(y)):.2f}, p={p:.1e}")
        out.append(f"| {a} vs {b} | " + " | ".join(cells) + " |")
    out.append("")
    (ROOT / "results" / "determinism_study.md").write_text("\n".join(out) + "\n", encoding="utf8")

    fig, axs = plt.subplots(2, len(CONDS), figsize=(14, 6.5), sharey="row")
    for ci, c in enumerate(CONDS):
        for ri, (idx, lab) in enumerate(((0, "DET"), (None, "excess DET"))):
            ax = axs[ri, ci]
            data = [get(n, c, EMB[0])[:, 0] if idx == 0 else get(n, c, EMB[0])[:, 0] - get(n, c, EMB[0])[:, 4] for n in names]
            ax.boxplot(data, tick_labels=[n.replace(" ", "\n") for n in names])
            ax.set_title(f"{lab}, {cname(c)}", fontsize=9); ax.tick_params(labelsize=8)
    fig.suptitle("Single-channel determinism, m=5, tau=4, 5% recurrence rate, 30 windows per series")
    fig.tight_layout(); fig.savefig(ROOT / "results" / "figures" / "determinism_study.png", dpi=130)
    print("\n".join(out))


if __name__ == "__main__":
    main()
