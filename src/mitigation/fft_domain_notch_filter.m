function [y, info] = fft_domain_notch_filter(x, cfg)
%FFT_DOMAIN_NOTCH_FILTER  频域峰值检测 + 陷波抑制（FFT变换域滤波）。
%
% 输入:
%   x   - 输入符号序列（列向量）
%   cfg - 配置结构体（可选）
%         .peakRatio      峰值/噪声底阈值（默认10）
%         .maxNotches     最大陷波数（默认2）
%         .notchHalfWidth 每个陷波的半宽bin数（默认1）
%         .minFreqAbs     忽略近DC区域（默认0.01 cycles/sample）
%
% 输出:
%   y    - 滤波后序列
%   info - 诊断信息

if nargin < 2
    cfg = struct();
end
if ~isfield(cfg, "peakRatio"); cfg.peakRatio = 10; end
if ~isfield(cfg, "maxNotches"); cfg.maxNotches = 2; end
if ~isfield(cfg, "notchHalfWidth"); cfg.notchHalfWidth = 1; end
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

[~, ord] = sort(P(cand), "descend");
cand = cand(ord);

maxNotches = max(1, round(double(cfg.maxNotches)));
halfW = max(0, round(double(cfg.notchHalfWidth)));

picked = zeros(0, 1);
for k = 1:numel(cand)
    idx = cand(k);
    if any(abs(idx - picked) <= (2*halfW + 1))
        continue;
    end
    picked(end+1, 1) = idx; %#ok<AGROW>
    if numel(picked) >= maxNotches
        break;
    end
end

notchMask = false(nfft, 1);
for k = 1:numel(picked)
    left = max(1, picked(k) - halfW);
    right = min(nfft, picked(k) + halfW);
    notchMask(left:right) = true;
end

SNotch = S;
SNotch(notchMask) = 0;
yTmp = ifft(ifftshift(SNotch), nfft);
y = yTmp(1:N);

info = struct();
info.applied = true;
info.nfft = nfft;
info.notchBins = picked;
info.notchFreq = f(picked);
info.noiseFloor = noiseFloor;
info.peakPower = P(picked);
end
