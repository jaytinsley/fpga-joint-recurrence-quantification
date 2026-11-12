"""Excess DET over phase-randomised surrogates for footstep-rich (f) and quiet (q) windows of the four series (10 windows per group).
Values are the Python excess from termite_noise_test2.csv / termite_noise_test_wild.csv (condition bp_dec4), which equals the board's
excess to four decimals (results/board_termite.md); groups from termite_case_selection*.csv."""
import csv
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

R = Path(__file__).resolve().parents[1] / "results"
NAME = {"lab": "lab ant", "darwin": "Darwin termite", "griffith": "Griffith termite", "wild": "wild ant"}
exc = {}
for fn in ("termite_noise_test2.csv", "termite_noise_test_wild.csv"):
    for r in csv.DictReader(open(R / fn)):
        if r["condition"] == "bp_dec4":
            exc[(r["series"], round(float(r["start_s"])))] = float(r["DET"]) - float(r["DET_surr_mean"])
val = {}
for fn in ("termite_case_selection.csv", "termite_case_selection_wild.csv"):
    for r in csv.DictReader(open(R / fn)):
        val.setdefault((NAME[r["series"]], r["group"]), []).append(exc[(NAME[r["series"]], int(r["start_s"]))])
order = ["lab ant", "Darwin termite", "Griffith termite", "wild ant"]
fig, ax = plt.subplots(figsize=(6.4, 3.4))
rng = np.random.default_rng(1)
for i, s in enumerate(order):
    for g, dx, c, lab in (("q", -0.18, "#8a8f98", "quiet"), ("f", 0.18, "#e08a1e", "footstep-rich")):
        v = np.array(val[(s, g)])
        ax.scatter(i + dx + rng.uniform(-0.07, 0.07, len(v)), v, s=14, color=c, alpha=0.85, label=lab if i == 0 else None, zorder=3)
        ax.hlines(v.mean(), i + dx - 0.12, i + dx + 0.12, color="k", lw=1.5, zorder=4)
ax.axhline(0, color="#999999", lw=0.8)
ax.set_xticks(range(4)); ax.set_xticklabels(order, fontsize=8.5)
ax.set_ylabel("Excess DET over surrogates", fontsize=8.5)
ax.tick_params(axis="y", labelsize=8)
ax.grid(axis="y", color="#dddddd", lw=0.5); ax.set_axisbelow(True)
for s in ("top", "right"):
    ax.spines[s].set_visible(False)
ax.legend(fontsize=8, frameon=False, loc="upper right")
fig.tight_layout()
fig.savefig(R / "figures" / "footstep_excess.pdf", bbox_inches="tight")
fig.savefig(R / "figures" / "footstep_excess.png", dpi=200, bbox_inches="tight")
print({k: round(float(np.mean(v)), 3) for k, v in val.items()})
