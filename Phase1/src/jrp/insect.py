"""Loader and preprocessing for simultaneously recorded insect vibration channel pairs.

The dataset (Oberst, Lai and Evans 2026) has not been received yet, so file format and
sampling rate are not assumed: the loader reads WAV, CSV/TXT, NPY and MAT files and keeps
the sampling rate and units in the returned metadata. Raw data lives in data/raw and is
never modified or committed.

Pipeline: load -> select channel pair -> remove mean -> (optional) band-limit and decimate
-> cut a segment of n samples -> normalise each channel to [0, 1] (the RTL input range).
The scale factors are kept so physical units (e.g. m/s for LDV velocity) can be recovered.
"""
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .signals import to_unit_interval


@dataclass
class Recording:
    channels: np.ndarray            # (n_samples, n_channels), float64, original units
    fs: float                       # sampling rate, Hz
    names: list                     # channel names
    units: str = "unknown"          # e.g. "m/s" for LDV velocity
    source: str = ""
    meta: dict = field(default_factory=dict)

    def pair(self, a, b):
        ia, ib = self._idx(a), self._idx(b)
        return self.channels[:, ia].copy(), self.channels[:, ib].copy()

    def _idx(self, c):
        return self.names.index(c) if isinstance(c, str) else int(c)


def load_recording(path, fs: float = None, units: str = "unknown", csv_delimiter=None,
                   mat_var: str = None) -> Recording:
    """Read a multi-channel recording. fs is required unless the file stores it
    (WAV always does; a CSV with a 'time' or 't' column in seconds also gives it)."""
    path = Path(path)
    ext = path.suffix.lower()
    names = None
    if ext == ".wav":
        from scipy.io import wavfile
        rate, data = wavfile.read(path)
        data = np.asarray(data, dtype=np.float64)
        fs = float(rate)
    elif ext in (".csv", ".txt"):
        import pandas as pd
        df = pd.read_csv(path, sep=csv_delimiter, engine="python")  # None: sniff the delimiter
        tcol = next((c for c in df.columns if str(c).strip().lower() in ("time", "t", "time_s")), None)
        if tcol is not None:
            t = df[tcol].to_numpy(dtype=np.float64)
            fs_t = 1.0 / float(np.median(np.diff(t)))
            if fs is not None and abs(fs - fs_t) > 1e-3 * fs_t:
                raise ValueError(f"fs={fs} disagrees with time column ({fs_t:.6g} Hz)")
            fs = fs if fs is not None else fs_t
            df = df.drop(columns=[tcol])
        names = [str(c) for c in df.columns]
        data = df.to_numpy(dtype=np.float64)
    elif ext == ".npy":
        data = np.load(path).astype(np.float64)
    elif ext == ".mat":
        from scipy.io import loadmat
        d = {k: v for k, v in loadmat(path).items() if not k.startswith("__")}
        key = mat_var or max(d, key=lambda k: np.size(d[k]))
        data = np.asarray(d[key], dtype=np.float64)
        if data.shape[0] < data.shape[1]:
            data = data.T
    else:
        raise ValueError(f"unsupported format {ext!r}")
    data = np.atleast_2d(data.T).T if data.ndim == 1 else data
    if fs is None:
        raise ValueError("sampling rate unknown: pass fs=... (Hz)")
    names = names or [f"ch{i}" for i in range(data.shape[1])]
    return Recording(data, float(fs), names, units, str(path), {"n_samples": int(data.shape[0])})


def preprocess_pair(x, y, fs: float, n: int, start: int = 0, decimate: int = 1):
    """Mean-removal, optional decimation, segment cut and per-channel [0, 1] normalisation.

    decimate: integer factor, applied with scipy's anti-aliasing FIR decimator to both
    channels identically. start and n are in samples after decimation.
    Returns (x01, y01, info) with info holding fs_out (Hz) and the affine maps
    x = x01 * scale + offset back to the original units.
    """
    x = np.asarray(x, dtype=np.float64) - np.mean(x)
    y = np.asarray(y, dtype=np.float64) - np.mean(y)
    if x.shape != y.shape:
        raise ValueError("channels must be simultaneously recorded (equal length)")
    if decimate > 1:
        from scipy.signal import decimate as _dec
        x, y = _dec(x, decimate, ftype="fir", zero_phase=True), _dec(y, decimate, ftype="fir", zero_phase=True)
    seg = slice(start, start + n)
    xs, ys = x[seg], y[seg]
    if len(xs) < n:
        raise ValueError(f"only {len(xs)} samples available from start={start}, need {n}")
    out = []
    info = {"fs_out_Hz": fs / decimate, "start": start, "n": n, "decimate": decimate}
    for tag, s in (("x", xs), ("y", ys)):
        lo, hi = float(s.min()), float(s.max())
        info[f"{tag}_offset"], info[f"{tag}_scale"] = lo, hi - lo
        out.append(to_unit_interval(s))
    return out[0], out[1], info
