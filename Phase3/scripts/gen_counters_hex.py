"""Write <case>_counters.hex from the Phase 1 golden JSON, for the SystemVerilog testbenches.

Words (8 hex digits, one per line):
  0 rr_count  1 det_points  2 det_lines  3 l_max  4 lam_points  5 lam_lines  6 v_max
  7 n_det_bins  8 n_lam_bins   then (bin, count) pairs for the DET histogram, then the LAM one.
Counters come from expected_counters_full_scan (the decided full N x N scan, D1).
Usage: python gen_counters_hex.py <case> [<case> ...]   (output in Phase3/build/counters)
"""
import json
import sys
from pathlib import Path

GOLD = Path(__file__).resolve().parents[2] / "Phase1" / "golden"
OUT = Path(__file__).resolve().parents[1] / "build" / "counters"


def words(case):
    c = json.loads((GOLD / f"{case}.json").read_text())["expected_counters_full_scan"]
    det = sorted((int(k), v) for k, v in c["det_hist"].items())
    lam = sorted((int(k), v) for k, v in c["lam_hist"].items())
    w = [c["rr_count"], c["det_points"], c["det_lines"], c["l_max"], c["lam_points"], c["lam_lines"],
         c["v_max"], len(det), len(lam)]
    for b, v in det + lam:
        w += [b, v]
    return w


def main(cases):
    OUT.mkdir(parents=True, exist_ok=True)
    for case in cases:
        w = words(case)
        assert all(0 <= x < 2**32 for x in w), case
        (OUT / f"{case}_counters.hex").write_text("\n".join("%08X" % x for x in w) + "\n")
        print(case, "counters", w[:7], "det bins", w[7], "lam bins", w[8])


if __name__ == "__main__":
    main(sys.argv[1:])
