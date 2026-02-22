function m = warden_energy_detector(txBurst, N0, ch, maxDelaySymbols, det)
%WARDEN_ENERGY_DETECTOR  辐射计（能量检测器）Pd/Pfa估计。
%
% 输入:
%   txBurst         - 发送符号（无前导延迟），列向量
%   N0              - 背景噪声功率谱密度
%   ch              - 信道配置结构体（同channel_bg_impulsive）
%                     .impulseProb, .impulseToBgRatio
%   maxDelaySymbols - 随机前导零延迟范围[0, maxDelaySymbols]
%   det             - 检测器配置结构体
%                     .pfaTarget - 目标虚警率(0,1)
%                     .nObs      - 观测窗口长度（符号数）
%                     .nTrials   - 蒙特卡洛试验次数
%
% 输出:
%   m - 检测性能结构体
%       .threshold - 能量判决阈值（由H0统计量按目标虚警率分位数确定）
%       .pfaEst    - 估计虚警率 Pfa（H0下误报“有信号”的概率）
%       .pdEst     - 估计检测率 Pd（H1下正确判定“有信号”的概率）
%       .peEst     - 等先验下平均判错率 Pe = 0.5 * (Pfa + 1 - Pd)
%       .pfaTarget - 目标虚警率（检测器设计参数）
%       .nObs      - 实际观测窗口长度（符号数，受突发长度与延迟范围约束）
%       .nTrials   - 蒙特卡洛试验次数（用于估计阈值与检测性能）

arguments
    txBurst (:,1) double
    N0 (1,1) double {mustBePositive}
    ch (1,1) struct
    maxDelaySymbols (1,1) double {mustBeNonnegative}
    det (1,1) struct
end

% 设置默认参数
if ~isfield(det, "pfaTarget"); det.pfaTarget = 0.01; end
if ~isfield(det, "nObs"); det.nObs = 4096; end
if ~isfield(det, "nTrials"); det.nTrials = 200; end 

% 参数验证
pfaTarget = double(det.pfaTarget);
nObs = double(det.nObs);
nTrials = double(det.nTrials); 

% 参数合理性检查
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

% 蒙特卡洛仿真
T0 = zeros(nTrials, 1);
T1 = zeros(nTrials, 1);

% 对每次试验，随机生成一个前导零延迟，并构造对应的观测窗口。
% 然后分别在H0（无信号）和H1（有信号）条件下通过信道模型生成观测数据，并计算能量统计量。
for i = 1:nTrials
    delay = randi([0, maxDelaySymbols], 1, 1);

    txWin = zeros(L, 1);
    if delay < L 
        nSig = min(numel(txBurst), L - delay); 
        if nSig > 0
            txWin(delay+1:delay+nSig) = txBurst(1:nSig); 
        end
    end

    r0 = channel_bg_impulsive(zeros(L, 1), N0, ch);%H0：输入全零，观测仅包含噪声和冲击干扰
    r1 = channel_bg_impulsive(txWin, N0, ch);%H1：输入包含信号（可能部分被前导零覆盖），观测包含信号、噪声和冲击干扰

    T0(i) = mean(abs(r0).^2);
    T1(i) = mean(abs(r1).^2);
end

T0s = sort(T0);
q = 1 - pfaTarget;
idx = max(1, min(nTrials, ceil(q * nTrials)));
threshold = T0s(idx);%根据H0统计量的排序结果和目标虚警率确定能量判决阈值，即H0统计量的(1-pfaTarget)分位数。

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


