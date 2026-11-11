"""GHKSS with vector dimension 4 and manifold dimension 3 (delay 1, 8 iterations), lab ant x wild ant, same pipeline as ghkss_sensitivity.py.
Writes results/ghkss_m4q3.md.
"""
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

from scipy.io import loadmat

import ghkss_sensitivity as g

if __name__ == "__main__":
    g.SETTINGS = [(4, 3)]
    d = loadmat(g.ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)
    ctxs = {}
    for nm in g.SERIES:
        c = d[nm][g.S0 - g.PRE:g.S0 - g.PRE + g.CTX].astype(float)
        ctxs[nm] = (c - c.min()) / (c.max() - c.min())
    del d
    jobs = [(ctxs[nm], (4, 3)) for nm in g.SERIES]
    with ProcessPoolExecutor(max_workers=2) as ex:
        wins = list(ex.map(g.window, jobs))
    from jrp.jrp import ChannelParams
    from jrp.pipeline import jrp_rqa
    (xl, tl, ml, el), (xw, tw, mw, ew) = g.prep(wins[0]), g.prep(wins[1])
    px, py = ChannelParams(ml, tl, eps=el), ChannelParams(mw, tw, eps=ew)
    r, _ = jrp_rqa(xl, xw, px, py, lmin=2, vmin=2, convention="rtl", normalise=False)
    dl, _ = jrp_rqa(xl, xl, px, px, lmin=2, vmin=2, convention="rtl", normalise=False)
    dw, _ = jrp_rqa(xw, xw, py, py, lmin=2, vmin=2, convention="rtl", normalise=False)
    row = (f"| (4, 3) | ({ml},{tl}) | ({mw},{tw}) | {r['JRR']:.5f} | {r['JDET']:.3f} | {r['JLAM']:.3f} | {r['Lmax']} | {r['ENTR']:.3f} | "
           f"{dl['JDET']:.3f} | {dw['JDET']:.3f} |")
    print(row)
    (g.ROOT / "results" / "ghkss_m4q3.md").write_text(
        "| filter (dim, q) | lab (m,tau) | wild (m,tau) | JRR | JDET | JLAM | Lmax | ENTR | lab DET | wild DET |\n|---|---|---|---|---|---|---|---|---|---|\n" + row + "\n",
        encoding="utf8")
