function [featureRow, info] = adaptive_frontend_extract_features(capture, txPreamble, N0, opts)
%ADAPTIVE_FRONTEND_EXTRACT_FEATURES  Extract frame-level features for interference selection.

arguments
    capture (1,1) struct
    txPreamble (:,1) double
    N0 (1,1) double {mustBeNonnegative}
    opts.channelLenSymbols (1,1) double {mustBePositive} = 4
end

txPreamble = txPreamble(:);
featureNames = ml_interference_selector_feature_names();
featureRow = zeros(1, numel(featureNames));
info = struct( ...
    "featureNames", featureNames, ...
    "channelEstimate", complex(zeros(0, 1)), ...
    "residual", complex(zeros(0, 1)), ...
    "metrics", struct());

if ~(isfield(capture, "ok") && capture.ok && isfield(capture, "rFull") && numel(capture.rFull) >= numel(txPreamble))
    return;
end

rxPre = capture.rFull(1:numel(txPreamble));
[hEst, preHat] = local_estimate_channel(txPreamble, rxPre, max(1, round(double(opts.channelLenSymbols))));
resid = rxPre - preHat;

[fftPeakRatio, fftBandOcc, fftDominantBw] = local_fft_shape_metrics(capture.rFull);
stftDrift = local_stft_drift_metric(capture.rFull);
[tailRatio, delaySpread] = local_channel_shape_metrics(hEst);
[gainErr, cfoAbs, peakToMedian, peakToSecond] = local_sync_metrics(capture);

residAbs = abs(resid);
residMed = median(residAbs) + eps;
residEnergy = mean(abs(resid).^2) / max(mean(abs(rxPre).^2), eps);
residPeakRatio = max(residAbs) / residMed;
residKurtosis = local_real_kurtosis(residAbs);
residOutlierRate = mean(residAbs > 3 * residMed);

featureRow = [ ...
    residEnergy, ...
    residPeakRatio, ...
    residKurtosis, ...
    residOutlierRate, ...
    fftPeakRatio, ...
    fftBandOcc, ...
    fftDominantBw, ...
    stftDrift, ...
    tailRatio, ...
    delaySpread, ...
    cfoAbs, ...
    gainErr, ...
    peakToMedian, ...
    peakToSecond];
featureRow(~isfinite(featureRow)) = 0;

info.channelEstimate = hEst;
info.residual = resid;
info.metrics = struct( ...
    "residEnergy", residEnergy, ...
    "residPeakRatio", residPeakRatio, ...
    "residKurtosis", residKurtosis, ...
    "residOutlierRate", residOutlierRate, ...
    "fftPeakRatio", fftPeakRatio, ...
    "fftBandOcc", fftBandOcc, ...
    "fftDominantBw", fftDominantBw, ...
    "stftDrift", stftDrift, ...
    "tailRatio", tailRatio, ...
    "delaySpread", delaySpread, ...
    "gainErr", gainErr, ...
    "cfoAbs", cfoAbs, ...
    "peakToMedian", peakToMedian, ...
    "peakToSecond", peakToSecond);
end

function [hEst, preHat] = local_estimate_channel(tx, rx, Lh)
L = min(numel(tx), numel(rx));
tx = tx(1:L);
rx = rx(1:L);
Lh = min(max(1, Lh), max(1, floor(L / 2)));

Xfull = toeplitz([tx; zeros(Lh - 1, 1)], [tx(1); zeros(Lh - 1, 1)]);
X = Xfull(1:L, :);
try
    hEst = X \ rx;
catch
    hEst = complex(zeros(Lh, 1));
end
preHat = X * hEst;
end

function [peakRatio, bandOcc, dominantBw] = local_fft_shape_metrics(x)
x = x(:);
N = numel(x);
if N == 0
    peakRatio = 0;
    bandOcc = 0;
    dominantBw = 0;
    return;
end

nfft = 2^nextpow2(max(N, 64));
S = fftshift(fft(x, nfft));
P = abs(S).^2;
f = ((0:nfft-1).' / nfft) - 0.5;
valid = abs(f) >= 0.01;
noiseFloor = median(P(valid));
if ~isfinite(noiseFloor) || noiseFloor <= 0
    noiseFloor = mean(P(valid)) + eps;
end
peakRatio = max(P(valid)) / noiseFloor;
hot = valid & P > 4 * noiseFloor;
bandOcc = mean(double(hot(valid)));

hotIdx = find(hot);
groups = local_group_hot_bins(hotIdx);
if isempty(groups)
    dominantBw = 0;
else
    dominantBw = max(cellfun(@numel, groups)) / nfft;
end
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
        pValid = P;
        pValid(~valid) = -inf;
        [~, idx] = max(pValid);
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

function [tailRatio, delaySpread] = local_channel_shape_metrics(hEst)
hEst = hEst(:);
pow = abs(hEst).^2;
powSum = sum(pow);
if powSum <= 0
    tailRatio = 0;
    delaySpread = 0;
    return;
end
tailRatio = sum(pow(2:end)) / powSum;
idx = (0:numel(hEst)-1).';
delaySpread = sum((idx .^ 2) .* pow) / powSum;
end

function [gainErr, cfoAbs, peakToMedian, peakToSecond] = local_sync_metrics(capture)
gainErr = 0;
cfoAbs = 0;
peakToMedian = 0;
peakToSecond = 0;
if ~(isfield(capture, "syncInfo") && isstruct(capture.syncInfo))
    return;
end
syncInfo = capture.syncInfo;
if isfield(syncInfo, "chanGainEstimate") && ~isempty(syncInfo.chanGainEstimate)
    gainErr = abs(abs(syncInfo.chanGainEstimate) - 1);
end
if isfield(syncInfo, "cfoRadPerSample") && ~isempty(syncInfo.cfoRadPerSample)
    cfoAbs = abs(double(syncInfo.cfoRadPerSample));
end
if isfield(syncInfo, "corrPeakToMedian") && ~isempty(syncInfo.corrPeakToMedian)
    peakToMedian = max(0, double(syncInfo.corrPeakToMedian));
end
if isfield(syncInfo, "corrPeakToSecond") && ~isempty(syncInfo.corrPeakToSecond)
    peakToSecond = max(0, double(syncInfo.corrPeakToSecond));
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
