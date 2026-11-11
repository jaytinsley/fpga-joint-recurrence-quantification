"""Golden vector export for SystemVerilog testbenches (Q8.24, $readmemh friendly).

Files written for a case called NAME in outdir:
  NAME_x.hex, NAME_y.hex        input samples, one 8-digit hex word per line (y: dual channel)
  NAME_flags.hex                one 8-digit word per pair (00000000 or 00000001), pair order
                                of rtl/grid_index_gen.v: i outer, j inner, full n x n grid,
                                including i == j. Only written when n <= max_pair_lines_n.
  NAME_flags_packed.hex         the same flags, 32 per word, pair p in bit (p mod 32) of
                                word p // 32 (LSB first); final word zero padded
  NAME_vec_x.hex, NAME_vec_y.hex   embedded vectors (small n only): m words per vector,
                                component 0 first = newest sample, as in
                                phase_space_reconstruction.v
  NAME.json                     sidecar: parameters, eps (float and Q8.24), source, seeds,
                                saturation events, checksums and the expected metrics
The flags and expected metrics come from the integer model of the RTL compare stage, so
they are exactly what the hardware must produce. Metrics use the "rtl" counting convention.
"""
import hashlib
import json
from pathlib import Path

import numpy as np

from . import fixedpoint as fp
from .embedding import takens_embedding
from .jrp import ChannelParams, embed_pair, resolve_eps
from .rqa import rqa_metrics, rtl_counters


def _write_hex(path: Path, words):
    path.write_text("\n".join(words) + "\n")


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pack_flags(R: np.ndarray) -> list:
    """Pack an n x n flag matrix, row-major, 32 pairs per hex word, LSB first."""
    bits = R.astype(np.uint8).ravel()
    pad = (-len(bits)) % 32
    bits = np.concatenate([bits, np.zeros(pad, dtype=np.uint8)]).reshape(-1, 32)
    words = (bits.astype(np.uint64) << np.arange(32, dtype=np.uint64)).sum(axis=1)
    return ["%08X" % int(w) for w in words]


def unpack_flags(words, n: int) -> np.ndarray:
    u = np.array([int(w, 16) for w in words], dtype=np.uint64)
    bits = ((u[:, None] >> np.arange(32, dtype=np.uint64)) & 1).astype(np.uint8).ravel()
    return bits[: n * n].reshape(n, n)


def integer_jrp(x, y, px: ChannelParams, py: ChannelParams, block: int = 1024,
                align: str = "end", log: fp.SaturationLog = None):
    """JRP in the RTL integer domain. y may be None for the single-channel case.

    eps is resolved from the float64 embedded vectors (percent of max distance), then
    converted to eps2 in Q8.24. Returns (flags, info, xq, yq, Vq_x, Vq_y).
    """
    xq = fp.to_q824(x, log, "x")
    yq = fp.to_q824(y, log, "y") if y is not None else None
    if y is None:
        Vx = takens_embedding(np.asarray(x, dtype=np.float64), px.m, px.tau)
        eps_x = resolve_eps(Vx, px, block)
        eps2_x = fp.eps2_to_q824(eps_x, log, "eps2_x")
        Vq = takens_embedding(xq, px.m, px.tau, dtype=np.int64)
        R = fp.recurrence_flags_q824(Vq, eps2_x, block)
        info = {"n": len(R), "eps_x": eps_x, "eps2_x_raw": eps2_x}
        return R, info, xq, None, Vq, None
    Vx, Vy = embed_pair(np.asarray(x, dtype=np.float64), np.asarray(y, dtype=np.float64),
                        px, py, align=align)
    eps_x, eps_y = resolve_eps(Vx, px, block), resolve_eps(Vy, py, block)
    e2x, e2y = fp.eps2_to_q824(eps_x, log, "eps2_x"), fp.eps2_to_q824(eps_y, log, "eps2_y")
    Vqx, Vqy = embed_pair(xq, yq, px, py, align=align)  # float64 embed of ints is exact here
    Vqx, Vqy = Vqx.astype(np.int64), Vqy.astype(np.int64)
    R = fp.recurrence_flags_q824(Vqx, e2x, block) & fp.recurrence_flags_q824(Vqy, e2y, block)
    info = {"n": len(R), "eps_x": eps_x, "eps_y": eps_y, "eps2_x_raw": e2x, "eps2_y_raw": e2y}
    return R, info, xq, yq, Vqx, Vqy


def export_case(name, outdir, x, y, px: ChannelParams, py: ChannelParams = None, lmin: int = 2,
                vmin: int = 2, source: dict = None, block: int = 1024, align: str = "end",
                max_pair_lines_n: int = 256, max_vec_n: int = 1024):
    """Write one golden-vector case. Returns the sidecar dict."""
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    dual = y is not None
    py = py or px
    log = fp.SaturationLog()
    R, info, xq, yq, Vqx, Vqy = integer_jrp(x, y if dual else None, px, py, block, align, log)
    n = info["n"]
    metrics = rqa_metrics(R, lmin, vmin, convention="rtl")

    def counters(scan):
        c = rtl_counters(R, lmin, vmin, scan=scan)
        c["det_hist"] = {str(k): v for k, v in sorted(c["det_hist"].items())}
        c["lam_hist"] = {str(k): v for k, v in sorted(c["lam_hist"].items())}
        return c

    files = {}

    def put(fname, words):
        _write_hex(outdir / fname, words)
        files[fname] = _sha(outdir / fname)

    put(f"{name}_x.hex", fp.to_hex32(xq))
    if dual:
        put(f"{name}_y.hex", fp.to_hex32(yq))
    put(f"{name}_flags_packed.hex", pack_flags(R))
    if n <= max_pair_lines_n:
        put(f"{name}_flags.hex", ["%08X" % int(v) for v in R.ravel()])
    if n <= max_vec_n:
        put(f"{name}_vec_x.hex", fp.to_hex32(Vqx[:, ::-1]))
        if dual:
            put(f"{name}_vec_y.hex", fp.to_hex32(Vqy[:, ::-1]))

    names = {"RR": "JRR", "DET": "JDET", "LAM": "JLAM"} if dual else {}
    expected = {names.get(k, k): (int(v) if k in ("Lmax", "Vmax") else float(v))
                for k, v in metrics.items()}
    side = {
        "name": name, "format": "Q8.24 signed 32-bit two's complement, round to nearest, saturate",
        "channels": 2 if dual else 1, "N_samples": int(len(xq)), "n_vectors": n,
        "x": {"m": px.m, "tau": px.tau}, **({"y": {"m": py.m, "tau": py.tau}} if dual else {}),
        "align": align if dual else None,
        "eps_x": {"float": info["eps_x"], "eps2_raw_q824": info["eps2_x_raw"],
                  "eps2_hex": "%08X" % info["eps2_x_raw"], "percent": px.eps_percent},
        **({"eps_y": {"float": info["eps_y"], "eps2_raw_q824": info["eps2_y_raw"],
                      "eps2_hex": "%08X" % info["eps2_y_raw"], "percent": py.eps_percent}} if dual else {}),
        "lmin": lmin, "vmin": vmin, "metric_convention": "rtl",
        "pair_order": "row-major: i outer, j inner, full n x n grid including i == j (grid_index_gen.v)",
        "flags_packed": "32 pairs per word, pair p in bit p % 32 of word p // 32, hex %08X",
        "vector_component_order": "component 0 = newest sample (phase_space_reconstruction.v)",
        "signal_source": source or {},
        "saturation_events": log.events,
        "expected_metrics": expected,
        "rr_count_offdiagonal": int(R.sum() - np.trace(R)),
        "expected_counters_full_scan": counters("full"),
        "expected_counters_upper_scan": counters("upper"),
        "counters_note": "Integers the RTL extractor must report (histogram bin = min(length, 8191), "
                         "sparse {bin: count}). full_scan: all n*n cells streamed, det_* from the strict "
                         "upper triangle only. upper_scan: only cells with i < j streamed. Host formulas: "
                         "jrp.rqa.metrics_from_counters.",
        "files_sha256": files,
    }
    (outdir / f"{name}.json").write_text(json.dumps(side, indent=1))
    return side


def load_case(name, outdir):
    """Reload a case from disk: returns (sidecar, flags matrix from the packed file)."""
    outdir = Path(outdir)
    side = json.loads((outdir / f"{name}.json").read_text())
    words = (outdir / f"{name}_flags_packed.hex").read_text().split()
    return side, unpack_flags(words, side["n_vectors"])
