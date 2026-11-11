"""How much do the joint metrics of the lab-ant x wild-ant pair move with the GHKSS settings the proposal leaves ambiguous?

Settings are (vector dimension, q) with delay 1 and 8 iterations; 'none' is unfiltered. For each: filter an 8192-sample context of each
series (parallel), cut the 4096-sample window from 5.0 s, scale to [0,1], choose tau/m per channel (AMI, FNN, m <= 10), set each
threshold to a 5% recurrence rate, and compute the JRQA metrics in float64 (rtl convention). Also the single-channel DET of each series.
Writes results/ghkss_sensitivity.md.
"""
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
from scipy.io import loadmat
from scipy.spatial.distance import pdist

from jrp.embedding import select_dim, select_tau, takens_embedding
from jrp.ghkss import ghkss
from jrp.jrp import ChannelParams
from jrp.pipeline import jrp_rqa

ROOT = Path(__file__).resolve().parents[1]
FS, N, PRE, CTX = 12000, 4096, 2048, 8192
S0 = 5 * FS
SETTINGS = [None, (5, 4), (5, 3), (5, 2), (6, 4), (7, 4), (7, 3), (7, 2)]
SERIES = ("purpureus_lab", "purpureus_wild")


def window(args):
    ctx, st = args
    if st is not None:
        ctx = ghkss(ctx, m=st[0], tau=1, q=st[1], k_min=30, iterations=8)
    return ctx[PRE:PRE + N]


def prep(x, rr=0.05):
    x = (x - x.min()) / (x.max() - x.min())
    tau = min(select_tau(x, maxtau=40), 16)
    m = min(select_dim(x, tau, max_dim=10, window=max(10, 3 * tau)), 10)
    V = takens_embedding(x, m, tau)
    return x, tau, m, float(np.quantile(pdist(V), rr))


def main():
    d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)
    ctxs = {}
    for nm in SERIES:
        c = d[nm][S0 - PRE:S0 - PRE + CTX].astype(float)
        ctxs[nm] = (c - c.min()) / (c.max() - c.min())
    del d
    jobs = [(ctxs[nm], st) for st in SETTINGS for nm in SERIES]
    t = time.time()
    with ProcessPoolExecutor(max_workers=4) as ex:
        wins = list(ex.map(window, jobs))
    print(f"filtered {len(jobs)} windows in {time.time() - t:.0f}s", flush=True)
    rows = ["| filter (dim, q) | lab (m,tau) | wild (m,tau) | JRR | JDET | JLAM | Lmax | ENTR | lab DET | wild DET |", "|---|---|---|---|---|---|---|---|---|---|"]
    for i, st in enumerate(SETTINGS):
        (xl, tl, ml, el), (xw, tw, mw, ew) = prep(wins[2 * i]), prep(wins[2 * i + 1])
        px, py = ChannelParams(ml, tl, eps=el), ChannelParams(mw, tw, eps=ew)
        r, _ = jrp_rqa(xl, xw, px, py, lmin=2, vmin=2, convention="rtl", normalise=False)
        # single-channel DET: joint of a channel with itself
        dl, _ = jrp_rqa(xl, xl, px, px, lmin=2, vmin=2, convention="rtl", normalise=False)
        dw, _ = jrp_rqa(xw, xw, py, py, lmin=2, vmin=2, convention="rtl", normalise=False)
        label = "none" if st is None else f"({st[0]}, {st[1]})"
        rows.append(f"| {label} | ({ml},{tl}) | ({mw},{tw}) | {r['JRR']:.5f} | {r['JDET']:.3f} | {r['JLAM']:.3f} | {r['Lmax']} | {r['ENTR']:.3f} | "
                    f"{dl['JDET']:.3f} | {dw['JDET']:.3f} |")
        print(rows[-1], flush=True)
    out = ["# GHKSS setting sensitivity: lab ant x wild ant (float64, 5% recurrence rate per channel)", ""] + rows
    (ROOT / "results" / "ghkss_sensitivity.md").write_text("\n".join(out) + "\n", encoding="utf8")


if __name__ == "__main__":
    main()
