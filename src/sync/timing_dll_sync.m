function [ySym, ok, info] = timing_dll_sync(x, startPos, nSamp, modCfg, dllCfg, samplesPerSymbol)
%TIMING_DLL_SYNC  基于Early-Late门的符号级DLL定时跟踪。
%
% 输入:
%   x        - 输入序列（列向量，允许复数）
%   startPos - 初始采样起点（可为分数）
%   nSamp    - 需提取的符号数
%   modCfg   - 调制配置（用于判决导向误差）
%   dllCfg   - DLL参数
%              .enable            - 是否启用
%              .earlyLateSpacing  - Early/Late间隔（symbol）
%              .alpha             - 一阶环增益
%              .beta              - 二阶环增益
%              .maxOffset         - 定时偏移限幅（symbol）
%              .decisionDirected  - true=判决导向，false=非数据辅助
%   samplesPerSymbol - 输入序列每个符号对应的采样数
%
% 输出:
%   ySym - 跟踪后的符号抽样
%   ok   - 是否成功
%   info - 诊断信息（误差与偏移轨迹）

arguments
    x (:,1)
    startPos (1,1) double
    nSamp (1,1) double {mustBeInteger, mustBeNonnegative}
    modCfg (1,1) struct
    dllCfg (1,1) struct
    samplesPerSymbol (1,1) double {mustBePositive} = 1
end

if nSamp == 0 || isempty(x)
    ySym = complex(zeros(0, 1));
    ok = false;
    info = struct("enabled", false);
    return;
end

if ~isfield(dllCfg, "enable"); dllCfg.enable = false; end
if ~dllCfg.enable
    idx = (1:numel(x)).';
    t = startPos + (0:nSamp-1).' * samplesPerSymbol;
    ySym = interp1(idx, x, t, "linear", 0);
    ok = all(isfinite(ySym)) && any(abs(ySym) > 0);
    info = struct("enabled", false, "sampleTimes", t);
    return;
end

if ~isfield(dllCfg, "earlyLateSpacing"); dllCfg.earlyLateSpacing = 0.45; end
if ~isfield(dllCfg, "alpha"); dllCfg.alpha = 0.03; end
if ~isfield(dllCfg, "beta"); dllCfg.beta = 5e-4; end
if ~isfield(dllCfg, "maxOffset"); dllCfg.maxOffset = 0.75; end
if ~isfield(dllCfg, "decisionDirected"); dllCfg.decisionDirected = true; end

deltaSym = max(0.05, min(0.95, abs(double(dllCfg.earlyLateSpacing))));
alpha = abs(double(dllCfg.alpha));
beta = abs(double(dllCfg.beta));
maxOffsetSym = max(0.1, abs(double(dllCfg.maxOffset)));
useDd = logical(dllCfg.decisionDirected);
samplesPerSymbol = double(samplesPerSymbol);
delta = deltaSym * samplesPerSymbol;
maxOffset = maxOffsetSym * samplesPerSymbol;

idxAxis = (1:numel(x)).';
guard = 2;

ySym = complex(zeros(nSamp, 1));
errHist = zeros(nSamp, 1);
tauHist = zeros(nSamp, 1);
freqHist = zeros(nSamp, 1);
timeHist = zeros(nSamp, 1);

tau = 0;
omega = 0;
ok = true;

for k = 1:nSamp
    tNow = startPos + (k-1) * samplesPerSymbol + tau;
    if tNow < 1 - guard || tNow > numel(x) + guard
        ok = false;
        break;
    end

    on = interp1(idxAxis, x, tNow, "linear", 0);
    early = interp1(idxAxis, x, tNow - delta, "linear", 0);
    late = interp1(idxAxis, x, tNow + delta, "linear", 0);

    if useDd
        d = slicer_symbol(on, modCfg);
        err = real((late - early) * conj(d));
    else
        err = abs(late)^2 - abs(early)^2;
    end

    omega = omega + beta * err;
    tau = tau + omega + alpha * err;
    tau = min(max(tau, -maxOffset), maxOffset);

    ySym(k) = on;
    errHist(k) = err;
    tauHist(k) = tau;
    freqHist(k) = omega;
    timeHist(k) = tNow;
end

if ~ok
    ySym(:) = 0;
end

info = struct();
info.enabled = true;
info.ok = ok;
info.error = errHist;
info.timingOffset = tauHist;
info.timingRate = freqHist;
info.sampleTimes = timeHist;
info.finalOffset = tau / samplesPerSymbol;
info.finalRate = omega;
end

function d = slicer_symbol(y, modCfg)
modType = "BPSK";
if isfield(modCfg, "type")
    modType = upper(string(modCfg.type));
end

switch modType
    case "BPSK"
        b = sign(real(y));
        if b == 0; b = 1; end
        d = complex(b, 0);
    case {"QPSK", "MSK"}
        bi = sign(real(y));
        bq = sign(imag(y));
        if bi == 0; bi = 1; end
        if bq == 0; bq = 1; end
        d = (bi + 1j*bq) / sqrt(2);
    otherwise
        b = sign(real(y));
        if b == 0; b = 1; end
        d = complex(b, 0);
end
end
