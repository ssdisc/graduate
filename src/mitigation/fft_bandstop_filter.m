function [y, info] = fft_bandstop_filter(x, cfg)
%FFT_BANDSTOP_FILTER  Detect contiguous narrowband interferers and zero them in FFT domain.

if nargin < 2
    cfg = struct();
end
if ~isfield(cfg, "peakRatio"); cfg.peakRatio = 6; end
if ~isfield(cfg, "maxBands"); cfg.maxBands = 1; end
if ~isfield(cfg, "mergeGapBins"); cfg.mergeGapBins = 2; end
if ~isfield(cfg, "padBins"); cfg.padBins = 1; end
if ~isfield(cfg, "minFreqAbs"); cfg.minFreqAbs = 0.01; end

x = x(:);
N = numel(x);
if N == 0
    y = x;
    info = struct("applied", false);
    return;
end

nfft = 2^nextpow2(max(N, 64));
S = fftshift(fft(x, nfft));
P = abs(S).^2;
f = ((0:nfft-1).' / nfft) - 0.5;

valid = abs(f) >= abs(double(cfg.minFreqAbs));
noiseFloor = median(P(valid));
if ~isfinite(noiseFloor) || noiseFloor <= 0
    noiseFloor = mean(P(valid)) + eps;
end

peakRatio = max(1.1, double(cfg.peakRatio));
cand = find(valid & P > peakRatio * noiseFloor);
if isempty(cand)
    y = x;
    info = struct("applied", false, "noiseFloor", noiseFloor);
    return;
end

mergeGap = max(0, round(double(cfg.mergeGapBins)));
groups = local_group_bins(cand, mergeGap);
if isempty(groups)
    y = x;
    info = struct("applied", false, "noiseFloor", noiseFloor);
    return;
end

maxBands = max(1, round(double(cfg.maxBands)));
scores = zeros(numel(groups), 1);
for k = 1:numel(groups)
    idx = groups{k};
    scores(k) = max(P(idx)) * numel(idx);
end
[~, ord] = sort(scores, "descend");
pickCount = min(maxBands, numel(ord));
picked = groups(ord(1:pickCount));

padBins = max(0, round(double(cfg.padBins)));
mask = false(nfft, 1);
edges = zeros(pickCount, 2);
centerFreq = zeros(pickCount, 1);
for k = 1:pickCount
    idx = picked{k};
    left = max(1, idx(1) - padBins);
    right = min(nfft, idx(end) + padBins);
    mask(left:right) = true;
    edges(k, :) = [left right];
    centerFreq(k) = mean(f(idx));
end

S(mask) = 0;
yTmp = ifft(ifftshift(S), nfft);
y = yTmp(1:N);

info = struct();
info.applied = true;
info.nfft = nfft;
info.noiseFloor = noiseFloor;
info.bandEdges = edges;
info.centerFreq = centerFreq;
info.bandWidthBins = edges(:, 2) - edges(:, 1) + 1;
end

function groups = local_group_bins(idx, mergeGap)
idx = sort(idx(:));
groups = cell(0, 1);
if isempty(idx)
    return;
end

startPos = 1;
for k = 2:numel(idx)
    if idx(k) - idx(k-1) > mergeGap + 1
        groups{end+1, 1} = idx(startPos:k-1); %#ok<AGROW>
        startPos = k;
    end
end
groups{end+1, 1} = idx(startPos:end);
end
