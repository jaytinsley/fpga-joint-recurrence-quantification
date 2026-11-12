"""PyRQA (Rawald et al., 2017; OpenCL, RTX 3070 Ti) as an established GPU baseline for the joint recurrence analysis.

Same signals and parameters as benchmark_gpu_rqa.py: coupled logistic maps, m=5, tau=3, eps = 50 % of the maximum distance of each
channel (resolved once, not timed), N = 512 to 8192. PyRQA JRQAComputation (float32, Euclidean, Theiler corrector 1, min line length 2)
is timed end to end around run() (kernel build excluded by one warm-up), 10 runs. Its metrics are compared with the project reference
(rtl convention, float64): the conventions differ slightly (see the md), so differences are reported, not asserted equal.
Writes results/csv/benchmark_pyrqa.csv and results/benchmark_pyrqa.md."""
import csv
import os
import time
from pathlib import Path

os.environ.setdefault("OMP_NUM_THREADS", "1")
import numpy as np

from pyrqa.analysis_type import Classic
from pyrqa.computation import JRQAComputation
from pyrqa.metric import EuclideanMetric
from pyrqa.neighbourhood import FixedRadius
from pyrqa.settings import JointSettings, Settings
from pyrqa.time_series import TimeSeries

from jrp import bench
from jrp.jrp import ChannelParams
from jrp.signals import gen_coupled_logistic, to_unit_interval

ROOT = Path(__file__).resolve().parents[1]
M, TAU, REPEATS = 5, 3, 10
LENGTHS = [512, 1024, 2048, 4096, 8192]


def make(xu, yu, ex, ey):
    sx = Settings(TimeSeries(xu, embedding_dimension=M, time_delay=TAU), analysis_type=Classic, neighbourhood=FixedRadius(ex),
                  similarity_measure=EuclideanMetric, theiler_corrector=1)
    sy = Settings(TimeSeries(yu, embedding_dimension=M, time_delay=TAU), analysis_type=Classic, neighbourhood=FixedRadius(ey),
                  similarity_measure=EuclideanMetric, theiler_corrector=1)
    return JointSettings(sx, sy)


rows = []
for n in LENGTHS:
    x, y = gen_coupled_logistic(n, 0.1)
    p = ChannelParams(M, TAU, eps_percent=50.0)
    ex, ey, _ = bench.resolve_eps_absolute(x, y, p, p, 1024, "cupy")
    xu, yu = to_unit_interval(x), to_unit_interval(y)
    # a PyRQA computation object returns empty results when run() is called twice, so each run uses a fresh object (creation is not timed)
    JRQAComputation.create(make(xu, yu, ex, ey), verbose=False).run()          # warm-up (kernel build)
    ts, dv = [], []
    for _ in range(REPEATS):
        comp = JRQAComputation.create(make(xu, yu, ex, ey), verbose=False)
        t0 = time.perf_counter(); res = comp.run(); ts.append((time.perf_counter() - t0) * 1e3)
        mr = res.matrix_runtimes
        dv.append((mr.transfer_to_device + mr.execute_computations + mr.transfer_from_device) * 1e3)   # PyRQA's own device timings (s -> ms)
    # project reference (float64, rtl convention) for the same signals
    px = ChannelParams(M, TAU, eps=ex); py = ChannelParams(M, TAU, eps=ey)
    ref = bench.run_once(x, y, px, py, ex, ey, backend="numpy")[1]
    rows.append(dict(N=n, mean_ms=float(np.mean(ts)), std_ms=float(np.std(ts, ddof=1)), device_ms=float(np.mean(dv)), device_std_ms=float(np.std(dv, ddof=1)),
                     pyrqa_RR=res.recurrence_rate, ref_RR=ref["RR"], pyrqa_DET=res.determinism, ref_DET=ref["DET"],
                     pyrqa_LAM=res.laminarity, ref_LAM=ref["LAM"], pyrqa_Lmax=res.longest_diagonal_line, ref_Lmax=ref["Lmax"],
                     pyrqa_Vmax=res.longest_vertical_line, ref_Vmax=ref["Vmax"]))
    print(n, round(rows[-1]["mean_ms"], 2), "ms", {k: (round(rows[-1]["pyrqa_" + k], 4), round(float(rows[-1]["ref_" + k]), 4)) for k in ("RR", "DET", "LAM", "Lmax", "Vmax")}, flush=True)

(ROOT / "results" / "csv").mkdir(parents=True, exist_ok=True)
with open(ROOT / "results" / "csv" / "benchmark_pyrqa.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
md = ["# PyRQA joint recurrence analysis on the GPU, coupled logistic maps", "",
      f"PyRQA 8.1 JRQAComputation (OpenCL, RTX 3070 Ti, float32, Euclidean, Theiler corrector 1), m={M}, tau={TAU}, eps = 50 % of the maximum distance (not timed), {REPEATS} timed runs after one warm-up, each on a fresh computation object (object creation not timed). Two times (mean ms): wall = end-to-end run() on a fresh object, which includes PyRQA's per-object OpenCL set-up; device = PyRQA's own timers for transfer to the device, kernel execution and transfer back, which is the cost once set up.", "",
      "| N | wall ms (std) | device ms (std) | RR py / ref | DET py / ref | LAM py / ref | Lmax py / ref | Vmax py / ref |", "|---|---|---|---|---|---|---|---|---|"]
for r in rows:
    md.append(f"| {r['N']} | {r['mean_ms']:.1f} ({r['std_ms']:.1f}) | {r['device_ms']:.2f} ({r['device_std_ms']:.2f}) | {r['pyrqa_RR']:.4f} / {float(r['ref_RR']):.4f} | {r['pyrqa_DET']:.4f} / {float(r['ref_DET']):.4f} | {r['pyrqa_LAM']:.4f} / {float(r['ref_LAM']):.4f} | {r['pyrqa_Lmax']} / {r['ref_Lmax']} | {r['pyrqa_Vmax']} / {r['ref_Vmax']} |")
(ROOT / "results" / "benchmark_pyrqa.md").write_text("\n".join(md) + "\n", encoding="utf8")
print("\n".join(md))
