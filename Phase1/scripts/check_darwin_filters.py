"""Why does joint DET of Darwin x Griffith go from 0.74 (own GHKSS d5 q4) to 0.007 (PyPI ghkss d3 q2)? Compare the single-channel DET of the
5 s window at the embedding the pair pipeline chose (Darwin m=10, tau=6; Griffith m=10, tau=7 for d3q2), for three versions of the signal."""
from pathlib import Path

import numpy as np
from scipy.io import loadmat
from scipy.spatial.distance import pdist

from jrp.embedding import takens_embedding
from jrp.jrp import ChannelParams
from jrp.pipeline import jrp_rqa

ROOT = Path(__file__).resolve().parents[1]
S0, N = 60000, 4096
d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)


def sc(x, m, tau):
    x = (x - x.min()) / (x.max() - x.min())
    eps = float(np.quantile(pdist(takens_embedding(x, m, tau)), 0.05))
    p = ChannelParams(m, tau, eps=eps)
    r, _ = jrp_rqa(x, x, p, p, lmin=2, vmin=2, convention="rtl", normalise=False)
    return r["JDET"], r["ENTR"]


for nm, var, m, tau in (("Darwin", "acinaciformis_Darwin", 10, 6), ("Griffith", "acinaciformis_Griffith", 10, 7)):
    raw = d[var][S0:S0 + N].astype(float)
    old = np.load(ROOT / "data" / "filtered" / f"{var}_s{S0}.npy")
    new = np.load(ROOT / "data" / "filtered_full" / f"{var}_d3q2.npy")[S0:S0 + N]
    for lab, x in (("unfiltered", raw), ("own GHKSS d5 q4", old), ("PyPI ghkss d3 q2", new)):
        print(nm, lab, "m,tau", m, tau, "single-channel DET, ENTR = %.3f %.3f" % sc(x, m, tau), " std", round(float(np.std(x)), 5))
