import numpy as np
from scipy.io import loadmat
import ghkss as G
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)
S0, PRE, CTX = 60000, 2048, 8192
c = d["purpureus_lab"][S0 - PRE:S0 - PRE + CTX].astype(float); c = (c - c.min()) / (c.max() - c.min())
def run(dim, q, **kw):
    cfg = G.FilterConfig(iterations=8, delay_vector_pattern=list(range(dim)), projection_dimension=q, minimum_neighbour_count=30, **kw)
    return G.filter_ghkss(c.reshape(-1, 1), cfg).ravel()
for dim, q, kw in ((3, 4, {}), (3, 3, {}), (3, 2, {}), (4, 3, {}), (5, 4, {}), (5, 4, dict(tisean_epsilon_widening=True, neighbour_epsilon=1e-3)),
                   (3, 2, dict(tisean_epsilon_widening=True, neighbour_epsilon=1e-3)), (4, 3, dict(euclidean_norm=True))):
    try:
        y = run(dim, q, **kw); print(dim, q, kw, "rms change", round(float(np.sqrt(np.mean((c - y) ** 2))), 5))
    except Exception as e:
        print(dim, q, kw, "ERROR", str(e)[:150])
