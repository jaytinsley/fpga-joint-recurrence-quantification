"""Bar chart (CuPy with GPU extraction: about 25 ms, mean of two benchmark_gpu_rqa.py runs, 28.7 and 21.8 ms)
Bar chart of the time for one N=4096 frame: NumPy (CPU), CuPy (GPU plus CPU RQA extraction), this work on the FPGA (K=1, K=2)
and the reported figure of Li et al. Values are those of Table tab:time and the text after it; the CuPy split is 30 ms GPU compare
and 444 ms CPU RQA extraction (the maximum-distance search is excluded in all bars). PyRQA 8.1 (results/benchmark_pyrqa.md): 567.5 ms end to end, 192.2 ms device time."""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

FIG = Path(__file__).resolve().parents[1] / "results" / "figures"
FIG.mkdir(parents=True, exist_ok=True)

CPU, GPU, CPUX, FPGA, LI = "#8a8f98", "#4c78a8", "#b9c8dc", "#e08a1e", "#f3c98b"
rows = ["NumPy, CPU", "CuPy, host RQA extraction", "CuPy, GPU RQA extraction", "PyRQA, GPU (end to end)", "PyRQA, GPU (device time)", "This work, FPGA, K=1", "This work, FPGA, K=2", "Li et al. (reported)"]

fig, ax = plt.subplots(figsize=(7.2, 4.1))
y = list(range(len(rows)))[::-1]
ax.barh(y[0], 739.7, color=CPU, height=0.6)
ax.barh(y[1], 30.0, color=GPU, height=0.6, label="GPU compare (30 ms)")
ax.barh(y[1], 444.7, left=30.0, color=CPUX, height=0.6, label="CPU RQA extraction (444 ms)")
ax.barh(y[2], 25.3, color=GPU, height=0.6)
ax.barh(y[3], 567.5, color="#9fb7d3", height=0.6)
ax.barh(y[4], 192.2, color=GPU, height=0.6)
ax.barh(y[5], 111.4, color=FPGA, height=0.6)
ax.barh(y[6], 55.7, color=FPGA, height=0.6)
ax.barh(y[7], 55.0, color=LI, height=0.6, hatch="//", edgecolor="#a06a10", lw=0.6)
for yy, v, t in ((y[0], 739.7, "739.7 ms"), (y[1], 474.7, "474.7 ms"), (y[2], 25.3, "about 25 ms"), (y[3], 567.5, "567.5 ms"), (y[4], 192.2, "192.2 ms"),
                 (y[5], 111.4, "111.4 ms"), (y[6], 55.7, "55.7 ms"), (y[7], 55.0, "about 55 ms")):
    ax.text(v + 10, yy, t, va="center", fontsize=8)
ax.set_xlim(0, 880)
ax.set_yticks(y)
ax.set_yticklabels(rows, fontsize=8.5)
ax.set_xlabel("Time for one N = 4096 frame (ms)", fontsize=8.5)
ax.tick_params(axis="x", labelsize=8)
ax.grid(axis="x", color="#dddddd", lw=0.5)
ax.set_axisbelow(True)
for s in ("top", "right"):
    ax.spines[s].set_visible(False)
ax.legend(fontsize=7.5, frameon=False, loc="lower right", bbox_to_anchor=(1.0, 0.0))
fig.tight_layout()
fig.savefig(FIG / "cpu_gpu_fpga_time.pdf", bbox_inches="tight")
fig.savefig(FIG / "cpu_gpu_fpga_time.png", dpi=200, bbox_inches="tight")
print("written")
