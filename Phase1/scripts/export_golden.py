"""Task 8: export golden vectors (Q8.24 hex plus JSON sidecar) into golden/.

Cases (Li et al. settings: m = 5, tau = 3, eps = 50 % of max distance, lmin = vmin = 2):
  bench_<signal>_small / _full   the four benchmark signals, single channel
  jrp_coupled_c<c>_small / _full coupled logistic pairs (dual channel)
  jrp_mixedparams_small          dual channel with different m, tau per channel
Small cases (N = 128) include per-pair flag files and embedded vectors for quick
testbenches; full cases (N = 4096) include packed flags only.
Insect recording pair: add with scripts/export_insect_golden.py once the data is in
data/raw (see src/jrp/insect.py).
Usage: python scripts/export_golden.py
"""
import json
from pathlib import Path

from jrp.golden import export_case
from jrp.jrp import ChannelParams
from jrp.signals import (gen_coupled_logistic, gen_harmonic_5_osc, gen_logistic,
                         gen_lorenz_x_resampled, gen_uwn)

OUT = Path(__file__).resolve().parents[1] / "golden"
P = ChannelParams(5, 3, eps_percent=50.0)


def main():
    OUT.mkdir(exist_ok=True)
    bench = {
        "uwn": (lambda n: gen_uwn(n, seed=123), {"generator": "gen_uwn", "seed": 123}),
        "logistic": (lambda n: gen_logistic(n, 3.82843, 0.5, 100),
                     {"generator": "gen_logistic", "r": 3.82843, "x0": 0.5, "burn_in": 100}),
        "lorenz_x": (lambda n: gen_lorenz_x_resampled(n, 100.0, 0.1),
                     {"generator": "gen_lorenz_x_resampled", "total_time_s": 100.0, "dt_sim_s": 0.1,
                      "sigma": 10, "b": 8 / 3, "rho": 28}),
        "harmonic": (lambda n: gen_harmonic_5_osc(n, 100.0, 5),
                     {"generator": "gen_harmonic_5_osc", "total_time_s": 100.0, "cycles": 5}),
    }
    index = []
    for sig, (gen, src) in bench.items():
        for tag, n in (("small", 128), ("full", 4096)):
            name = f"bench_{sig}_{tag}"
            s = export_case(name, OUT, gen(n), None, P, source={**src, "N": n, "normalised": "[0,1]"})
            index.append((name, s["n_vectors"], s["expected_metrics"]))
            print(name, s["n_vectors"], s["expected_metrics"], flush=True)

    for c in (0.0, 0.1, 0.3):
        for tag, n in (("small", 128), ("full", 4096)):
            if tag == "full" and c == 0.1:
                continue
            x, y = gen_coupled_logistic(n, c)
            name = f"jrp_coupled_c{c:g}_{tag}"
            src = {"generator": "gen_coupled_logistic", "r": 3.82843, "c": c, "x0": 0.3, "y0": 0.7,
                   "burn_in": 100, "N": n, "normalised": "[0,1] per channel"}
            s = export_case(name, OUT, x, y, P, P, source=src)
            index.append((name, s["n_vectors"], s["expected_metrics"]))
            print(name, s["n_vectors"], s["expected_metrics"], flush=True)

    x, y = gen_coupled_logistic(128, 0.1)
    s = export_case("jrp_mixedparams_small", OUT, x, y, ChannelParams(5, 3, eps_percent=40.0),
                    ChannelParams(3, 2, eps_percent=60.0),
                    source={"generator": "gen_coupled_logistic", "r": 3.82843, "c": 0.1, "x0": 0.3,
                            "y0": 0.7, "N": 128, "note": "different m, tau, eps per channel, end-aligned"})
    index.append(("jrp_mixedparams_small", s["n_vectors"], s["expected_metrics"]))
    print("jrp_mixedparams_small", s["n_vectors"], s["expected_metrics"])
    # Edge cases for RTL verification (absolute eps, small n so per-pair flags are exported)
    xs, ys = gen_coupled_logistic(64, 0.1)
    edge = {
        "edge_all_recurrent": (xs, ys, ChannelParams(3, 1, eps=10.0), ChannelParams(3, 1, eps=10.0),
                               "eps larger than any distance: every cell recurs"),
        "edge_no_recurrence": (xs, ys, ChannelParams(3, 1, eps=1e-9), ChannelParams(3, 1, eps=1e-9),
                               "eps2 rounds to 0: only identical vectors recur (the diagonal)"),
        "edge_m1_tau1": (xs, ys, ChannelParams(1, 1, eps=0.2), ChannelParams(1, 1, eps=0.2),
                         "embedding dimension 1"),
        "edge_max_embedding": (*gen_coupled_logistic(400, 0.1), ChannelParams(10, 16, eps_percent=60.0),
                               ChannelParams(10, 16, eps_percent=60.0), "MAX_M = 10 and MAX_TAU = 16 of the RTL"),
        "edge_saturation": (300.0 * xs, 300.0 * ys, ChannelParams(3, 1, eps=50.0), ChannelParams(3, 1, eps=50.0),
                            "samples up to 300 exceed the Q8.24 range: saturation events must be logged"),
    }
    for name, (ex, ey, epx, epy, note) in edge.items():
        s = export_case(name, OUT, ex, ey, epx, epy,
                        source={"generator": "gen_coupled_logistic", "c": 0.1, "note": note})
        index.append((name, s["n_vectors"], s["expected_metrics"]))
        print(name, s["n_vectors"], "saturation events:", len(s["saturation_events"]), flush=True)

    (OUT / "index.json").write_text(json.dumps(
        [{"case": n, "n_vectors": v, "expected_metrics": m} for n, v, m in index], indent=1))


if __name__ == "__main__":
    main()
