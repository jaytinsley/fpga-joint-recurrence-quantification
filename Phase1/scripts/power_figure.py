"""Power and energy per N=4096 frame: FPGA (Vivado estimates), Li et al. (reported estimate) and the GPU card (measured).
Values: results/power_estimates.md and results/gpu_power.md. Energy = power x frame time."""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

FIG = Path(__file__).resolve().parents[1] / "results" / "figures"
FIG.mkdir(parents=True, exist_ok=True)
ORG, LI, BLU = "#e08a1e", "#f3c98b", "#4c78a8"
rows = [  # label, power W, frame time s, colour, hatch
    ("FPGA logic only\n(this work, K=2)", 0.802, 0.0557, ORG, None),
    ("FPGA whole chip\n(this work, K=2)", 2.042, 0.0557, ORG, None),
    ("Li et al. (2026)\n(reported estimate)", 3.539, 0.055, LI, "//"),
    ("GPU card\n(RTX 3070 Ti, measured)", 168.0, 0.0208, BLU, None),
    ("GPU card + CPU package\n(measured)", 206.4, 0.0208, BLU, None),
    ("CPU, NumPy, one thread\n(i5-12600K, RAPL)", 39.6, 0.888, "#8a8f98", None),
]
lab = [r[0] for r in rows]
pw = [r[1] for r in rows]
en = [r[1] * r[2] for r in rows]
fig, axes = plt.subplots(1, 2, figsize=(7.4, 3.9), sharey=True)
y = list(range(len(rows)))[::-1]
for ax, vals, unit, xl in ((axes[0], pw, "W", "Power (W, log scale)"), (axes[1], en, "J", "Energy per N = 4096 frame (J, log scale)")):
    for yy, v, r in zip(y, vals, rows):
        ax.barh(yy, v, color=r[3], hatch=r[4], edgecolor="#a06a10" if r[4] else r[3], height=0.6, lw=0.6)
        ax.text(v * 1.25, yy, f"{v:.3g} {unit}", va="center", fontsize=8)
    ax.set_xscale("log")
    ax.set_xlabel(xl, fontsize=8.5)
    ax.tick_params(axis="x", labelsize=8)
    ax.grid(axis="x", which="major", color="#dddddd", lw=0.5)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
axes[0].set_xlim(0.3, 2500)
axes[1].set_xlim(0.02, 400)
axes[0].set_yticks(y)
axes[0].set_yticklabels(lab, fontsize=8)
fig.tight_layout()
fig.savefig(FIG / "power_energy.pdf", bbox_inches="tight")
fig.savefig(FIG / "power_energy.png", dpi=200, bbox_inches="tight")
print("written", [round(e, 3) for e in en])
