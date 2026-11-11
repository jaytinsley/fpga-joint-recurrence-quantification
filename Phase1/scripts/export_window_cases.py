"""Golden cases for running the determinism study on the board: 15 windows per series (4096 samples every 10 s from 10 s to 150 s),
unfiltered (u) and ghkss d3 q2 (g), same samples in both channels, m=5, tau=4, 5% recurrence-rate threshold, gain to eps 0.3.
Writes golden/w<u|g>_<series>_<start_s>.* and golden/window_cases.txt (case names, one per line)."""
from pathlib import Path

import numpy as np
from scipy.io import loadmat
from scipy.spatial.distance import pdist

from jrp.embedding import takens_embedding
from jrp.golden import export_case
from jrp.jrp import ChannelParams

ROOT = Path(__file__).resolve().parents[1]
FS, N = 12000, 4096
SERIES = (("lab", "purpureus_lab"), ("wild", "purpureus_wild"), ("darwin", "acinaciformis_Darwin"), ("griffith", "acinaciformis_Griffith"))
STARTS = list(range(10, 151, 10))
d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)
names = []
for cond in ("u", "g"):
    for tag, var in SERIES:
        full = d[var].astype(float) if cond == "u" else np.load(ROOT / "data" / "filtered_full" / f"{var}_d3q2.npy")
        for s in STARTS:
            x = full[s * FS:s * FS + N]
            x = (x - x.min()) / (x.max() - x.min())
            eps = float(np.quantile(pdist(takens_embedding(x, 5, 4)), 0.05))
            g = float(np.clip(0.3 / eps, 1.0, 100.0))
            p = ChannelParams(5, 4, eps=eps * g)
            name = f"w{cond}_{tag}_{s}"
            export_case(name, ROOT / "golden", x * g, x * g, p, p, lmin=2, vmin=2,
                        source={"dataset": var, "start_s": s, "filter": "none" if cond == "u" else "ghkss d3 q2", "target_rr": 0.05, "gain": g})
            names.append(name)
(ROOT / "golden" / "window_cases.txt").write_text("\n".join(names) + "\n")
print(len(names), "cases")
