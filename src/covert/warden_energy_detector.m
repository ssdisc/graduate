function m = warden_energy_detector(txBurst, N0, ch, maxDelaySymbols, det)
%WARDEN_ENERGY_DETECTOR  五层Warden检测器评估（宽带能量/窄带能量/循环平稳）。
%
% 输入:
%   txBurst         - 发送符号（无前导延迟），列向量（已含跳频+脉冲成型）
%   N0              - 背景噪声功率谱密度
%   ch              - 信道配置结构体（同channel_bg_impulsive）
%                     .impulseProb, .impulseToBgRatio
%   maxDelaySymbols - 随机前导零延迟范围[0, maxDelaySymbols]
%   det             - 检测器配置结构体
%                     .pfaTarget          - 第一层的目标虚警率(0,1)
%                     .nObs               - 观测窗口长度（采样点）
%                     .nTrials            - 蒙特卡洛试验次数
%                     .primaryLayer       - "energyNp"|"energyOpt"|"energyOptUncertain"|
%                                           "energyFhNarrow"|"cyclostationaryOpt"
%                     .noiseUncertaintyDb - 第三层噪声不确定性半宽（+-dB）
%                     .extraDelaySamples  - 第三层额外时延不确定性（采样点）
%                     .referenceLink      - Warden链路来源标签，仅用于结果记录
%                     .fhNarrowband       - 跳频窄带Warden配置（可选）
%                       .enable           - 是否启用窄带Warden层
%                       .nFreqs           - 跳频频点数（用于确定单信道带宽）
%                       .scanAllBins      - true=扫描所有频点取最大能量（最优Warden），
%                                           false=随机选一个频点（实际Warden）
%                     .cyclostationary    - 循环平稳检测器配置（可选）
%                       .enable           - 是否启用循环平稳层
%                       .sps              - 每符号采样数（用于确定循环频率alpha=1/sps）
%
% 输出:
%   m - 检测性能结构体
%       .layers.energyNp           - 固定P_FA目标的工程检测层
%       .layers.energyOpt          - 最优阈值下的文献常用xi*层
%       .layers.energyOptUncertain - 噪声/时延不确定性的更实际xi*层
%       .layers.energyFhNarrow     - 窄带Warden层（不知跳频序列时的实际检测能力）
%       .layers.cyclostationaryOpt - 循环平稳检测器层（利用符号率周期特征）
%       以及为兼容旧代码保留的顶层字段：
%       .threshold/.pfaEst/.pdEst/.peEst 等，对应第一层energyNp。

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
if ~isfield(det, "primaryLayer"); det.primaryLayer = "energyOptUncertain"; end
if ~isfield(det, "noiseUncertaintyDb"); det.noiseUncertaintyDb = 1.0; end
if ~isfield(det, "extraDelaySamples"); det.extraDelaySamples = 4096; end
if ~isfield(det, "referenceLink"); det.referenceLink = "unknown"; end
if ~isfield(det, "fhNarrowband"); det.fhNarrowband = struct(); end
if ~isfield(det.fhNarrowband, "enable"); det.fhNarrowband.enable = false; end
if ~isfield(det.fhNarrowband, "nFreqs"); det.fhNarrowband.nFreqs = 8; end
if ~isfield(det.fhNarrowband, "scanAllBins"); det.fhNarrowband.scanAllBins = true; end
if ~isfield(det, "cyclostationary"); det.cyclostationary = struct(); end
if ~isfield(det.cyclostationary, "enable"); det.cyclostationary.enable = false; end
if ~isfield(det.cyclostationary, "sps"); det.cyclostationary.sps = 4; end

% 参数验证
pfaTarget = double(det.pfaTarget);
nObs = double(det.nObs);
nTrials = double(det.nTrials);
noiseUncertaintyDb = double(det.noiseUncertaintyDb);
extraDelaySamples = round(double(det.extraDelaySamples));
primaryLayer = local_normalize_layer_name(det.primaryLayer);
referenceLink = string(det.referenceLink);
fhNarrowbandEnable = logical(det.fhNarrowband.enable);
fhNFreqs = max(1, round(double(det.fhNarrowband.nFreqs)));
fhScanAllBins = logical(det.fhNarrowband.scanAllBins);
cycloEnable = logical(det.cyclostationary.enable);
cycloSps = max(1, round(double(det.cyclostationary.sps)));

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
if ~(noiseUncertaintyDb >= 0)
    error("noiseUncertaintyDb必须 >= 0。");
end
if ~(extraDelaySamples >= 0)
    error("extraDelaySamples必须 >= 0。");
end

txBurst = txBurst(:);
baseDelaySamples = max(0, round(double(maxDelaySymbols)));

% 层1/2：同一组基础统计量分别导出固定P_FA与最优xi*两种指标
statsBase = local_run_trials(txBurst, N0, ch, baseDelaySamples, nObs, nTrials, 0.0);
layerNp = local_fixed_pfa_metrics(statsBase.T0, statsBase.T1, pfaTarget);
layerOpt = local_optimal_metrics(statsBase.T0, statsBase.T1);

% 层3：在独立Warden链路上叠加噪声不确定性与更强的时延不确定性
statsUncertain = local_run_trials( ...
    txBurst, N0, ch, baseDelaySamples + extraDelaySamples, nObs, nTrials, noiseUncertaintyDb);
layerOptUncertain = local_optimal_metrics(statsUncertain.T0, statsUncertain.T1);

% 层4（可选）：跳频窄带Warden — 不知跳频序列，只能监听1/nFreqs带宽的单个信道
if fhNarrowbandEnable
    statsFhNarrow = local_run_trials_fh_narrow( ...
        txBurst, N0, ch, baseDelaySamples, nObs, nTrials, fhNFreqs, fhScanAllBins);
    layerFhNarrow = local_optimal_metrics(statsFhNarrow.T0, statsFhNarrow.T1);
else
    % 未启用时用全带能量层占位，xi相同（表示未评估）
    layerFhNarrow = layerOpt;
end

% 层5（可选）：循环平稳检测器 — 利用符号率处的循环自相关特征
if cycloEnable
    statsCyclo = local_run_trials_cyclo( ...
        txBurst, N0, ch, baseDelaySamples, nObs, nTrials, cycloSps);
    layerCyclo = local_optimal_metrics(statsCyclo.T0, statsCyclo.T1);
else
    layerCyclo = layerOpt;
end

layerNp = local_attach_layer_meta( ...
    layerNp, "energyNp", "fixed_pfa", statsBase.L, statsBase.delayMaxSamples, 0.0, referenceLink);
layerOpt = local_attach_layer_meta( ...
    layerOpt, "energyOpt", "xi_opt", statsBase.L, statsBase.delayMaxSamples, 0.0, referenceLink);
layerOptUncertain = local_attach_layer_meta( ...
    layerOptUncertain, "energyOptUncertain", "xi_opt_uncertain", ...
    statsUncertain.L, statsUncertain.delayMaxSamples, noiseUncertaintyDb, referenceLink);
layerFhNarrow = local_attach_layer_meta( ...
    layerFhNarrow, "energyFhNarrow", "xi_opt", ...
    statsBase.L, statsBase.delayMaxSamples, 0.0, referenceLink);
layerCyclo = local_attach_layer_meta( ...
    layerCyclo, "cyclostationaryOpt", "xi_opt", ...
    statsBase.L, statsBase.delayMaxSamples, 0.0, referenceLink);

m = struct();
m.primaryLayer = primaryLayer;
m.referenceLink = referenceLink;
m.pfaTarget = pfaTarget;
m.nObs = statsBase.L;
m.nTrials = nTrials;
m.layers = struct( ...
    "energyNp", layerNp, ...
    "energyOpt", layerOpt, ...
    "energyOptUncertain", layerOptUncertain, ...
    "energyFhNarrow", layerFhNarrow, ...
    "cyclostationaryOpt", layerCyclo);

% 兼容旧结果结构：顶层字段默认映射到第一层energyNp
m.threshold = layerNp.threshold;
m.pfaEst = layerNp.pfa;
m.pdEst = layerNp.pd;
m.pmdEst = layerNp.pmd;
m.xiEst = layerNp.xi;
m.peEst = layerNp.pe;

% 便于直接读取的文献口径字段
m.thresholdOpt = layerOpt.threshold;
m.pfaOpt = layerOpt.pfa;
m.pdOpt = layerOpt.pd;
m.pmdOpt = layerOpt.pmd;
m.xiOpt = layerOpt.xi;
m.peOpt = layerOpt.pe;

m.thresholdUncertain = layerOptUncertain.threshold;
m.pfaUncertain = layerOptUncertain.pfa;
m.pdUncertain = layerOptUncertain.pd;
m.pmdUncertain = layerOptUncertain.pmd;
m.xiUncertain = layerOptUncertain.xi;
m.peUncertain = layerOptUncertain.pe;
end

function stats = local_run_trials(txBurst, N0, ch, maxDelaySamples, nObs, nTrials, noiseUncertaintyDb)
L = min(round(nObs), numel(txBurst) + round(maxDelaySamples));
delayMaxSamples = max(0, round(maxDelaySamples));
T0 = zeros(nTrials, 1);
T1 = zeros(nTrials, 1);

for i = 1:nTrials
    delay = randi([0, delayMaxSamples], 1, 1);
    txWin = zeros(L, 1);
    if delay < L
        nSig = min(numel(txBurst), L - delay);
        if nSig > 0
            txWin(delay+1:delay+nSig) = txBurst(1:nSig);
        end
    end

    % 同一检测试验内，H0/H1共享同一个未知噪声底，更贴近文献常用假设。
    n0Trial = local_sample_n0(N0, noiseUncertaintyDb);

    r0 = channel_bg_impulsive(zeros(L, 1), n0Trial, ch);
    r1 = channel_bg_impulsive(txWin, n0Trial, ch);

    T0(i) = mean(abs(r0).^2);
    T1(i) = mean(abs(r1).^2);
end

stats = struct();
stats.T0 = T0;
stats.T1 = T1;
stats.L = L;
stats.delayMaxSamples = delayMaxSamples;
end

function n0Draw = local_sample_n0(N0, noiseUncertaintyDb)
if noiseUncertaintyDb <= 0
    n0Draw = N0;
    return;
end
deltaDb = (2 * rand() - 1) * noiseUncertaintyDb;
n0Draw = N0 * 10.^(deltaDb / 10);
end

function metrics = local_fixed_pfa_metrics(T0, T1, pfaTarget)
T0s = sort(T0);
idx = max(1, min(numel(T0s), ceil((1 - pfaTarget) * numel(T0s))));
threshold = T0s(idx);
metrics = local_metrics_at_threshold(T0, T1, threshold);
metrics.pfaTarget = pfaTarget;
metrics.thresholdScanCount = numel(T0s);
end

function metrics = local_optimal_metrics(T0, T1)
thresholds = local_candidate_thresholds(T0, T1);
xiVals = zeros(numel(thresholds), 1);
for i = 1:numel(thresholds)
    cur = local_metrics_at_threshold(T0, T1, thresholds(i));
    xiVals(i) = cur.xi;
end

[~, bestIdx] = min(xiVals);
metrics = local_metrics_at_threshold(T0, T1, thresholds(bestIdx));
metrics.pfaTarget = NaN;
metrics.thresholdScanCount = numel(thresholds);
end

function thresholds = local_candidate_thresholds(T0, T1)
values = sort(unique([T0(:); T1(:)]));
if isempty(values)
    thresholds = 0;
    return;
end
thresholds = [-inf; values; inf];
end

function metrics = local_metrics_at_threshold(T0, T1, threshold)
pfa = mean(T0 > threshold);
pmd = mean(T1 <= threshold);
pd = 1 - pmd;
xi = pfa + pmd;
metrics = struct();
metrics.threshold = threshold;
metrics.pfa = pfa;
metrics.pd = pd;
metrics.pmd = pmd;
metrics.xi = xi;
metrics.pe = 0.5 * xi;
end

function layer = local_attach_layer_meta(metrics, layerName, criterion, nObs, delayMaxSamples, noiseUncertaintyDb, referenceLink)
layer = metrics;
layer.name = string(layerName);
layer.criterion = string(criterion);
layer.nObs = nObs;
layer.delayMaxSamples = delayMaxSamples;
layer.noiseUncertaintyDb = noiseUncertaintyDb;
layer.referenceLink = string(referenceLink);
end

function name = local_normalize_layer_name(nameIn)
name = string(nameIn);
switch lower(name)
    case lower("energyNp")
        name = "energyNp";
    case lower("energyOpt")
        name = "energyOpt";
    case lower("energyOptUncertain")
        name = "energyOptUncertain";
    case lower("energyFhNarrow")
        name = "energyFhNarrow";
    case lower("cyclostationaryOpt")
        name = "cyclostationaryOpt";
    otherwise
        error("Unknown warden primaryLayer: %s", string(nameIn));
end
end

function stats = local_run_trials_fh_narrow(txBurst, N0, ch, maxDelaySamples, nObs, nTrials, nFreqs, scanAllBins)
% 模拟不知道跳频序列的Warden：只能监听带宽为1/nFreqs的单个子带。
% scanAllBins=true时扫描全部nFreqs个频点并取最大能量（最强非相干Warden）；
% scanAllBins=false时随机选一个频点（平均意义下的实际Warden）。
L = min(round(nObs), numel(txBurst) + round(maxDelaySamples));
delayMaxSamples = max(0, round(maxDelaySamples));
T0 = zeros(nTrials, 1);
T1 = zeros(nTrials, 1);

% 构建nFreqs个等间距子带的带通滤波器（归一化频率，FIR，汉明窗）
% 每个子带带宽 bw = 1/nFreqs（归一化到采样率）
bw = 1 / nFreqs;
binCenters = linspace(-0.5 + bw/2, 0.5 - bw/2, nFreqs);
nTaps = 63; % 奇数阶FIR，群延迟=(nTaps-1)/2
filters = cell(nFreqs, 1);
for k = 1:nFreqs
    fc = binCenters(k);
    % 复指数调制：将低通滤波器搬移到中心频率fc
    lpf = fir1(nTaps - 1, bw, 'low', hamming(nTaps));
    n_idx = (0:nTaps-1).';
    filters{k} = lpf(:) .* exp(1j * 2*pi*fc * n_idx);
end

for i = 1:nTrials
    delay = randi([0, delayMaxSamples], 1, 1);
    txWin = zeros(L, 1);
    if delay < L
        nSig = min(numel(txBurst), L - delay);
        if nSig > 0
            txWin(delay+1:delay+nSig) = txBurst(1:nSig);
        end
    end

    r0 = channel_bg_impulsive(zeros(L, 1), N0, ch);
    r1 = channel_bg_impulsive(txWin, N0, ch);

    if scanAllBins
        % 扫描所有频点，取能量最大的子带（最优非相干Warden）
        e0 = zeros(nFreqs, 1);
        e1 = zeros(nFreqs, 1);
        for k = 1:nFreqs
            y0 = filter(filters{k}, 1, r0);
            y1 = filter(filters{k}, 1, r1);
            e0(k) = mean(abs(y0).^2);
            e1(k) = mean(abs(y1).^2);
        end
        T0(i) = max(e0);
        T1(i) = max(e1);
    else
        % 随机选一个频点
        k = randi(nFreqs);
        y0 = filter(filters{k}, 1, r0);
        y1 = filter(filters{k}, 1, r1);
        T0(i) = mean(abs(y0).^2);
        T1(i) = mean(abs(y1).^2);
    end
end

stats = struct();
stats.T0 = T0;
stats.T1 = T1;
stats.L = L;
stats.delayMaxSamples = delayMaxSamples;
end

function stats = local_run_trials_cyclo(txBurst, N0, ch, maxDelaySamples, nObs, nTrials, sps)
% 循环平稳检测器：利用信号在循环频率 alpha=1/sps 处的循环自相关（CAF）。
% 调制信号（BPSK/QPSK+RRC成型）在此循环频率处存在显著的循环自相关分量，
% 而纯AWGN在任意非零循环频率处的CAF趋于零。
% 检验统计量：T = |R_xx(tau=0, alpha=1/sps)|，tau取0简化计算。
L = min(round(nObs), numel(txBurst) + round(maxDelaySamples));
delayMaxSamples = max(0, round(maxDelaySamples));
T0 = zeros(nTrials, 1);
T1 = zeros(nTrials, 1);
alpha = 1 / sps; % 循环频率（归一化，cycles/sample）

for i = 1:nTrials
    delay = randi([0, delayMaxSamples], 1, 1);
    txWin = zeros(L, 1);
    if delay < L
        nSig = min(numel(txBurst), L - delay);
        if nSig > 0
            txWin(delay+1:delay+nSig) = txBurst(1:nSig);
        end
    end

    r0 = channel_bg_impulsive(zeros(L, 1), N0, ch);
    r1 = channel_bg_impulsive(txWin, N0, ch);

    T0(i) = local_caf_magnitude(r0, alpha);
    T1(i) = local_caf_magnitude(r1, alpha);
end

stats = struct();
stats.T0 = T0;
stats.T1 = T1;
stats.L = L;
stats.delayMaxSamples = delayMaxSamples;
end

function val = local_caf_magnitude(x, alpha)
% 计算循环自相关函数在 tau=0, 给定alpha处的幅值。
% CAF(alpha, tau=0) = (1/N) * sum_n x(n) * conj(x(n)) * exp(-j*2*pi*alpha*n)
%                   = (1/N) * sum_n |x(n)|^2 * exp(-j*2*pi*alpha*n)
% 即 |x|^2 序列在频率alpha处的DFT系数（归一化）。
N = numel(x);
n = (0:N-1).';
pow_seq = abs(x).^2;
val = abs(sum(pow_seq .* exp(-1j * 2*pi*alpha*n)) / N);
end
