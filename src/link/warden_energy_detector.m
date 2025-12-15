function m = warden_energy_detector(txBurst, N0, ch, maxDelaySymbols, det)
%WARDEN_ENERGY_DETECTOR  辐射计（能量检测器）Pd/Pfa估计。
%
% txBurst: 发送符号（无前导延迟），列向量。
% N0: channel_bg_impulsive()使用的噪声功率谱密度。
% ch: channel_bg_impulsive()使用的信道配置。
% maxDelaySymbols: 随机前导零延迟范围[0, maxDelaySymbols]。
% det: 结构体，包含字段：
%   - pfaTarget (0..1)
%   - nObs（观测窗口长度，符号数）
%   - nTrials（蒙特卡洛试验次数）

arguments
    txBurst (:,1) double
    N0 (1,1) double {mustBePositive}
    ch (1,1) struct
    maxDelaySymbols (1,1) double {mustBeNonnegative}
    det (1,1) struct
end

if ~isfield(det, "pfaTarget"); det.pfaTarget = 0.01; end
if ~isfield(det, "nObs"); det.nObs = 4096; end
if ~isfield(det, "nTrials"); det.nTrials = 200; end

pfaTarget = double(det.pfaTarget);
nObs = double(det.nObs);
nTrials = double(det.nTrials);

if ~(pfaTarget > 0 && pfaTarget < 1)
    error("pfaTarget必须在(0,1)范围内。");
end
if ~(nObs >= 16)
    error("nObs必须 >= 16。");
end
if ~(nTrials >= 10)
    error("nTrials必须 >= 10。");
end

txBurst = txBurst(:);
L = min(nObs, numel(txBurst) + maxDelaySymbols);

T0 = zeros(nTrials, 1);
T1 = zeros(nTrials, 1);

for i = 1:nTrials
    delay = randi([0, maxDelaySymbols], 1, 1);

    txWin = zeros(L, 1);
    if delay < L
        nSig = min(numel(txBurst), L - delay);
        if nSig > 0
            txWin(delay+1:delay+nSig) = txBurst(1:nSig);
        end
    end

    r0 = channel_bg_impulsive(zeros(L, 1), N0, ch);
    r1 = channel_bg_impulsive(txWin, N0, ch);

    T0(i) = mean(abs(r0).^2);
    T1(i) = mean(abs(r1).^2);
end

T0s = sort(T0);
q = 1 - pfaTarget;
idx = max(1, min(nTrials, ceil(q * nTrials)));
threshold = T0s(idx);

pfaEst = mean(T0 > threshold);
pdEst = mean(T1 > threshold);
peEst = 0.5 * (pfaEst + 1 - pdEst);

m = struct();
m.pfaTarget = pfaTarget;
m.nObs = L;
m.nTrials = nTrials;
m.threshold = threshold;
m.pfaEst = pfaEst;
m.pdEst = pdEst;
m.peEst = peEst;
end

