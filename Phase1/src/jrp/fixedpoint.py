"""Q8.24 fixed point, bit-exact with the RTL distance/threshold stage.

Format: signed 32-bit two's complement, 8 integer bits (including sign) and 24 fractional
bits, value = raw / 2**24, range [-128, 128). Conversion rounds to nearest (ties toward
+infinity) and saturates; every saturation is recorded.

RTL arithmetic (rtl/distance_threshold_calculation.v, FRAC = 24):
  diff_k = a_k - b_k              signed 32-bit register (wraps on overflow)
  sq_k   = diff_k * diff_k        exact 64-bit product, scale 2**48
  sum    = sum_k sq_k             exact, no rounding
  flag   = sum <= (eps2 << 24)    eps2 is eps**2 as an unsigned Q8.24 integer
All of this is reproduced here in exact int64 integer arithmetic.
"""
from dataclasses import dataclass, field
from typing import List

import numpy as np

FRAC = 24
SCALE = 1 << FRAC
QMAX = (1 << 31) - 1
QMIN = -(1 << 31)
UMAX = (1 << 32) - 1


@dataclass
class SaturationLog:
    """Record of every value clipped during conversion."""
    events: List[dict] = field(default_factory=list)

    def add(self, name, idx, value, clipped_to):
        self.events.append({"signal": name, "index": int(idx), "value": float(value),
                            "clipped_to_raw": int(clipped_to)})

    def __len__(self):
        return len(self.events)


def to_q824(x, log: SaturationLog = None, name: str = "x") -> np.ndarray:
    """Float array -> int64 array of raw signed Q8.24 values (round to nearest, saturate)."""
    x = np.asarray(x, dtype=np.float64)
    if not np.all(np.isfinite(x)):
        raise ValueError(f"{name}: non-finite value cannot be converted to Q8.24")
    scaled = np.floor(x * SCALE + 0.5)
    for mask, bound in ((scaled > QMAX, QMAX), (scaled < QMIN, QMIN)):
        for i in np.flatnonzero(mask):
            if log is not None:
                log.add(name, i, x[i], bound)
    return np.clip(scaled, QMIN, QMAX).astype(np.int64)


def from_q824(q) -> np.ndarray:
    return np.asarray(q, dtype=np.float64) / SCALE


def eps2_to_q824(eps: float, log: SaturationLog = None, name: str = "eps2") -> int:
    """eps -> unsigned 32-bit raw Q8.24 representation of eps**2 (the RTL eps2 input)."""
    raw = int(np.floor(float(eps) ** 2 * SCALE + 0.5))
    if raw > UMAX:
        if log is not None:
            log.add(name, 0, float(eps) ** 2, UMAX)
        raw = UMAX
    return raw


def to_hex32(q) -> list:
    """Raw signed values -> list of 8-digit upper-case hex strings (two's complement)."""
    return ["%08X" % (int(v) & 0xFFFFFFFF) for v in np.asarray(q).ravel()]


def from_hex32(lines) -> np.ndarray:
    """Inverse of to_hex32: hex strings -> int64 signed raw values."""
    u = np.array([int(s, 16) for s in lines], dtype=np.int64)
    return np.where(u >= 1 << 31, u - (1 << 32), u)


def sq_dist_block_q824(Ai, Aj, xp=np, dtype=None, clip=None):
    """Exact integer sum of squared component differences between rows of Ai and Aj.

    Ai, Aj: int64 arrays (n, m) of raw Q8.24 values. Result is int64 at scale 2**48.
    The component difference is wrapped to signed 32 bits, as in the RTL register.
    dtype=object (NumPy only) uses Python integers: exact for any input, as the RTL's 68-bit
    accumulator is, but slow.
    """
    D = xp.zeros((Ai.shape[0], Aj.shape[0]), dtype=dtype or xp.int64)
    for k in range(Ai.shape[1]):
        d = Ai[:, k][:, None] - Aj[:, k][None, :]
        d = ((d + (1 << 31)) % (1 << 32)) - (1 << 31)
        D += d * d if clip is None else xp.minimum(d * d, clip)
    return D


def recurrence_flags_q824(Vq, eps2_raw: int, block: int = 1024, xp=np) -> np.ndarray:
    """Single-channel recurrence matrix in the RTL integer domain (uint8, on the host)."""
    n = Vq.shape[0]
    big = abs(int(np.max(np.abs(Vq)))) > (1 << 26)   # |value| > 4.0: int64 sums could overflow
    thr = int(eps2_raw) << FRAC
    # Large values: clip each squared difference at thr + 1. The flag (sum <= thr) is unchanged, because any single term
    # above thr already puts the exact sum above thr, and the clipped sum (at most m * (thr + 1) < 2**60) cannot overflow.
    clip = thr + 1 if big else None
    R = np.empty((n, n), dtype=np.uint8)
    for i0 in range(0, n, block):
        i1 = min(i0 + block, n)
        for j0 in range(0, n, block):
            j1 = min(j0 + block, n)
            tile = (sq_dist_block_q824(Vq[i0:i1], Vq[j0:j1], xp, None, clip)
                    <= thr).astype(xp.uint8)
            R[i0:i1, j0:j1] = tile if xp is np else tile.get()
    return R
