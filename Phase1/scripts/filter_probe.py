"""Probe the GHKSS stage the proposal specifies (m=3, delay 1, q=4, 8 iterations; Oberst, Lai, Evans 2026) on the four series.
q must be below the vector dimension, so m=3, q=4 cannot be used literally; the smallest TISEAN-style choice that keeps q=4 is dimension 5.
Reports noise level and AMI/FNN before and after, for each series, on a 16384-sample context from 5.0 s.
"""
import sys
import time
from pathlib import Path

import numpy as np
from scipy.io import loadmat

from jrp.embedding import ami, first_local_minimum, fnn_fractions
from jrp.ghkss import ghkss

ROOT = Path(__file__).resolve().parents[1]
FS = 12000
dim = int(sys.argv[1]) if len(sys.argv) > 1 else 5
q = int(sys.argv[2]) if len(sys.argv) > 2 else 4
its = int(sys.argv[3]) if len(sys.argv) > 3 else 8
d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)


def sig_noise(x):
    b = x[: len(x) // 64 * 64].reshape(-1, 64)
    return float(np.median(np.std(np.diff(b, axis=1), axis=1)) / np.sqrt(2))


for name in ("purpureus_lab", "purpureus_wild", "acinaciformis_Darwin", "acinaciformis_Griffith"):
    x = d[name][5 * FS:5 * FS + 16384].astype(float)
    x = (x - x.min()) / (x.max() - x.min())
    t = time.time()
    y = ghkss(x, m=dim, tau=1, q=q, k_min=30, iterations=its)
    el = time.time() - t
    out = []
    for tag, s in (("raw", x), ("ghkss", y)):
        mi = ami(s[:4096], maxtau=40)
        tau = first_local_minimum(mi)
        tau = tau if tau > 0 else int(np.argmin(mi[1:]) + 1)
        f = fnn_fractions(s[:4096], tau, list(range(1, 11)), window=max(10, 3 * tau))
        ok = np.flatnonzero(f < 0.05)
        out.append(f"{tag}: rms {s.std():.4f} noise {sig_noise(s):.5f} tau {tau} m {int(ok[0]) + 1 if len(ok) else '>10'} fnn@3 {f[2]:.2f}")
    print(f"{name:24s} ({el:.0f}s) | " + " | ".join(out), flush=True)
