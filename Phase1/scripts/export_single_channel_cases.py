"""Golden cases for the single-channel board check: one unfiltered 4096-sample window per series (default 60 s), the same samples in both
channels (the joint plot of a channel with itself is its recurrence plot), m=5, tau=4, 5% recurrence-rate threshold, gain to eps 0.3.
Writes golden/sc_<series>.*"""
import sys
from pathlib import Path

import numpy as np
from scipy.io import loadmat
from scipy.spatial.distance import pdist

from jrp.embedding import takens_embedding
from jrp.golden import export_case
from jrp.jrp import ChannelParams

ROOT = Path(__file__).resolve().parents[1]
S0 = int(float(sys.argv[1] if len(sys.argv) > 1 else 60) * 12000)
d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)
for tag, var in (("lab", "purpureus_lab"), ("wild", "purpureus_wild"), ("darwin", "acinaciformis_Darwin"), ("griffith", "acinaciformis_Griffith")):
    x = d[var][S0:S0 + 4096].astype(float)
    x = (x - x.min()) / (x.max() - x.min())
    eps = float(np.quantile(pdist(takens_embedding(x, 5, 4)), 0.05))
    g = float(np.clip(0.3 / eps, 1.0, 100.0))
    p = ChannelParams(5, 4, eps=eps * g)
    side = export_case(f"sc_{tag}", ROOT / "golden", x * g, x * g, p, p, lmin=2, vmin=2,
                       source={"dataset": var, "start_s": S0 / 12000, "filter": "none", "target_rr": 0.05, "gain": g})
    print(f"sc_{tag}", {k: round(v, 5) if isinstance(v, float) else v for k, v in side["expected_metrics"].items()}, flush=True)
