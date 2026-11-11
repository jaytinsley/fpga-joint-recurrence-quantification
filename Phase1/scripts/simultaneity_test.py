"""If the lab ant and the two termite recordings were made at the same time, is there joint structure between them?

Test: for each pair, 30 aligned windows (4096 samples, every 5 s from 10 s to 155 s) are compared with windows of the second series taken at a
time offset of 30, 60 and 90 s (wrapping inside the same range), which cannot share a driver with the first. Per window pair: threshold per
channel at a 5% recurrence rate, common embedding m=5, tau=4, hardware (rtl) convention. Reported: JRR / (RRx RRy), JDET, JLAM, compared between
aligned and offset pairs (Mann-Whitney, descriptive because windows overlap in time). Unfiltered and ghkss d3 q2.
Writes results/simultaneity_test.md/.csv.
"""
import csv
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
from scipy.io import loadmat
from scipy.spatial.distance import pdist
from scipy.stats import mannwhitneyu

from jrp.embedding import takens_embedding
from jrp.jrp import ChannelParams
from jrp.pipeline import jrp_rqa

ROOT = Path(__file__).resolve().parents[1]
FS, N = 12000, 4096
VAR = {"lab ant": "purpureus_lab", "Darwin termite": "acinaciformis_Darwin", "Griffith termite": "acinaciformis_Griffith"}
PAIRS = [("lab ant", "Darwin termite"), ("lab ant", "Griffith termite"), ("Darwin termite", "Griffith termite")]
STARTS = [int((10 + 5 * k) * FS) for k in range(30)]
OFFS = [0, 6, 12, 18]          # in windows: 0, 30, 60, 90 s
M, TAU = 5, 4


def prep(x):
    x = (x - x.min()) / (x.max() - x.min())
    eps = float(np.quantile(pdist(takens_embedding(x, M, TAU)), 0.05))
    return x, ChannelParams(M, TAU, eps=eps)


def one(a):
    x, y = a
    x, px = prep(x); y, py = prep(y)
    j, _ = jrp_rqa(x, y, px, py, lmin=2, vmin=2, convention="rtl", normalise=False)
    rx, _ = jrp_rqa(x, x, px, px, lmin=2, vmin=2, convention="rtl", normalise=False)
    ry, _ = jrp_rqa(y, y, py, py, lmin=2, vmin=2, convention="rtl", normalise=False)
    return j["JRR"] / (rx["JRR"] * ry["JRR"]), j["JDET"], j["JLAM"]


def main():
    d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)
    series = {}
    for nm, var in VAR.items():
        raw = d[var].astype(float)
        series[(nm, "unfiltered")] = (raw - raw.min()) / (raw.max() - raw.min())
        series[(nm, "ghkss d3 q2")] = np.load(ROOT / "data" / "filtered_full" / f"{var}_d3q2.npy")
    del d
    jobs, keys = [], []
    for cond in ("unfiltered", "ghkss d3 q2"):
        for a, b in PAIRS:
            for k, st in enumerate(STARTS):
                for off in OFFS:
                    st2 = STARTS[(k + off) % 30]
                    jobs.append((series[(a, cond)][st:st + N].copy(), series[(b, cond)][st2:st2 + N].copy()))
                    keys.append((cond, a, b, k, off))
    with ProcessPoolExecutor(max_workers=4) as ex:
        res = list(ex.map(one, jobs, chunksize=8))
    with open(ROOT / "results" / "simultaneity_test.csv", "w", newline="") as f:
        w = csv.writer(f); w.writerow(["condition", "x", "y", "window", "offset_windows", "JRR_ratio", "JDET", "JLAM"])
        for k, r in zip(keys, res):
            w.writerow([*k, *r])
    out = ["# Aligned versus offset windows (lab ant, Darwin termite, Griffith termite)", "",
           "Aligned = same time in both recordings; offset = second series taken 30, 60 or 90 s away. m=5, tau=4, 5% recurrence rate per channel, N=4096.",
           "Median [first, third quartile]. p: Mann-Whitney aligned vs offset (descriptive; windows overlap in time).", "",
           "| condition | pair | measure | aligned | offset | p |", "|---|---|---|---|---|---|"]
    for cond in ("unfiltered", "ghkss d3 q2"):
        for a, b in PAIRS:
            for ci, nm in enumerate(("JRR/(RRx RRy)", "JDET", "JLAM")):
                al = np.array([r[ci] for k, r in zip(keys, res) if k[0] == cond and k[1] == a and k[2] == b and k[4] == 0])
                of = np.array([r[ci] for k, r in zip(keys, res) if k[0] == cond and k[1] == a and k[2] == b and k[4] != 0])
                p = mannwhitneyu(al, of).pvalue
                q = lambda v: f"{np.median(v):.4f} [{np.percentile(v, 25):.4f}, {np.percentile(v, 75):.4f}]"
                out.append(f"| {cond} | {a} x {b} | {nm} | {q(al)} | {q(of)} | {p:.2g} |")
    (ROOT / "results" / "simultaneity_test.md").write_text("\n".join(out) + "\n", encoding="utf8")
    print("\n".join(out))


if __name__ == "__main__":
    main()
