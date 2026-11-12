"""Collate the board runs of golden/wt_<series>_<start_s>_<f|q>.* (band-passed, decimated windows, footstep-rich f against quiet q).
Board DET = the integer-model metric (the board's counters equalled it: PASS, 0 errors). Python DET and the phase-randomised surrogate mean
come from the PC rerun (scratchpad termite_noise_test2.csv copied to results/termite_noise_test2.csv). Excess = DET minus surrogate mean
(surrogates are computed on the PC; the board computes the DET of the actual window). Writes results/board_termite.md."""
import csv
import json
from pathlib import Path

import numpy as np
from scipy.stats import mannwhitneyu

ROOT = Path(__file__).resolve().parents[1]
HW = ROOT.parent / "Phase3" / "build" / "hwresults"
SER = {"darwin": "Darwin termite", "griffith": "Griffith termite", "lab": "lab ant", "wild": "wild ant"}
py = {}
for fn in ("termite_noise_test2.csv", "termite_noise_test_wild.csv"):      # the wild ant was added later (termite_noise_test_wild.py)
    if not (ROOT / "results" / fn).exists():
        continue
    with open(ROOT / "results" / fn) as f:
        for r in csv.DictReader(f):
            if r["condition"] == "bp_dec4":
                py[(r["series"], round(float(r["start_s"])))] = (float(r["DET"]), float(r["DET_surr_mean"]))
rng = np.random.default_rng(3)
rows, bad = [], []
names = []
for fn in ("termite_cases.txt", "termite_cases_wild.txt"):
    if (ROOT / "golden" / fn).exists():
        names += (ROOT / "golden" / fn).read_text().split()
for name in names:
    rt = HW / f"rt_{name}.json"
    if not rt.exists():
        bad.append((name, "no board result")); continue
    h = json.loads(rt.read_text())
    if h["result"] != "PASS" or h["errors"] != 0:
        bad.append((name, h["result"], h["errors"]))
    j = json.loads((ROOT / "golden" / f"{name}.json").read_text())
    _, tag, s, g = name.split("_")
    pdet, psur = py[(SER[tag], int(s))]
    rows.append((SER[tag], g, int(s), j["expected_metrics"]["JDET"], pdet, psur, h["latency_cycles"]))


def ci(v):
    m = [rng.choice(v, len(v)).mean() for _ in range(3000)]
    return f"{np.mean(v):.3f} [{np.percentile(m, 2.5):.3f}, {np.percentile(m, 97.5):.3f}]"


out = ["# Footstep-rich against quiet termite and ant windows computed on the board", "",
       f"{len(rows)} windows run through the DMA path ({len(bad)} not passing or missing). Each: 4096 samples at 3 kHz after 700 to 1500 Hz band-pass and decimation by 4,"
       " same samples in both channels, m=5, tau=2, 5% recurrence rate, 3 repeats. f = 10 most footstep-rich windows by the envelope detector, q = 10 quietest.", ""]
if bad:
    out += ["Not passing or missing: " + ", ".join(str(b) for b in bad), ""]
out += ["| series | group | windows | board DET, median [Q1, Q3] | board excess, mean [95% CI] | Python excess, mean [95% CI] | max abs(board DET - Python DET) | p (f > q, board excess) |", "|---|---|---|---|---|---|---|---|"]
for ser in SER.values():
    ex = {}
    for g in ("f", "q"):
        sel = [r for r in rows if r[0] == ser and r[1] == g]
        if not sel:
            continue
        b = np.array([r[3] for r in sel]); p = np.array([r[4] for r in sel]); su = np.array([r[5] for r in sel])
        ex[g] = b - su
        q = lambda v: f"{np.median(v):.3f} [{np.percentile(v, 25):.3f}, {np.percentile(v, 75):.3f}]"
        pv = ""
        if g == "f" and "q" in ex:
            pass
        out.append((ser, g, len(sel), q(b), ci(b - su), ci(p - su), f"{np.max(np.abs(b - p)):.4f}"))
    # p value row fill after both groups known
    if "f" in ex and "q" in ex:
        pv = mannwhitneyu(ex["f"], ex["q"], alternative="greater").pvalue
        for i, r in enumerate(out):
            if isinstance(r, tuple) and r[0] == ser:
                out[i] = r + (f"{pv:.4f}" if r[1] == "f" else "",)
    for i, r in enumerate(out):
        if isinstance(r, tuple) and r[0] == ser:
            out[i] = "| " + " | ".join(str(c) for c in r) + (" | |" if len(r) == 7 else " |")
cyc = [r[6] for r in rows]
out += ["", f"Board latency per run: median {np.median(cyc) / 1e6:.2f} M cycles."]
(ROOT / "results" / "board_termite.md").write_text("\n".join(out) + "\n", encoding="utf8")
print("\n".join(out))
