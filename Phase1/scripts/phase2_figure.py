"""Phase 2 block diagram of the dual-channel JRP architecture (PDF for the thesis, PNG for docs)."""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch

ROOT = Path(__file__).resolve().parents[1]
FIG = ROOT / "results" / "figures"
FIG.mkdir(parents=True, exist_ok=True)

fig, ax = plt.subplots(figsize=(12, 6.6))
ax.set_xlim(0, 120)
ax.set_ylim(0, 66)
ax.axis("off")

PS, PL, NEW, OLD = "#e8eef7", "#f4f4f4", "#ffe9c7", "#dff0df"


def box(x, y, w, h, text, fc, fs=7.5, bold=False):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.25,rounding_size=0.8",
                                fc=fc, ec="#444", lw=0.9))
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center", fontsize=fs,
            fontweight="bold" if bold else "normal", linespacing=1.25)


def arrow(p, q, label=None, lx=0, ly=1.2, style="-|>", ls="-"):
    ax.add_patch(FancyArrowPatch(p, q, arrowstyle=style, mutation_scale=9, lw=1, color="#222", linestyle=ls))
    if label:
        ax.text((p[0] + q[0]) / 2 + lx, (p[1] + q[1]) / 2 + ly, label, ha="center", fontsize=6.3, color="#222")


# regions
ax.add_patch(FancyBboxPatch((0.5, 1), 30, 62.5, boxstyle="round,pad=0.3,rounding_size=1", fc=PS, ec="#2b4c7e", lw=1.4))
ax.text(15.5, 61.3, "Processing system (ARM A53, PetaLinux)", ha="center", fontsize=8.0, fontweight="bold", color="#2b4c7e")
ax.add_patch(FancyBboxPatch((36, 1), 83, 62.5, boxstyle="round,pad=0.3,rounding_size=1", fc=PL, ec="#444", lw=1.4))
ax.text(77.5, 61.3, "Programmable logic (XCZU4EV, 150 MHz)", ha="center", fontsize=8.5, fontweight="bold")

# PS blocks
box(2.5, 46, 26, 11, "Acquisition and preprocessing\nmean removal, decimation,\nnormalise to [0, 1] per channel,\nQ8.24 conversion + saturation log", "white")
box(2.5, 33, 26, 10, "Parameter selection (offline)\nAMI -> tau,  FNN -> m  per channel\nGHKSS noise reduction (optional)", "white")
box(2.5, 20.5, 26, 10, "Threshold selection\neps_x, eps_y -> eps2 (Q8.24)\nexact max-distance pass or\nbounding-box rule (decision D4)", "white")
box(2.5, 3, 26, 14, "Driver and host formulas\nregisters, DMA descriptors, results\nRR = rr/N^2,  DET = 2 det_pts/rr\nLAM = lam_pts/rr,  ENTR from histogram\nlog, store, compare with golden", "white")

# PL blocks
box(38, 49, 13, 8, "AXI-DMA MM2S\n64-bit beat\n{y, x} per cycle", OLD, bold=False)
box(54, 52.5, 14, 5.5, "PSR x\n(m_x, tau_x)", OLD)
box(54, 45, 14, 5.5, "PSR y\n(m_y, tau_y)", NEW)
box(71, 52.5, 15, 5.5, "Vector memory X\n(URAM, 2 copies)", OLD)
box(71, 45, 15, 5.5, "Vector memory Y\n(URAM, 2 copies)", NEW)
box(89, 47.5, 28, 10, "Pair index generator\nfull N x N grid, i outer, j inner\n(as grid_index_gen.v, K per cycle)\nbase-index offsets per channel", NEW)

# lanes
ax.add_patch(FancyBboxPatch((38, 22), 56, 20, boxstyle="round,pad=0.3,rounding_size=0.8", fc="white", ec="#444", lw=1, linestyle="--"))
ax.text(66, 40, "K parallel lanes (K = 1 or 2), one pair per lane per cycle", ha="center", fontsize=7.5, fontweight="bold")
box(40, 30.5, 17, 6.5, "DTC x\nd2(x_i, x_j) <= eps2_x", OLD)
box(40, 23.5, 17, 6.5, "DTC y\nd2(y_i, y_j) <= eps2_y", NEW)
box(62, 26, 8, 7.5, "AND", NEW, bold=True)
box(73, 25, 19, 9.5, "joint flag stream\n{i, j, flag}\nunchanged format", OLD)

box(97, 22, 20, 20, "RQA extractor (reused)\ncolumn state: vertical runs\ndiagonal state: DET runs\n(upper triangle)\nhistograms DET, LAM\n(BRAM / LUTRAM)", OLD, fs=7)
box(38, 8, 38, 9.5, "AXI-Lite slaves\ncontrol and status (adds y-channel regs)\nRQA counters + histogram window\nperformance monitor", NEW)
box(81, 5, 36, 12.5, "Integer counters per frame\nrr_count, det_points, det_lines, l_max,\nlam_points, lam_lines, v_max,\nhistograms (bin = min(len, 8191))\n= what the testbenches compare", OLD)

# arrows PS <-> PL
arrow((28.8, 51.5), (37.8, 53), "samples (DDR)", ly=1.3)
arrow((28.8, 12), (37.8, 12.5), "AXI-Lite: regs,\neps2, results", ly=1.2, style="<|-|>")
arrow((28.8, 25.5), (37.8, 10.5))
# PL internal
arrow((51.2, 54), (53.8, 55))
arrow((51.2, 52), (53.8, 48))
arrow((68.2, 55.2), (70.8, 55.2))
arrow((68.2, 47.8), (70.8, 47.8))
arrow((86.2, 54.5), (88.8, 53.5), "")
arrow((86.2, 48), (88.8, 50), "")
arrow((103, 47.3), (80, 42.2), "read addresses i, j", lx=9, ly=-2.2)
arrow((57.2, 33.7), (61.8, 31))
arrow((57.2, 26.7), (61.8, 28.5))
arrow((70.2, 29.7), (72.8, 29.7))
arrow((92.2, 29.7), (96.8, 30))
arrow((107, 21.8), (100, 17.2))
arrow((81, 11), (76.2, 12.5), style="-|>")
arrow((107, 21.8), (107, 17.7))

ax.text(60, -0.8, "Legend:  green = reused from the Li, Lai and Oberst RTL     orange = new or modified for the dual-channel JRP",
        ha="center", fontsize=7.5)
fig.savefig(FIG / "phase2_architecture.pdf", bbox_inches="tight")
fig.savefig(FIG / "phase2_architecture.png", dpi=170, bbox_inches="tight")
print("written")
