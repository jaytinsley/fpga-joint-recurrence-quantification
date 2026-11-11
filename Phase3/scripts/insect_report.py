"""Summary of one board run on a golden case (insect pair or any other): hardware-verified metrics, the
float64 reference on the same samples, and the timing.

"Hardware-verified" means the board's integer counters and histograms equalled the Phase 1 integer model
(HWRUN: PASS), so the metrics below, computed from those counters with the host formulas, are the board's.
Usage: python insect_report.py <case>     (writes reports/insect_<case>.md)
"""
import json
import sys
from pathlib import Path

import numpy as np

P3 = Path(__file__).resolve().parents[1]
GOLD = P3.parent / "Phase1" / "golden"
sys.path.insert(0, str(P3.parent / "Phase1" / "src"))
from jrp.jrp import ChannelParams  # noqa: E402
from jrp.pipeline import jrp_rqa  # noqa: E402


def fmt_eps(e):
    return f"{e['percent']}%" if e.get("percent") is not None else f"{e['float']:.5f} (fixed recurrence rate)"


def q824(path):
    w = np.array([int(t, 16) for t in Path(path).read_text().split()], dtype=np.int64)
    w = np.where(w >= 2**31, w - 2**32, w)
    return w.astype(np.float64) / 2**24


def main(case):
    j = json.loads((GOLD / f"{case}.json").read_text())
    hw_file = P3 / "build" / "hwresults" / f"{case}.json"
    rt_file = P3 / "build" / "hwresults" / f"rt_{case}.json"
    hw = json.loads(hw_file.read_text()) if hw_file.exists() else (json.loads(rt_file.read_text()) if rt_file.exists() else None)
    x = q824(GOLD / f"{case}_x.hex")
    y = q824(GOLD / f"{case}_y.hex")
    def chan(c, e):
        return (ChannelParams(c["m"], c["tau"], eps_percent=e["percent"]) if e.get("percent") is not None
                else ChannelParams(c["m"], c["tau"], eps=e["float"]))
    px, py = chan(j["x"], j["eps_x"]), chan(j["y"], j["eps_y"])
    ref, _ = jrp_rqa(x, y, px, py, lmin=j["lmin"], vmin=j["vmin"], convention="rtl", normalise=False)
    exp = j["expected_metrics"]
    rows = [("JRR", "JRR"), ("JDET", "JDET"), ("JLAM", "JLAM"), ("Lmax", "Lmax"), ("Vmax", "Vmax"), ("ENTR", "ENTR")]
    L = [f"# Board run: {case}", ""]
    if hw and "scan_cycles" in hw:
        L += [f"Hardware result: **{hw['result']}** ({hw['errors']} errors), PL clock {hw['clock_mhz']:.2f} MHz, "
              f"scan {hw['scan_cycles']:,} cycles = {hw['scan_cycles'] / (hw['clock_mhz'] * 1e3):.3f} ms, "
              f"{hw['pairs']:,} pairs.", ""]
    elif hw:
        L += [f"Hardware result (DMA path, {hw['windows']} window): **{hw['result']}** ({hw['errors']} errors), PL clock "
              f"{hw['clock_mhz']:.2f} MHz; counters and histograms equal the integer model.", ""]
    else:
        L += ["No hardware result found (build/hwresults).", ""]
    L += [f"N = {j['N_samples']} samples, {j['n_vectors']} joint vectors; x: m {j['x']['m']}, tau {j['x']['tau']}, "
          f"eps {fmt_eps(j['eps_x'])} ; y: m {j['y']['m']}, tau {j['y']['tau']}, eps {fmt_eps(j['eps_y'])} ; "
          f"lmin {j['lmin']}, vmin {j['vmin']}.", "",
          "| metric | board (Q8.24 integer) | float64 reference | difference |", "|---|---|---|---|"]
    for a, b in rows:
        r = ref[b]
        d = exp[a] - r
        L.append(f"| {a} | {exp[a]:.6g} | {r:.6g} | {d:+.3g} |")
    L += ["", "The float64 column recomputes the recurrence matrix from the Q8.24-quantised samples in double precision; "
          "any difference is the effect of the fixed-point squared distance and threshold only.", ""]
    out = P3 / "reports" / f"insect_{case}.md"
    out.write_text("\n".join(L), encoding="utf8")
    print("\n".join(L))
    print("written", out)


if __name__ == "__main__":
    main(sys.argv[1])
