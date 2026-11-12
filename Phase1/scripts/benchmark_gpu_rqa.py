"""CuPy pipeline with the RQA extraction on the GPU, against the CuPy pipeline with host extraction (bench.py) and NumPy.

Coupled logistic maps as in Table tab:cpu (m=5, tau=3, eps = 50 % of the maximum distance, rtl convention, 10 timed runs after one
warm-up). GPU stages are timed with CUDA events. In the GPU-extraction run the recurrence matrix stays on the device, so T_cmp has no
device-to-host copy, and T_rqa is the on-device extraction including the copy of the six scalars. The maximum-distance search is
excluded from all totals, as in the paper. Metrics from the two CuPy variants are compared for equality.
Writes results/csv/benchmark_gpu_rqa.csv and results/benchmark_gpu_rqa.md."""
import csv
import os

os.environ.setdefault("OMP_NUM_THREADS", "1")
import numpy as np

import cupy as cp
from jrp import bench
from jrp.backend import get_xp
from jrp.embedding import takens_embedding
from jrp.jrp import ChannelParams, embed_pair
from jrp.rqa_gpu import joint_recurrence_gpu, rqa_metrics_gpu
from jrp.signals import gen_coupled_logistic, to_unit_interval
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
M, TAU, REPEATS = 5, 3, 10
LENGTHS = [512, 1024, 2048, 4096, 8192]


def run_gpu(x, y, px, py, ex, ey):
    t = {}
    with bench.stage(t, "T_sig", "cupy", False):
        xu, yu = to_unit_interval(x), to_unit_interval(y)
    with bench.stage(t, "T_psr", "cupy", True):
        Vx, Vy = embed_pair(xu, yu, px, py, xp=cp)
    with bench.stage(t, "T_cmp", "cupy", True):
        R = joint_recurrence_gpu(Vx, Vy, ex, ey)
    with bench.stage(t, "T_rqa", "cupy", True):
        met = rqa_metrics_gpu(R)
    t["T_total"] = sum(t[s] for s in bench.STAGES)
    return t, met


def summarise(runs):
    out = {}
    for s in bench.STAGES + ("T_total",):
        v = np.array([r[0][s] for r in runs])
        out[s] = (v.mean(), v.std(ddof=1))
    return out


rows = []
for n in LENGTHS:
    x, y = gen_coupled_logistic(n, 0.1)
    p = ChannelParams(M, TAU, eps_percent=50.0)
    ex, ey, _ = bench.resolve_eps_absolute(x, y, p, p, 1024, "cupy")
    px = ChannelParams(M, TAU, eps=ex); py = ChannelParams(M, TAU, eps=ey)
    res = {}
    for name, fn in (("numpy", lambda: bench.run_once(x, y, px, py, ex, ey, backend="numpy")[:2]),
                     ("cupy_host_rqa", lambda: bench.run_once(x, y, px, py, ex, ey, backend="cupy")[:2]),
                     ("cupy_gpu_rqa", lambda: run_gpu(x, y, px, py, ex, ey))):
        fn()
        runs = [fn() for _ in range(REPEATS if name != "numpy" or n <= 4096 else 5)]
        res[name] = (summarise(runs), runs[-1][1])
    a, b = res["cupy_host_rqa"][1], res["cupy_gpu_rqa"][1]
    same = all((a[k] == b[k]) if k in ("Lmax", "Vmax") else abs(a[k] - b[k]) < 1e-9 for k in a)
    for name, (s, _) in res.items():
        rows.append(dict(N=n, variant=name, metrics_equal_host=same, **{f"{k}_mean_ms": v[0] for k, v in s.items()},
                         **{f"{k}_std_ms": v[1] for k, v in s.items()}))
    print(n, {k: round(v[0]["T_total"][0], 1) for k, v in res.items()}, "equal:", same, flush=True)

(ROOT / "results" / "csv").mkdir(parents=True, exist_ok=True)
with open(ROOT / "results" / "csv" / "benchmark_gpu_rqa.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
lab = {"numpy": "NumPy (CPU)", "cupy_host_rqa": "CuPy, host RQA extraction", "cupy_gpu_rqa": "CuPy, GPU RQA extraction"}
md = ["# CPU, GPU (host extraction) and GPU (device extraction), coupled logistic maps", "",
      f"m={M}, tau={TAU}, eps = 50 % of the maximum distance (not timed), rtl convention, {REPEATS} timed runs (NumPy N=8192: 5). Mean ms.", "",
      "| N | variant | T_psr | T_cmp | T_rqa | total | metrics equal to host extraction |", "|---|---|---|---|---|---|---|"]
for r in rows:
    md.append(f"| {r['N']} | {lab[r['variant']]} | {r['T_psr_mean_ms']:.1f} | {r['T_cmp_mean_ms']:.1f} | {r['T_rqa_mean_ms']:.1f} | {r['T_total_mean_ms']:.1f} | {r['metrics_equal_host']} |")
(ROOT / "results" / "benchmark_gpu_rqa.md").write_text("\n".join(md) + "\n", encoding="utf8")
print("\n".join(md))
