"""GHKSS-filter the four full series (2,097,152 samples) with the PyPI ghkss package for several (vector dimension, q) settings.
Series are min-max scaled to [0,1] first. delay 1, 8 iterations, 30 neighbours, max norm, 16384-sample batches.
Writes data/filtered_full/<series>_d<dim>q<q>.npy (float32 is not used; float64)."""
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
from scipy.io import loadmat

from jrp.ghkss import ghkss_pkg

ROOT = Path(__file__).resolve().parents[1]
SERIES = ["purpureus_lab", "purpureus_wild", "acinaciformis_Darwin", "acinaciformis_Griffith"]
SETTINGS = [(3, 2), (4, 3), (5, 4), (5, 3)]
OUT = ROOT / "data" / "filtered_full"


def job(a):
    nm, dim, q, x = a
    f = OUT / f"{nm}_d{dim}q{q}.npy"
    if not f.exists():
        np.save(f, ghkss_pkg(x, dim, q, iterations=8, k_min=30, batch_size=16384))
    return f.name


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)
    xs = {nm: d[nm].astype(float) for nm in SERIES}
    xs = {nm: (x - x.min()) / (x.max() - x.min()) for nm, x in xs.items()}
    del d
    jobs = [(nm, dim, q, xs[nm]) for (dim, q) in SETTINGS for nm in SERIES]
    with ProcessPoolExecutor(max_workers=4) as ex:
        for n in ex.map(job, jobs):
            print("done", n, flush=True)


if __name__ == "__main__":
    main()
