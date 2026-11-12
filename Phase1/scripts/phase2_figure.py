"""Phase 2 block diagram of the dual-channel JRP architecture (PDF for the thesis, PNG for docs)."""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch

ROOT = Path(__file__).resolve().parents[1]
FIG = ROOT / "results" / "figures"
FIG.mkdir(parents=True, exist_ok=True)

# Layout: the PS region is 10% wider (30 -> 33 units) and the gap between the PS and PL regions is 1.5x the original
# (5.5 -> 8.25 units), so every PL coordinate is shifted right by SH. The canvas grows by the same amount to keep the scale.
PS_W = 33.0                      # was 30.0
GAP = 8.25                       # was 5.5
PL_X0 = 0.5 + PS_W + GAP         # left edge of the PL region (was 36)
SH = PL_X0 - 36.0                # shift applied to all PL coordinates
SC = PS_W / 30.0                 # horizontal scale of the PS blocks
W_TOT = 120 + SH

fig, ax = plt.subplots(figsize=(12 * W_TOT / 120, 6.6))
ax.set_xlim(0, W_TOT)
ax.set_ylim(0, 66)
ax.axis("off")

PS, PL, NEW, OLD = "#e8eef7", "#f4f4f4", "#ffe9c7", "#dff0df"


def box(x, y, w, h, text, fc, fs=7.5, bold=False):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.25,rounding_size=0.8",
                                fc=fc, ec="#444", lw=0.9))
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center", fontsize=fs,
            fontweight="bold" if bold else "normal", linespacing=1.25)


def pbox(x, y, w, h, text, fc, **kw):          # box in the PL region (shifted)
    box(x + SH, y, w, h, text, fc, **kw)


def arrow(p, q, label=None, lx=0, ly=1.2, style="-|>", ls="-", va="baseline"):
    ax.add_patch(FancyArrowPatch(p, q, arrowstyle=style, mutation_scale=9, lw=1, color="#222", linestyle=ls))
    if label:
        ax.text((p[0] + q[0]) / 2 + lx, (p[1] + q[1]) / 2 + ly, label, ha="center", va=va, fontsize=6.3, color="#222")


def parrow(p, q, *a, **kw):                    # arrow with both ends in the PL region
    arrow((p[0] + SH, p[1]), (q[0] + SH, q[1]), *a, **kw)


# regions
ax.add_patch(FancyBboxPatch((0.5, 1), PS_W, 62.5, boxstyle="round,pad=0.3,rounding_size=1", fc=PS, ec="#2b4c7e", lw=1.4))
ax.text(0.5 + PS_W / 2, 61.3, "Processing system (ARM A53, PetaLinux)", ha="center", fontsize=7.4, fontweight="bold", color="#2b4c7e")
ax.add_patch(FancyBboxPatch((PL_X0, 1), 83, 62.5, boxstyle="round,pad=0.3,rounding_size=1", fc=PL, ec="#444", lw=1.4))
ax.text(PL_X0 + 41.5, 61.3, "Programmable logic (XCZU4EV, 150 MHz)", ha="center", fontsize=8.5, fontweight="bold")

# PS blocks (10% wider to fill the wider region)
PW = 26 * SC
box(2.5, 46, PW, 11, "Acquisition and preprocessing\nmean removal, decimation,\nnormalise to [0, 1] per channel,\nQ8.24 conversion + saturation log", "white")
box(2.5, 33, PW, 10, "Parameter selection (offline)\nAMI -> tau,  FNN -> m  per channel\nGHKSS noise reduction (optional)", "white")
box(2.5, 20.5, PW, 10, "Threshold selection\neps_x, eps_y -> eps2 (Q8.24)\nexact max-distance pass or\nbounding-box rule (decision D4)", "white")
box(2.5, 3, PW, 14, "Driver and host formulas\nregisters, DMA descriptors, results\nRR = rr/N^2,  DET = 2 det_pts/rr\nLAM = lam_pts/rr,  ENTR from histogram\nlog, store, compare with golden", "white")

# PL blocks
pbox(38, 49, 13, 8, "AXI-DMA MM2S\n64-bit beat\n{y, x} per cycle", OLD, bold=False)
pbox(54, 52.5, 14, 5.5, "PSR x\n(m_x, tau_x)", OLD)
pbox(54, 45, 14, 5.5, "PSR y\n(m_y, tau_y)", NEW)
pbox(71, 52.5, 15, 5.5, "Vector memory X\n(URAM, 2 copies)", OLD)
pbox(71, 45, 15, 5.5, "Vector memory Y\n(URAM, 2 copies)", NEW)
pbox(89, 47.5, 28, 10, "Pair index generator\nfull N x N grid, i outer, j inner\n(as grid_index_gen.v, K per cycle)\nbase-index offsets per channel", NEW)

# lanes
ax.add_patch(FancyBboxPatch((38 + SH, 22), 56, 20, boxstyle="round,pad=0.3,rounding_size=0.8", fc="white", ec="#444", lw=1, linestyle="--"))
ax.text(66 + SH, 40, "K parallel lanes (K = 1 or 2), one pair per lane per cycle", ha="center", fontsize=7.5, fontweight="bold")
pbox(40, 30.5, 17, 6.5, "DTC x\nd2(x_i, x_j) <= eps2_x", OLD)
pbox(40, 23.5, 17, 6.5, "DTC y\nd2(y_i, y_j) <= eps2_y", NEW)
pbox(62, 26, 8, 7.5, "AND", NEW, bold=True)
pbox(73, 25, 19, 9.5, "joint flag stream\n{i, j, flag}\nunchanged format", OLD)

pbox(97, 22, 20, 20, "RQA extractor (reused)\ncolumn state: vertical runs\ndiagonal state: DET runs\n(upper triangle)\nhistograms DET, LAM\n(BRAM / LUTRAM)", OLD, fs=7)
pbox(38, 8, 38, 9.5, "AXI-Lite slaves\ncontrol and status (adds y-channel regs)\nRQA counters + histogram window\nperformance monitor", NEW)
pbox(81, 5, 36, 12.5, "Integer counters per frame\nrr_count, det_points, det_lines, l_max,\nlam_points, lam_lines, v_max,\nhistograms (bin = min(len, 8191))\n= what the testbenches compare", OLD)

# arrows PS <-> PL (start just outside the right edge of the PS blocks, end just left of the PL blocks)
PS_R = 2.5 + PW + 0.3
arrow((PS_R, 51.5), (37.8 + SH, 53), "samples\n(DDR)", ly=1.3)
# AXI-Lite label sits in the white space below its double arrow; the threshold arrow runs above it and ends higher on the AXI-Lite box
arrow((PS_R, 12), (37.8 + SH, 12.5), "AXI-Lite:\nregs, eps2,\nresults", lx=0, ly=-0.9, style="<|-|>", va="top")
arrow((PS_R, 25.5), (37.8 + SH, 15.5))
# PL internal
parrow((51.2, 54), (53.8, 55))
parrow((51.2, 52), (53.8, 48))
parrow((68.2, 55.2), (70.8, 55.2))
parrow((68.2, 47.8), (70.8, 47.8))
parrow((86.2, 54.5), (88.8, 53.5), "")
parrow((86.2, 48), (88.8, 50), "")
parrow((103, 47.3), (80, 42.2), "read addresses i, j", lx=9, ly=-2.2)
parrow((57.2, 33.7), (61.8, 31))
parrow((57.2, 26.7), (61.8, 28.5))
parrow((70.2, 29.7), (72.8, 29.7))
parrow((92.2, 29.7), (96.8, 30))
parrow((107, 21.8), (100, 17.2))
parrow((81, 11), (76.2, 12.5), style="-|>")
parrow((107, 21.8), (107, 17.7))

ax.text(W_TOT / 2, -0.8, "Legend:  green = reused from the Li, Lai and Oberst RTL     orange = new or modified for the dual-channel JRP",
        ha="center", fontsize=7.5)
fig.savefig(FIG / "phase2_architecture.pdf", bbox_inches="tight")
fig.savefig(FIG / "phase2_architecture.png", dpi=170, bbox_inches="tight")
print("written")
