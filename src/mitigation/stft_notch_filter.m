function [y, info] = stft_notch_filter(x, cfg)
%STFT_NOTCH_FILTER  Frame-wise peak tracking notch for sweep/chirp interference.

if nargin < 2
    cfg = struct();
end
if ~isfield(cfg, "windowLength"); cfg.windowLength = 128; end
if ~isfield(cfg, "hopLength"); cfg.hopLength = 32; end
if ~isfield(cfg, "peakRatio"); cfg.peakRatio = 8; end
if ~isfield(cfg, "maxBins"); cfg.maxBins = 2; end
if ~isfield(cfg, "halfWidth"); cfg.halfWidth = 1; end
if ~isfield(cfg, "minFreqAbs"); cfg.minFreqAbs = 0.01; end

x = x(:);
N = numel(x);
if N == 0
    y = x;
    info = struct("applied", false);
    return;
end

winLen = max(16, round(double(cfg.windowLength)));
hopLen = max(1, round(double(cfg.hopLength)));
peakRatio = max(1.1, double(cfg.peakRatio));
maxBins = max(1, round(double(cfg.maxBins)));
halfWidth = max(0, round(double(cfg.halfWidth)));

if N < winLen
    xPad = [x; complex(zeros(winLen - N, 1))];
else
    nFrames = 1 + ceil((N - winLen) / hopLen);
    outLen = (nFrames - 1) * hopLen + winLen;
    xPad = [x; complex(zeros(max(0, outLen - N), 1))];
end

win = hamming(winLen, "periodic");
nFrames = 1 + floor((numel(xPad) - winLen) / hopLen);
nfft = 2^nextpow2(winLen);
f = ((0:nfft-1).' / nfft) - 0.5;
valid = abs(f) >= abs(double(cfg.minFreqAbs));

yAcc = complex(zeros(numel(xPad), 1));
wAcc = zeros(numel(xPad), 1);
appliedFrames = 0;
dominantFreq = nan(nFrames, 1);

for frameIdx = 1:nFrames
    startIdx = (frameIdx - 1) * hopLen + 1;
    seg = xPad(startIdx:startIdx+winLen-1) .* win;
    S = fftshift(fft(seg, nfft));
    P = abs(S).^2;
    noiseFloor = median(P(valid));
    if ~isfinite(noiseFloor) || noiseFloor <= 0
        noiseFloor = mean(P(valid)) + eps;
    end

    cand = find(valid & P > peakRatio * noiseFloor);
    if ~isempty(cand)
        [~, ord] = sort(P(cand), "descend");
        cand = cand(ord);
        picked = zeros(0, 1);
        for k = 1:numel(cand)
            idx = cand(k);
            if any(abs(idx - picked) <= (2 * halfWidth + 1))
                continue;
            end
            picked(end+1, 1) = idx; %#ok<AGROW>
            if numel(picked) >= maxBins
                break;
            end
        end

        if ~isempty(picked)
            dominantFreq(frameIdx) = f(picked(1));
            for k = 1:numel(picked)
                left = max(1, picked(k) - halfWidth);
                right = min(nfft, picked(k) + halfWidth);
                S(left:right) = 0;
            end
            appliedFrames = appliedFrames + 1;
        end
    end

    segOut = ifft(ifftshift(S), nfft);
    segOut = segOut(1:winLen) .* win;
    yAcc(startIdx:startIdx+winLen-1) = yAcc(startIdx:startIdx+winLen-1) + segOut;
    wAcc(startIdx:startIdx+winLen-1) = wAcc(startIdx:startIdx+winLen-1) + win.^2;
end

wAcc(wAcc < 1e-12) = 1;
yPad = yAcc ./ wAcc;
y = yPad(1:N);

info = struct();
info.applied = appliedFrames > 0;
info.appliedFrames = appliedFrames;
info.nFrames = nFrames;
info.nfft = nfft;
info.dominantFreq = dominantFreq;
end
