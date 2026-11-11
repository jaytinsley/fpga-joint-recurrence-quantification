"""NumPy / CuPy backend switch. One code path, selected by name."""
import numpy as np


def get_xp(name: str = "numpy"):
    """Return the array module for `name` ("numpy" or "cupy")."""
    if name == "numpy":
        return np
    if name == "cupy":
        import cupy
        return cupy
    raise ValueError(f"unknown backend {name!r}")


def to_numpy(a):
    """Copy an array from either backend to a host NumPy array."""
    if isinstance(a, np.ndarray):
        return a
    return a.get()
