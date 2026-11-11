"""Collate the board runs of golden/w<u|g>_<series>_<start>.* : board result (PASS, errors), metrics from the golden expected metrics
(equal to the board's counters by the PASS), medians [quartiles] per series and condition, and a comparison with the float64 Python
analysis of the same windows (results/determinism_study.csv, m=5, tau=4). Writes results/board_determinism.md."""
import csv
import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
HW = ROOT.parent / "Phase3" / "build" / "hwresults"
SER = {"lab": "lab ant", "wild": "wild ant", "darwin": "Darwin termite", "griffith": "Griffith termite"}
COND = {"u": "unfiltered", "g": "GHKSS d3 q2"}
py = {}
with open(ROOT / "results" / "determinism_study.csv") as f:
    for r in csv.DictReader(f):
        if r["m"] == "5" and r["tau"] == "4":
            py[(r["series"], r["condition"], round(float(r["start_s"])))] = float(r["DET"])
rows, bad = [], []
for name in (ROOT / "golden" / "window_cases.txt").read_text().split():
    rt = HW / f"rt_{name}.json"
    if not rt.exists():
        bad.append((name, "no board result")); continue
    h = json.loads(rt.read_text())
    if h["result"] != "PASS" or h["errors"] != 0:
        bad.append((name, h["result"], h["errors"]))
    j = json.loads((ROOT / "golden" / f"{name}.json").read_text())
    c, tag, s = name.split("_")
    m = j["expected_metrics"]
    rows.append((SER[tag], COND[c[1]], int(s), m["JDET"], m["JLAM"], m["ENTR"], m["Lmax"], h["latency_cycles"], h["clock_mhz"]))
out = ["# Determinism windows computed on the board", "",
       f"{len(rows)} windows run through the DMA path ({len(bad)} not passing or missing). Each: 4096 samples, same samples in both channels, m=5, tau=4, 5% recurrence rate, 3 repeats.",
       "Board metrics are the integer-model metrics (the board's counters and histograms equalled them, 0 errors).", ""]
if bad:
    out += ["Not passing or missing: " + ", ".join(str(b) for b in bad), ""]
out += ["| series | condition | windows | DET (board) | LAM (board) | ENTR (board) | median |DET board - DET Python float64| |", "|---|---|---|---|---|---|---|"]
for cond in COND.values():
    for ser in SER.values():
        sel = [r for r in rows if r[0] == ser and r[1] == cond]
        if not sel:
            continue
        a = np.array([[r[3], r[4], r[5]] for r in sel])
        q = lambda v: f"{np.median(v):.3f} [{np.percentile(v, 25):.3f}, {np.percentile(v, 75):.3f}]"
        diffs = [abs(r[3] - py[(r[0], r[1], r[2])]) for r in sel if (r[0], r[1], r[2]) in py]
        out.append(f"| {ser} | {cond} | {len(sel)} | {q(a[:, 0])} | {q(a[:, 1])} | {q(a[:, 2])} | {np.median(diffs):.4f} (max {np.max(diffs):.4f}) |" if diffs else
                   f"| {ser} | {cond} | {len(sel)} | {q(a[:, 0])} | {q(a[:, 1])} | {q(a[:, 2])} | n/a |")
cyc = [r[7] for r in rows]
out += ["", f"Board latency per run (start to metrics valid, incl. DMA of the window): median {np.median(cyc) / 1e6:.2f} M cycles, range {min(cyc) / 1e6:.2f} to {max(cyc) / 1e6:.2f} M cycles."]
(ROOT / "results" / "board_determinism.md").write_text("\n".join(out) + "\n", encoding="utf8")
print("\n".join(out))
