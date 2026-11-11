% visualise_cops.m
% Look at the four walking-response series in cops_iridomyrmex.mat (laser Doppler vibrometer, 12 kHz, unfiltered).
% Time axis starts at 0 (sample k is at (k-1)/fs). Base MATLAB only, no toolboxes.
%
%   Figure 1, one row per series:  (1) rms envelope over the whole record   (2) zoomed waveform
%                                  (3) power spectral density (Welch)        (4) amplitude histogram
%   Figure 2: spectrogram of the first 'specLen' seconds of each series
%   Command window: one-line summary per series, with a warning for a series that is not a vibration signal
%
% Edit the settings, then run. To also save PNGs next to the .mat file:  saveFigs = true; visualise_cops

if ~exist('saveFigs', 'var'), saveFigs = false; end

%% ---- settings ----
fs        = 12000;      % Hz (as supplied)
zoomStart = 5.0;        % s, start of the zoomed waveform window
zoomLen   = 0.34;       % s (0.34 s = 4096 samples)
envBlock  = 0.1;        % s, block length for the rms envelope
specLen   = 10;         % s, length of the spectrogram window (from t = 0)
nfftPSD   = 4096;       % samples per Welch segment (50 % overlap, Hann window)
nfftSpec  = 512;        % samples per spectrogram frame (75 % overlap, Hann window)

%% ---- load ----
here = fileparts(mfilename('fullpath'));
matfile = fullfile(here, '..', '..', 'cops_iridomyrmex.mat');
if ~isfile(matfile)
    [f, p] = uigetfile('*.mat', 'Select cops_iridomyrmex.mat');
    if isequal(f, 0), error('No file selected.'); end
    matfile = fullfile(p, f);
end
S = load(matfile);
names = fieldnames(S);
nSer = numel(names);
figVis = 'on'; if saveFigs, figVis = 'off'; end

%% ---- summary and checks ----
fprintf('\n%s  (fs = %g Hz)\n', matfile, fs);
fprintf('%-24s %9s %8s %10s %9s %9s %9s  %s\n', 'series', 'samples', 'sec', 'mean', 'std', 'max|x|', 'peak at s', 'note');
isRamp = false(nSer, 1);
for k = 1:nSer
    x = double(S.(names{k})(:));
    n = numel(x);
    [mx, ix] = max(abs(x));
    % a straight line from the first to the last sample is not a vibration signal
    dev = max(abs(x - linspace(x(1), x(end), n)'));
    isRamp(k) = dev < 1e-3 * (max(x) - min(x));
    note = '';
    if isRamp(k), note = 'WARNING: straight ramp, not a signal'; end
    if any(~isfinite(x)), note = [note ' non-finite samples']; end %#ok<AGROW>
    fprintf('%-24s %9d %8.2f %10.3g %9.3g %9.3g %9.2f  %s\n', names{k}, n, n / fs, mean(x), std(x), mx, (ix - 1) / fs, note);
end

%% ---- figure 1: overview ----
f1 = figure('Name', 'cops overview', 'Position', [50 50 1500 900], 'Visible', figVis);
tl = tiledlayout(nSer, 4, 'TileSpacing', 'compact', 'Padding', 'compact');
[~, fname, fext] = fileparts(matfile);
title(tl, sprintf('%s   (fs = %g Hz, time axis from 0)', strrep([fname fext], '_', '\_'), fs), 'FontSize', 10);
for k = 1:nSer
    x = double(S.(names{k})(:));
    n = numel(x);
    t = (0:n-1)' / fs;
    nm = strrep(names{k}, '_', '\_');
    warnTxt = ''; col = [0 0.447 0.741];
    if isRamp(k), warnTxt = '  (RAMP, NOT A SIGNAL)'; col = [0.85 0.1 0.1]; end

    % (1) rms envelope over the whole record
    b = round(envBlock * fs); nb = floor(n / b);
    env = sqrt(mean(reshape(x(1:nb*b), b, nb) .^ 2, 1));
    nexttile; plot(((0:nb-1) + 0.5) * envBlock, env, 'Color', col, 'LineWidth', 0.8);
    xlabel('time (s)'); ylabel('rms'); title([nm warnTxt ': rms per ' num2str(envBlock) ' s'], 'FontSize', 8); xlim([0 n/fs]); grid on

    % (2) zoomed waveform
    i0 = max(1, round(zoomStart * fs) + 1); i1 = min(n, i0 + round(zoomLen * fs) - 1);
    nexttile; plot(t(i0:i1), x(i0:i1), 'Color', col, 'LineWidth', 0.5);
    xlabel('time (s)'); ylabel('amplitude (normalised)'); title(sprintf('zoom %.2f to %.2f s', t(i0), t(i1)), 'FontSize', 8); grid on; xlim([t(i0) t(i1)])

    % (3) Welch PSD (Hann, 50 % overlap), without toolboxes
    w = 0.5 - 0.5 * cos(2 * pi * (0:nfftPSD-1)' / nfftPSD);
    hop = nfftPSD / 2; nseg = floor((n - nfftPSD) / hop) + 1;
    P = zeros(nfftPSD/2 + 1, 1);
    for s = 0:nseg-1
        seg = x(s*hop + (1:nfftPSD)); seg = (seg - mean(seg)) .* w;
        F = fft(seg); P = P + abs(F(1:nfftPSD/2+1)) .^ 2;
    end
    P = P / (nseg * fs * sum(w .^ 2)); P(2:end-1) = 2 * P(2:end-1);
    fr = (0:nfftPSD/2)' * fs / nfftPSD;
    nexttile; semilogx(fr(2:end), 10 * log10(P(2:end) + eps), 'Color', col, 'LineWidth', 0.8);
    xlabel('frequency (Hz)'); ylabel('PSD (dB/Hz)'); title('Welch PSD', 'FontSize', 8); grid on; xlim([fr(2) fs/2])

    % (4) amplitude histogram, log counts
    nexttile; histogram(x, 200, 'FaceColor', col, 'EdgeColor', 'none'); set(gca, 'YScale', 'log');
    xlabel('amplitude (normalised)'); ylabel('count'); title('amplitude histogram', 'FontSize', 8); grid on
end

%% ---- figure 2: spectrograms ----
f2 = figure('Name', 'cops spectrograms', 'Position', [80 80 1300 850], 'Visible', figVis);
tl2 = tiledlayout(nSer, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
title(tl2, sprintf('Spectrograms, first %g s', specLen), 'FontSize', 10);
w = 0.5 - 0.5 * cos(2 * pi * (0:nfftSpec-1)' / nfftSpec); hop = nfftSpec / 4;
for k = 1:nSer
    x = double(S.(names{k})(:)); x = x(1:min(numel(x), round(specLen * fs)));
    nfr = floor((numel(x) - nfftSpec) / hop) + 1;
    idx = (0:nfr-1) * hop + (1:nfftSpec)';                     % nfftSpec x nfr index matrix
    Fm = fft((x(idx) - mean(x)) .* w);
    Pm = abs(Fm(1:nfftSpec/2+1, :)) .^ 2 / (fs * sum(w .^ 2));
    tt = ((0:nfr-1) * hop + nfftSpec/2) / fs; ff = (0:nfftSpec/2)' * fs / nfftSpec;
    nexttile; imagesc(tt, ff, 10 * log10(Pm + eps)); axis xy;
    ylabel('Hz'); title(strrep(names{k}, '_', '\_'), 'FontSize', 8); colorbar;
    clim(max(10 * log10(Pm(:) + eps)) + [-70 0]);
end
xlabel('time (s)');

%% ---- optional save ----
if saveFigs
    exportgraphics(f1, fullfile(here, '..', 'results', 'figures', 'cops_overview.png'), 'Resolution', 110);
    exportgraphics(f2, fullfile(here, '..', 'results', 'figures', 'cops_spectrograms.png'), 'Resolution', 110);
    fprintf('saved Phase1/results/figures/cops_overview.png and cops_spectrograms.png\n');
end
