import numpy as np
import pandas as pd
import pytest
from scipy.io import savemat, wavfile

from jrp.insect import load_recording, preprocess_pair

FS = 8000.0


def two_channels(n=4000):
    t = np.arange(n) / FS
    return np.stack([np.sin(2 * np.pi * 100 * t) * 3.0 + 1.0, np.cos(2 * np.pi * 100 * t) * 0.5], axis=1)


def test_wav_keeps_sampling_rate(tmp_path):
    d = (two_channels() * 1000).astype(np.int16)
    wavfile.write(tmp_path / "a.wav", int(FS), d)
    r = load_recording(tmp_path / "a.wav")
    assert r.fs == FS and r.channels.shape == (4000, 2)


def test_csv_with_time_column_infers_fs(tmp_path):
    d = two_channels()
    df = pd.DataFrame({"time": np.arange(len(d)) / FS, "ant": d[:, 0], "substrate": d[:, 1]})
    df.to_csv(tmp_path / "a.csv", index=False)
    r = load_recording(tmp_path / "a.csv", units="m/s")
    assert r.fs == pytest.approx(FS) and r.names == ["ant", "substrate"] and r.units == "m/s"
    x, y = r.pair("ant", "substrate")
    assert np.allclose(x, d[:, 0])


def test_unknown_fs_is_an_error_not_a_guess(tmp_path):
    np.save(tmp_path / "a.npy", two_channels())
    with pytest.raises(ValueError):
        load_recording(tmp_path / "a.npy")
    assert load_recording(tmp_path / "a.npy", fs=FS).fs == FS


def test_mat_and_bad_extension(tmp_path):
    savemat(tmp_path / "a.mat", {"data": two_channels().T})  # stored as (channels, samples)
    r = load_recording(tmp_path / "a.mat", fs=FS)
    assert r.channels.shape == (4000, 2)
    with pytest.raises(ValueError):
        load_recording(tmp_path / "a.xyz", fs=FS)


def test_preprocess_normalises_and_records_scale():
    d = two_channels()
    x, y, info = preprocess_pair(d[:, 0], d[:, 1], FS, n=1000, start=200)
    assert x.min() == 0 and x.max() == 1 and y.min() == 0 and y.max() == 1
    seg = d[200:1200, 0] - d[:, 0].mean()
    assert np.allclose(x * info["x_scale"] + info["x_offset"], seg)


def test_preprocess_decimation_and_errors():
    d = two_channels()
    x, y, info = preprocess_pair(d[:, 0], d[:, 1], FS, n=500, decimate=4)
    assert info["fs_out_Hz"] == FS / 4 and len(x) == 500
    with pytest.raises(ValueError):
        preprocess_pair(d[:, 0], d[:, 1], FS, n=5000)
    with pytest.raises(ValueError):
        preprocess_pair(d[:, 0], d[:-1, 1], FS, n=100)
