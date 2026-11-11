"""Exploratory single-channel recurrence analysis of the four recordings: 30 windows of 4096 samples per series (10 s to 155 s, every 5 s),
unfiltered, scaled to [0,1], common embeddings (m=5, tau=4) and (m=3, tau=3), threshold = 5% recurrence rate per window, lmin = vmin = 2,
hardware (rtl) convention, no Theiler corridor. A single channel is the joint plot of a channel with itself.
Writes results/single_channel_windows.md, .csv and figures/single_channel_windows.png.
"""
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy.io import loadmat
from scipy.spatial.distance import pdist

from jrp.embedding import takens_embedding
from jrp.jrp import ChannelParams
from jrp.pipeline import jrp_rqa

ROOT = Path(__file__).resolve().parents[1]
FS, N = 12000, 4096
SERIES = {"lab ant": "purpureus_lab", "wild ant": "purpureus_wild", "Darwin termite": "acinaciformis_Darwin", "Griffith termite": "acinaciformis_Griffith"}
STARTS = [int((10 + 5 * k) * FS) for k in range(30)]
EMB = [(5, 4), (3, 3)]


def one(args):
    x, (m, tau) = args
    x = (x - x.min()) / (x.max() - x.min())
    eps = float(np.quantile(pdist(takens_embedding(x, m, tau)), 0.05))
    p = ChannelParams(m, tau, eps=eps)
    r, _ = jrp_rqa(x, x, p, p, lmin=2, vmin=2, convention="rtl", normalise=False)
    return r["JRR"], r["JDET"], r["JLAM"], r["Lmax"], r["ENTR"]


def main():
    d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)
    jobs, keys = [], []
    for name, var in SERIES.items():
        for st in STARTS:
            for e in EMB:
                jobs.append((d[var][st:st + N].astype(float), e)); keys.append((name, st / FS, e))
    del d
    with ProcessPoolExecutor(max_workers=4) as ex:
        res = list(ex.map(one, jobs, chunksize=4))
    import csv
    with open(ROOT / "results" / "single_channel_windows.csv", "w", newline="") as f:
        w = csv.writer(f); w.writerow(["series", "start_s", "m", "tau", "RR", "DET", "LAM", "Lmax", "ENTR"])
        for (n, s, e), r in zip(keys, res):
            w.writerow([n, s, e[0], e[1], *r])
    out = ["# Single-channel recurrence, 30 windows per series (unfiltered, 5% recurrence rate, N=4096)", "",
           "Median [first, third quartile] over windows. One recording (one individual) per series.", ""]
    fig, axs = plt.subplots(len(EMB), 3, figsize=(12, 6.5))
    for ei, e in enumerate(EMB):
        out += [f"## m={e[0]}, tau={e[1]}", "", "| series | DET | LAM | ENTR | Lmax |", "|---|---|---|---|---|"]
        data = {n: np.array([r for (nn, s, ee), r in zip(keys, res) if nn == n and ee == e]) for n in SERIES}
        for n, a in data.items():
            q = lambda c: f"{np.median(a[:, c]):.3f} [{np.percentile(a[:, c], 25):.3f}, {np.percentile(a[:, c], 75):.3f}]"
            out.append(f"| {n} | {q(1)} | {q(2)} | {q(4)} | {np.median(a[:, 3]):.0f} |")
        out.append("")
        for ci, (c, lab) in enumerate(((1, "DET"), (2, "LAM"), (4, "ENTR"))):
            ax = axs[ei, ci]; ax.boxplot([data[n][:, c] for n in SERIES], tick_labels=[n.replace(" ", "\n") for n in SERIES], showfliers=True)
            ax.set_title(f"{lab}, m={e[0]}, tau={e[1]}")
    fig.tight_layout(); fig.savefig(ROOT / "results" / "figures" / "single_channel_windows.png", dpi=130)
    (ROOT / "results" / "single_channel_windows.md").write_text("\n".join(out) + "\n", encoding="utf8")
    print("\n".join(out))


if __name__ == "__main__":
    main()
