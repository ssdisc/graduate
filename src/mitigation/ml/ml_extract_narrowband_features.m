function [featureRow, info] = ml_extract_narrowband_features(x, fftBandstopCfg)
%ML_EXTRACT_NARROWBAND_FEATURES  Extract narrowband-oriented features from a complex sequence.

if nargin < 2 || isempty(fftBandstopCfg)
    fftBandstopCfg = struct();
end

x = x(:);
featureNames = ml_narrowband_feature_names();
featureRow = zeros(1, numel(featureNames));
info = struct( ...
    "featureNames", featureNames, ...
    "probeInfo", struct(), ...
    "metrics", struct());

if isempty(x)
    return;
end

[fftPeakRatio, fftBandOcc, fftDominantBw, spectralFlatness] = local_fft_shape_metrics(x);
stftDrift = local_stft_drift_metric(x);

ampAbs = abs(x);
ampMed = median(ampAbs) + eps;
ampKurtosis = local_real_kurtosis(ampAbs);
ampOutlierRate = mean(ampAbs > 3 * ampMed);

probeCfg = fftBandstopCfg;
probeCfg.forcedFreqBounds = zeros(0, 2);
[~, probeInfo] = fft_bandstop_filter(x, probeCfg);
probeApplied = double(isfield(probeInfo, "applied") && logical(probeInfo.applied));
probePeakRatio = local_probe_scalar(probeInfo, "peakRatios");
probeBandwidthFrac = local_probe_scalar(probeInfo, "selectedBandwidthFrac");
probeCenterFreqAbs = abs(local_probe_scalar(probeInfo, "centerFreq"));
probeMaskFraction = local_probe_scalar(probeInfo, "maskFraction");

featureRow = [ ...
    fftPeakRatio, ...
    fftBandOcc, ...
    fftDominantBw, ...
    stftDrift, ...
    spectralFlatness, ...
    ampKurtosis, ...
    ampOutlierRate, ...
    probeApplied, ...
    probePeakRatio, ...
    probeBandwidthFrac, ...
    probeCenterFreqAbs, ...
    probeMaskFraction];
featureRow(~isfinite(featureRow)) = 0;

info.probeInfo = probeInfo;
info.metrics = struct( ...
    "fftPeakRatio", fftPeakRatio, ...
    "fftBandOccupancy", fftBandOcc, ...
    "fftDominantBandwidth", fftDominantBw, ...
    "stftDominantDrift", stftDrift, ...
    "spectralFlatness", spectralFlatness, ...
    "ampKurtosis", ampKurtosis, ...
    "ampOutlierRate", ampOutlierRate, ...
    "probeApplied", logical(probeApplied), ...
    "probePeakRatio", probePeakRatio, ...
    "probeBandwidthFrac", probeBandwidthFrac, ...
    "probeCenterFreqAbs", probeCenterFreqAbs, ...
    "probeMaskFraction", probeMaskFraction);
end

function [peakRatio, bandOcc, dominantBw, flatness] = local_fft_shape_metrics(x)
x = x(:);
N = numel(x);
if N == 0
    peakRatio = 0;
    bandOcc = 0;
    dominantBw = 0;
    flatness = 0;
    return;
end

nfft = 2^nextpow2(max(N, 64));
S = fftshift(fft(x, nfft));
P = abs(S).^2;
f = ((0:nfft-1).' / nfft) - 0.5;
valid = abs(f) >= 0.01;
if ~any(valid)
    peakRatio = 0;
    bandOcc = 0;
    dominantBw = 0;
    flatness = 0;
    return;
end

noiseFloor = median(P(valid));
if ~isfinite(noiseFloor) || noiseFloor <= 0
    noiseFloor = mean(P(valid)) + eps;
end
peakRatio = max(P(valid)) / max(noiseFloor, eps);

hot = valid & P > 4 * noiseFloor;
bandOcc = mean(double(hot(valid)));

hotIdx = find(hot);
groups = local_group_hot_bins(hotIdx);
if isempty(groups)
    dominantBw = 0;
else
    dominantBw = max(cellfun(@numel, groups)) / nfft;
end

Pvalid = P(valid);
flatness = exp(mean(log(Pvalid + eps))) / max(mean(Pvalid), eps);
end

function drift = local_stft_drift_metric(x)
x = x(:);
N = numel(x);
winLen = min(max(32, floor(N / 6)), 128);
if N < winLen || winLen < 16
    drift = 0;
    return;
end
hopLen = max(8, floor(winLen / 4));
win = hamming(winLen, "periodic");
nfft = 2^nextpow2(winLen);
f = ((0:nfft-1).' / nfft) - 0.5;
valid = abs(f) >= 0.01;
nFrames = 1 + floor((N - winLen) / hopLen);
dom = nan(nFrames, 1);
for frameIdx = 1:nFrames
    startIdx = (frameIdx - 1) * hopLen + 1;
    seg = x(startIdx:startIdx+winLen-1) .* win;
    P = abs(fftshift(fft(seg, nfft))).^2;
    if any(valid)
        P(~valid) = -inf;
        [~, idx] = max(P);
        dom(frameIdx) = f(idx);
    end
end
dom = dom(isfinite(dom));
if numel(dom) < 2
    drift = 0;
else
    drift = mean(abs(diff(dom)));
end
end

function k = local_real_kurtosis(x)
x = double(x(:));
if isempty(x)
    k = 0;
    return;
end
x = x - mean(x);
v = mean(x.^2);
if v <= 0
    k = 0;
    return;
end
k = mean(x.^4) / max(v^2, eps);
end

function value = local_probe_scalar(probeInfo, fieldName)
value = 0;
if ~(isstruct(probeInfo) && isfield(probeInfo, fieldName) && ~isempty(probeInfo.(fieldName)))
    return;
end
raw = double(probeInfo.(fieldName)(:));
raw = raw(isfinite(raw));
if isempty(raw)
    return;
end
value = max(raw);
end

function groups = local_group_hot_bins(idx)
groups = cell(0, 1);
if isempty(idx)
    return;
end
idx = sort(idx(:));
startPos = 1;
for k = 2:numel(idx)
    if idx(k) ~= idx(k-1) + 1
        groups{end+1, 1} = idx(startPos:k-1); %#ok<AGROW>
        startPos = k;
    end
end
groups{end+1, 1} = idx(startPos:end);
end
