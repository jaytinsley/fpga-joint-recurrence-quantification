"""Independence-baseline experiment, step 3: read the board log (hw_null_run.tcl output) for one or more pairing sets and report
(1) whether every hardware count equals the integer model, (2) the distribution of JRR / (RRx RRy) from the HARDWARE counts, and
(3) the independence expectation for comparison. Writes reports/null_baseline.md.
Usage: python analyse_null.py <name>=<logfile> [<name>=<logfile> ...]     name as in build/hwcase/null_<name>.json
"""
import json
import re
import sys
from pathlib import Path

import numpy as np

P3 = Path(__file__).resolve().parents[1]


def parse(log):
    rows = {}
    for line in Path(log).read_text(errors="ignore").splitlines():
        m = re.match(r"\s*NULL: (\d+) ((?:\d+ ?){8})\s*$", line)
        if m:
            rows[int(m.group(1))] = [int(t) for t in m.group(2).split()]
    return rows


def main():
    out = ["# Independence baseline on the board", "",
           "JRR / (RRx RRy) from the board's counts for random pairings of two separate recordings (cops_iridomyrmex.mat). "
           "For independent systems the expected value is about 1.", "",
           "| set | pairings | board = model (all three counts) | median ratio | 5th to 95th percentile | min / max | RRx median | RRy median |",
           "|---|---|---|---|---|---|---|---|"]
    for arg in sys.argv[1:]:
        name, log = arg.split("=", 1)
        meta = json.loads((P3 / "build" / "hwcase" / f"null_{name}.json").read_text())
        hw = parse(log)
        nwin = len(meta["rows"])
        if len(hw) != nwin:
            print(f"{name}: log has {len(hw)} of {nwin} windows")
        exact, ratios, rx, ry = 0, [], [], []
        for k in range(nwin):
            if k not in hw:
                continue
            hj, hx, hy, ej, ex, ey, status, _ = hw[k]
            exact += int(status == 0 and (hj, hx, hy) == (ej, ex, ey))
            n = meta["rows"][k]["n"]
            if hx > 0 and hy > 0:
                ratios.append(hj * n * n / (hx * hy))
            rx.append(hx / n**2); ry.append(hy / n**2)
        r = np.array(ratios)
        out.append(f"| {name} | {len(hw)} | {exact} of {len(hw)} | {np.median(r):.3f} | {np.percentile(r, 5):.3f} to {np.percentile(r, 95):.3f} | "
                   f"{r.min():.3f} / {r.max():.3f} | {np.median(rx):.3f} | {np.median(ry):.3f} |")
        print(out[-1])
    (P3 / "reports").mkdir(exist_ok=True)
    (P3 / "reports" / "null_baseline.md").write_text("\n".join(out) + "\n", encoding="utf8")
    print("written", P3 / "reports" / "null_baseline.md")


if __name__ == "__main__":
    main()
