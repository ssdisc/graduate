function [y, info] = adaptive_notch_filter(x, cfg)
%ADAPTIVE_NOTCH_FILTER  自适应估计干扰频率并应用IIR陷波。
%
% 输入:
%   x   - 输入符号序列（列向量）
%   cfg - 配置结构体（可选）
%         .peakRatio  峰值/噪声底阈值（默认8）
%         .radius     陷波极点半径（默认0.97）
%         .minFreqAbs 忽略近DC区域（默认0.01 cycles/sample）
%         .stages     级联陷波阶数（默认1）
%
% 输出:
%   y    - 滤波后序列
%   info - 诊断信息

if nargin < 2
    cfg = struct();
end
if ~isfield(cfg, "peakRatio"); cfg.peakRatio = 8; end
if ~isfield(cfg, "radius"); cfg.radius = 0.97; end
if ~isfield(cfg, "minFreqAbs"); cfg.minFreqAbs = 0.01; end
if ~isfield(cfg, "stages"); cfg.stages = 1; end

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
[peakPow, idx] = max(P .* double(valid));
if ~isfinite(peakPow) || peakPow <= peakRatio * noiseFloor
    y = x;
    info = struct("applied", false, "noiseFloor", noiseFloor);
    return;
end

f0 = f(idx); % cycles/sample
w0 = 2*pi*f0;
r = min(max(double(cfg.radius), 0.7), 0.9995);
stages = max(1, round(double(cfg.stages)));

b = [1, -2*cos(w0), 1];
a = [1, -2*r*cos(w0), r^2];

y = x;
for k = 1:stages
    y = filter(b, a, y);
end

info = struct();
info.applied = true;
info.f0 = f0;
info.w0 = w0;
info.radius = r;
info.stages = stages;
info.peakPower = peakPow;
info.noiseFloor = noiseFloor;
end
