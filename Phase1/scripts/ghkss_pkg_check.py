"""Check the PyPI ghkss package (C++, TISEAN drop-in) against jrp.ghkss on the lab ant and time it."""
import time
from pathlib import Path

import numpy as np
from scipy.io import loadmat

import ghkss as G
from jrp.ghkss import ghkss as mine

ROOT = Path(__file__).resolve().parents[1]
d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)
FS, PRE, CTX, S0 = 12000, 2048, 8192, 5 * 12000
c = d["purpureus_lab"][S0 - PRE:S0 - PRE + CTX].astype(float)
c = (c - c.min()) / (c.max() - c.min())


def pkg(x, dim, q, its=8, k=30, tis=False):
    cfg = G.FilterConfig(iterations=its, delay_vector_pattern=list(range(dim)), projection_dimension=q,
                         minimum_neighbour_count=k, tisean_epsilon_widening=tis)
    return G.filter_ghkss(x.reshape(-1, 1), cfg).ravel()


t = time.time(); y = pkg(c, 5, 4); print("pkg (5,4) time", round(time.time() - t, 2), "s", "len", len(y))
t = time.time(); z = mine(c, m=5, tau=1, q=4, k_min=30, iterations=8); print("mine (5,4) time", round(time.time() - t, 1), "s")
print("noise change pkg  rms(x-y)", np.sqrt(np.mean((c - y) ** 2)))
print("noise change mine rms(x-z)", np.sqrt(np.mean((c - z) ** 2)))
print("pkg vs mine rms diff", np.sqrt(np.mean((y - z) ** 2)), " corr", np.corrcoef(y - c, z - c)[0, 1])
for dim, q in ((3, 2), (4, 3), (5, 4)):
    for tis in (False, True):
        y = pkg(c, dim, q, tis=tis)
        print(dim, q, "tisean_widening", tis, "rms change", np.sqrt(np.mean((c - y) ** 2)))
