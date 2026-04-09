function [y, info] = fft_bandstop_filter(x, cfg)
%FFT_BANDSTOP_FILTER  Detect contiguous narrowband interferers and suppress them in FFT domain.

if nargin < 2
    cfg = struct();
end
if ~isfield(cfg, "peakRatio"); cfg.peakRatio = 6; end
if ~isfield(cfg, "edgeRatio"); cfg.edgeRatio = 2.5; end
if ~isfield(cfg, "maxBands"); cfg.maxBands = 1; end
if ~isfield(cfg, "mergeGapBins"); cfg.mergeGapBins = 2; end
if ~isfield(cfg, "padBins"); cfg.padBins = 1; end
if ~isfield(cfg, "minBandBins"); cfg.minBandBins = 3; end
if ~isfield(cfg, "smoothSpanBins"); cfg.smoothSpanBins = 7; end
if ~isfield(cfg, "fftOversample"); cfg.fftOversample = 4; end
if ~isfield(cfg, "maxBandwidthFrac"); cfg.maxBandwidthFrac = 0.22; end
if ~isfield(cfg, "minFreqAbs"); cfg.minFreqAbs = 0.01; end
if ~isfield(cfg, "suppressToFloor"); cfg.suppressToFloor = false; end

x = x(:);
N = numel(x);
if N == 0
    y = x;
    info = struct("applied", false);
    return;
end

oversample = max(1, round(double(cfg.fftOversample)));
nfft = 2^nextpow2(max(N * oversample, 256));
win = hamming(N, "periodic");
Xdet = fftshift(fft(x .* win, nfft));
S = fftshift(fft(x, nfft));
Pdet = abs(Xdet).^2 / max(mean(abs(win).^2), eps);
Papply = abs(S).^2;
f = ((0:nfft-1).' / nfft) - 0.5;

valid = abs(f) >= abs(double(cfg.minFreqAbs));
detectFloor = local_noise_floor(Pdet, valid);
applyFloor = local_noise_floor(Papply, valid);
peakRatio = max(1.1, double(cfg.peakRatio));
edgeRatio = min(max(double(cfg.edgeRatio), 1.0), peakRatio);
smoothSpan = local_odd_span(double(cfg.smoothSpanBins), nfft);
mergeGap = max(0, round(double(cfg.mergeGapBins)));
padBins = max(0, round(double(cfg.padBins)));
minBandBins = max(1, round(double(cfg.minBandBins)));
maxBands = max(1, round(double(cfg.maxBands)));
maxBandwidthBins = max(minBandBins, round(double(cfg.maxBandwidthFrac) * nfft));

Ps = movmean(Pdet, smoothSpan);
seedIdx = find(valid & Ps > peakRatio * detectFloor);
if isempty(seedIdx)
    y = x;
    info = local_empty_info(false, nfft, detectFloor, applyFloor);
    return;
end

groups = local_group_bins(seedIdx, mergeGap);
bandTable = zeros(0, 4);
bandScores = zeros(0, 1);
for k = 1:numel(groups)
    idx = groups{k};
    [left, right, peakIdx, peakRatioNow] = local_refine_band(idx, Pdet, Ps, valid, detectFloor, edgeRatio, minBandBins);
    if right < left
        continue;
    end
    width = right - left + 1;
    if width > maxBandwidthBins
        continue;
    end
    score = sum(max(Pdet(left:right) - detectFloor, 0));
    if ~(isfinite(score) && score > 0)
        continue;
    end
    bandTable(end + 1, :) = [left, right, peakIdx, peakRatioNow]; %#ok<AGROW>
    bandScores(end + 1, 1) = score; %#ok<AGROW>
end

if isempty(bandTable)
    y = x;
    info = local_empty_info(false, nfft, detectFloor, applyFloor);
    return;
end

[~, ord] = sort(bandScores, "descend");
pickCount = min(maxBands, numel(ord));
selected = bandTable(ord(1:pickCount), :);
selected = local_merge_interval_rows(selected);

mask = false(nfft, 1);
edges = zeros(size(selected, 1), 2);
centerFreq = zeros(size(selected, 1), 1);
bandWidthBins = zeros(size(selected, 1), 1);
peakRatios = zeros(size(selected, 1), 1);
for k = 1:size(selected, 1)
    left = max(1, round(selected(k, 1)) - padBins);
    right = min(nfft, round(selected(k, 2)) + padBins);
    mask(left:right) = true;
    edges(k, :) = [left right];
    bandWidthBins(k) = right - left + 1;
    centerFreq(k) = mean(f(round(selected(k, 1)):round(selected(k, 2))));
    peakRatios(k) = selected(k, 4);
end

if ~any(mask)
    y = x;
    info = local_empty_info(false, nfft, detectFloor, applyFloor);
    return;
end

if logical(cfg.suppressToFloor)
    gain = ones(nfft, 1);
    gain(mask) = sqrt(min(1, applyFloor ./ max(Papply(mask), applyFloor)));
    S = S .* gain;
else
    gain = ones(nfft, 1);
    gain(mask) = 0;
    S(mask) = 0;
end

yTmp = ifft(ifftshift(S), nfft);
y = yTmp(1:N);

info = struct();
info.applied = true;
info.nfft = nfft;
info.noiseFloor = applyFloor;
info.detectNoiseFloor = detectFloor;
info.bandEdges = edges;
info.centerFreq = centerFreq;
info.bandWidthBins = bandWidthBins;
info.selectedBandwidthFrac = bandWidthBins / nfft;
info.peakRatios = peakRatios;
info.bandScores = bandScores(ord(1:pickCount));
info.suppressionGain = gain(mask);
info.maskFraction = mean(mask);
end

function info = local_empty_info(applied, nfft, detectFloor, applyFloor)
info = struct( ...
    "applied", logical(applied), ...
    "nfft", double(nfft), ...
    "noiseFloor", double(applyFloor), ...
    "detectNoiseFloor", double(detectFloor), ...
    "bandEdges", zeros(0, 2), ...
    "centerFreq", zeros(0, 1), ...
    "bandWidthBins", zeros(0, 1), ...
    "selectedBandwidthFrac", zeros(0, 1), ...
    "peakRatios", zeros(0, 1), ...
    "bandScores", zeros(0, 1), ...
    "suppressionGain", zeros(0, 1), ...
    "maskFraction", 0);
end

function floorNow = local_noise_floor(P, valid)
floorNow = median(P(valid));
if ~isfinite(floorNow) || floorNow <= 0
    floorNow = mean(P(valid)) + eps;
end
if ~isfinite(floorNow) || floorNow <= 0
    floorNow = eps;
end
end

function span = local_odd_span(rawSpan, maxLen)
span = max(1, round(double(rawSpan)));
span = min(span, maxLen);
if mod(span, 2) == 0
    span = max(1, span + 1);
    if span > maxLen
        span = max(1, span - 2);
    end
end
end

function [left, right, peakIdx, peakRatioNow] = local_refine_band(idx, Pdet, Ps, valid, floorNow, edgeRatio, minBandBins)
idx = sort(idx(:));
[peakPow, relPeak] = max(Pdet(idx));
peakIdx = idx(relPeak);
peakRatioNow = peakPow / max(floorNow, eps);

left = idx(1);
right = idx(end);
edgeThr = edgeRatio * floorNow;

while left > 1 && valid(left - 1) && Ps(left - 1) >= edgeThr
    left = left - 1;
end
while right < numel(Ps) && valid(right + 1) && Ps(right + 1) >= edgeThr
    right = right + 1;
end

while (right - left + 1) < minBandBins
    grew = false;
    if left > 1 && valid(left - 1)
        left = left - 1;
        grew = true;
    end
    if (right - left + 1) >= minBandBins
        break;
    end
    if right < numel(Ps) && valid(right + 1)
        right = right + 1;
        grew = true;
    end
    if ~grew
        break;
    end
end
end

function rows = local_merge_interval_rows(rows)
if isempty(rows)
    return;
end
rows = sortrows(rows, 1);
writeIdx = 1;
for readIdx = 2:size(rows, 1)
    if rows(readIdx, 1) <= rows(writeIdx, 2) + 1
        rows(writeIdx, 2) = max(rows(writeIdx, 2), rows(readIdx, 2));
        if rows(readIdx, 4) > rows(writeIdx, 4)
            rows(writeIdx, 3) = rows(readIdx, 3);
            rows(writeIdx, 4) = rows(readIdx, 4);
        end
    else
        writeIdx = writeIdx + 1;
        rows(writeIdx, :) = rows(readIdx, :);
    end
end
rows = rows(1:writeIdx, :);
end

function groups = local_group_bins(idx, mergeGap)
idx = sort(idx(:));
groups = cell(0, 1);
if isempty(idx)
    return;
end

startPos = 1;
for k = 2:numel(idx)
    if idx(k) - idx(k - 1) > mergeGap + 1
        groups{end + 1, 1} = idx(startPos:k - 1); %#ok<AGROW>
        startPos = k;
    end
end
groups{end + 1, 1} = idx(startPos:end);
end
