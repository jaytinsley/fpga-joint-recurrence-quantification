"""Random recurrence matrices for the K = 2 extractor testbench (tb_k2_extract.sv).

For each case writes build/k2rand/<name>_beats.hex (one K = 2 beat per line, 8 hex digits,
{i[13:0], j0[13:0], f1, f0, v1} = i << 17 | j0 << 3 | f1 << 2 | f0 << 1 | v1) and
<name>_counters.hex (same word layout as gen_counters_hex.py) from the Phase 1 integer model
jrp.rqa.rtl_counters. Also writes build/k2rand/manifest.txt: "<name> <n>" per line.
Usage: python gen_k2_random.py [seed]
"""
import sys
from pathlib import Path

import numpy as np

P3 = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(P3.parent / "Phase1" / "src"))
from jrp.rqa import rtl_counters  # noqa: E402

OUT = P3 / "build" / "k2rand"
OUT.mkdir(parents=True, exist_ok=True)
seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
rng = np.random.default_rng(seed)


def make(kind, n):
    if kind == "ones":
        return np.ones((n, n), dtype=np.uint8)
    if kind == "zeros":
        return np.zeros((n, n), dtype=np.uint8)
    if kind.startswith("iid"):
        p = float(kind[3:])
        u = np.triu(rng.random((n, n)) < p, 1)
        return (u | u.T | np.eye(n, dtype=bool)).astype(np.uint8)
    if kind == "walk":
        x = np.cumsum(rng.standard_normal(n))
        eps = 0.6 * np.std(np.diff(x)) * 2
        return (np.abs(x[:, None] - x[None, :]) < eps).astype(np.uint8)
    if kind == "asym":
        return (rng.random((n, n)) < 0.4).astype(np.uint8)
    if kind == "bands":
        i = np.arange(n)
        return (np.abs(i[:, None] - i[None, :]) % 5 < 2).astype(np.uint8)
    raise ValueError(kind)


def words(c):
    det = sorted((int(k), v) for k, v in c["det_hist"].items())
    lam = sorted((int(k), v) for k, v in c["lam_hist"].items())
    w = [c["rr_count"], c["det_points"], c["det_lines"], c["l_max"], c["lam_points"], c["lam_lines"],
         c["v_max"], len(det), len(lam)]
    for b, v in det + lam:
        w += [b, v]
    return w


cases = []
for n in list(range(1, 13)) + [17, 31, 32, 33, 64, 65, 100, 129]:
    kinds = ["ones", "zeros", "iid0.15", "iid0.5", "iid0.85", "walk", "bands", "asym"]
    for kind in kinds:
        if n > 40 and kind in ("zeros", "asym") and n != 65:
            continue
        cases.append((f"{kind}_n{n}", kind, n))

with open(OUT / "manifest.txt", "w") as mf:
    for name, kind, n in cases:
        R = make(kind, n)
        c = rtl_counters(R, 2, 2)
        beats = []
        for i in range(n):
            for j0 in range(0, n, 2):
                v1 = 1 if j0 + 1 < n else 0
                f0 = int(R[i, j0])
                f1 = int(R[i, j0 + 1]) if v1 else 0
                beats.append((i << 17) | (j0 << 3) | (f1 << 2) | (f0 << 1) | v1)
        (OUT / f"{name}_beats.hex").write_text("\n".join("%08X" % b for b in beats) + "\n")
        w = words(c)
        assert all(0 <= x < 2**32 for x in w)
        (OUT / f"{name}_counters.hex").write_text("\n".join("%08X" % x for x in w) + "\n")
        mf.write(f"{name} {n} {len(beats)}\n")
print(len(cases), "cases in", OUT)
