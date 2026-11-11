"""Write build/hwcase/<case>.tcl: one golden case as Tcl variables for scripts/hw_axi_run.tcl.

Contents: sizes, m, tau, eps2 (Q8.24 hex), the end-alignment bases, the sample words, and the expected
integer counters and sparse histograms (full N x N scan, from the Phase 1 golden JSON).
Usage: python gen_hw_case.py <case> [<case> ...]
"""
import json
import sys
from pathlib import Path

GOLD = Path(__file__).resolve().parents[2] / "Phase1" / "golden"
OUT = Path(__file__).resolve().parents[1] / "build" / "hwcase"


def words(path):
    return [w.strip() for w in path.read_text().split() if w.strip()]


def gen(case):
    j = json.loads((GOLD / f"{case}.json").read_text())
    dual = j["channels"] == 2
    ns, n = j["N_samples"], j["n_vectors"]
    mx, tx = j["x"]["m"], j["x"]["tau"]
    my, ty = (j["y"]["m"], j["y"]["tau"]) if dual else (1, 1)
    e2x = j["eps_x"]["eps2_raw_q824"]
    e2y = j["eps_y"]["eps2_raw_q824"] if dual else 0xFFFFFFFF
    nx, ny = ns - (mx - 1) * tx, ns - (my - 1) * ty
    c = j["expected_counters_full_scan"]
    x = words(GOLD / f"{case}_x.hex")
    y = words(GOLD / f"{case}_y.hex") if dual else ["00000000"] * ns
    assert len(x) == ns and len(y) == ns, (len(x), len(y), ns)
    det = " ".join(f"{int(k)} {v}" for k, v in sorted(c["det_hist"].items(), key=lambda kv: int(kv[0])))
    lam = " ".join(f"{int(k)} {v}" for k, v in sorted(c["lam_hist"].items(), key=lambda kv: int(kv[0])))
    lines = [
        f"set case(name) {case}",
        f"set case(ns) {ns}", f"set case(n) {n}", f"set case(dual) {int(dual)}",
        f"set case(mx) {mx}", f"set case(tx) {tx}", f"set case(my) {my}", f"set case(ty) {ty}",
        f"set case(e2x) {e2x}", f"set case(e2y) {e2y}",
        f"set case(base_x) {nx - n}", f"set case(base_y) {ny - n}",
        f"set case(nx) {nx}", f"set case(ny) {ny}",
        "set case(expect) {%d %d %d %d %d %d %d}" % (
            c["rr_count"], c["det_points"], c["det_lines"], c["l_max"], c["lam_points"], c["lam_lines"], c["v_max"]),
        "set case(det_hist) {%s}" % det,
        "set case(lam_hist) {%s}" % lam,
        "set case(x) {%s}" % " ".join(x),
        "set case(y) {%s}" % " ".join(y),
    ]
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{case}.tcl").write_text("\n".join(lines) + "\n")
    print(case, "samples", ns, "joint vectors", n, "expected", c["rr_count"], c["det_points"], c["l_max"])


if __name__ == "__main__":
    for case in sys.argv[1:]:
        gen(case)
