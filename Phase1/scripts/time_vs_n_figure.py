"""Frame time against N: NumPy and CuPy (host extraction) from the benchmark sweep (coupled logistic JRP, m=5, tau=3), CuPy with GPU extraction
(benchmark_gpu_rqa.csv), PyRQA device time (benchmark_pyrqa.csv) and the K=2 cycle model of the hardware (phase2_cycle_budget.csv;
measured on the board at N=4096: 55.7 ms)."""
import csv
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

R = Path(__file__).resolve().parents[1] / "results"
sw = {"numpy": {}, "cupy": {}}
for r in csv.DictReader(open(R / "csv" / "benchmark_N_sweep.csv")):
    if r["series"] == "JRP_coupled_logistic":
        sw[r["backend"]][int(r["N"])] = float(r["T_total_mean_ms"])
gx = {int(r["N"]): float(r["T_total_mean_ms"]) for r in csv.DictReader(open(R / "csv" / "benchmark_gpu_rqa.csv")) if r["variant"] == "cupy_gpu_rqa"}
pq = {int(r["N"]): float(r["device_ms"]) for r in csv.DictReader(open(R / "csv" / "benchmark_pyrqa.csv"))}
fp = {int(r["n"]): float(r["total_ms"]) for r in csv.DictReader(open(R / "csv" / "phase2_cycle_budget.csv"))
      if r["K"] == "2" and r["engine"] == "pipelined" and r["scan"] == "full"}
fig, ax = plt.subplots(figsize=(6.4, 3.8))
Ns = [512, 1024, 2048, 4096, 8192]
def line(d, c, m, lab, **k):
    ax.plot(Ns, [d[n] for n in Ns], marker=m, color=c, lw=1.4, ms=4.5, label=lab, **k)
line(sw["numpy"], "#8a8f98", "o", "NumPy, CPU")
line(sw["cupy"], "#b9c8dc", "s", "CuPy, host RQA extraction")
line(gx, "#4c78a8", "^", "CuPy, GPU RQA extraction")
line(pq, "#2b4c7e", "v", "PyRQA, GPU (device time)")
line(fp, "#e08a1e", "D", "FPGA, K=2 (cycle model)")
ax.plot([4096], [55.7], marker="*", color="#e08a1e", ms=11, ls="none", markeredgecolor="k", markeredgewidth=0.5, label="FPGA, measured on the board")
ax.set_xscale("log", base=2); ax.set_yscale("log")
ax.set_xticks(Ns); ax.set_xticklabels([str(n) for n in Ns], fontsize=8)
ax.tick_params(axis="y", labelsize=8)
ax.set_xlabel("Window length N (samples)", fontsize=8.5)
ax.set_ylabel("Time per frame (ms, log scale)", fontsize=8.5)
ax.grid(color="#dddddd", lw=0.5, which="both"); ax.set_axisbelow(True)
for s in ("top", "right"):
    ax.spines[s].set_visible(False)
ax.legend(fontsize=7.5, frameon=False, loc="upper left")
fig.tight_layout()
fig.savefig(R / "figures" / "time_vs_n.pdf", bbox_inches="tight")
fig.savefig(R / "figures" / "time_vs_n.png", dpi=200, bbox_inches="tight")
print({k: {n: round(v, 1) for n, v in d.items()} for k, d in (("np", sw["numpy"]), ("cupy", sw["cupy"]), ("gx", gx), ("pq", pq), ("fp", fp))})
