function [y, impMask, chState] = channel_bg_impulsive(x, N0, ch)
%CHANNEL_BG_IMPULSIVE  复基带信道：AWGN + BG脉冲（可选多径/多普勒/路径损耗）。
%
% 输入:
%   x  - 输入符号（列向量）
%   N0 - 背景噪声功率谱密度
%   ch - 信道参数结构体
%        .impulseProb      - 脉冲噪声出现概率
%        .impulseToBgRatio - 脉冲噪声功率与背景噪声功率比
%        .fading.enable/.type（可选）
%        .multipath.enable/.pathDelays/.pathGainsDb（可选）
%        .doppler.enable/.mode/.maxNorm/.commonNorm/.pathNorm（可选）
%        .pathLoss.enable/.model（可选）
%        .singleTone.enable/.toBgRatio/.normFreq（可选）
%        .narrowband.enable/.toBgRatio/.centerFreq/.bandwidth（可选）
%        .syncImpairment.enable/.timingOffset/.cfoNorm/.phaseOffsetRad（可选）
%
% 输出:
%   y       - 加噪后符号
%   impMask - 脉冲样本掩码（logical）
%   chState - 信道状态（可选）

x = x(:);
n = (0:numel(x)-1).';

% 默认：无衰落
h = ones(size(x));
fadingType = "none";
dopplerEnable = false;
dopplerMode = "none";
dopplerNormUsed = [];
dopplerPhaseUsed = [];
pathLossEnable = false;
pathLossDb = 0;
pathLossLinear = 1;

% 可选衰落：块瑞利/逐符号瑞利
if isfield(ch, "fading") && isfield(ch.fading, "enable") && ch.fading.enable
    if isfield(ch.fading, "type")
        fadingType = lower(string(ch.fading.type));
    else
        fadingType = "rayleigh_block";
    end
    switch fadingType
        case "rayleigh_block"
            h0 = (randn(1, 1) + 1j*randn(1, 1)) / sqrt(2);
            h = h0 * ones(size(x));
        case "rayleigh_per_symbol"
            h = (randn(size(x)) + 1j*randn(size(x))) / sqrt(2);
        otherwise
            error("未知的衰落类型: %s", string(fadingType));
    end
end
xCh = h .* x;

% 可选：多径抽头（整数时延）
mpEnable = false;
mpTaps = 1;
if isfield(ch, "multipath") && isfield(ch.multipath, "enable") && ch.multipath.enable
    mpEnable = true;
    if ~isfield(ch.multipath, "pathDelays") || ~isfield(ch.multipath, "pathGainsDb")
        error("multipath启用时需提供pathDelays与pathGainsDb。");
    end
    dly = double(ch.multipath.pathDelays(:));
    gDb = double(ch.multipath.pathGainsDb(:));
    if numel(dly) ~= numel(gDb)
        error("pathDelays与pathGainsDb长度必须一致。");
    end
    if any(dly < 0) || any(abs(dly - round(dly)) > 1e-12)
        error("pathDelays必须是非负整数。");
    end
    dly = round(dly);

    amp = 10.^(gDb/20);
    phase = zeros(size(amp));
    if isfield(ch.multipath, "pathPhasesRad") && ~isempty(ch.multipath.pathPhasesRad)
        phase = double(ch.multipath.pathPhasesRad(:));
        if numel(phase) ~= numel(amp)
            error("pathPhasesRad长度需与pathDelays一致。");
        end
    else
        phase = 2*pi*rand(size(amp));
    end

    if ~isfield(ch.multipath, "fadingType")
        mpFadingType = "static";
    else
        mpFadingType = lower(string(ch.multipath.fadingType));
    end
    switch mpFadingType
        case "static"
            cplxAmp = amp .* exp(1j*phase);
        case "rayleigh_block"
            cplxAmp = amp .* exp(1j*phase) .* ((randn(size(amp)) + 1j*randn(size(amp))) / sqrt(2));
        otherwise
            error("未知的multipath.fadingType: %s", string(mpFadingType));
    end

    mpTaps = complex(zeros(max(dly)+1, 1));
    for k = 1:numel(dly)
        mpTaps(dly(k)+1) = mpTaps(dly(k)+1) + cplxAmp(k);
    end
    if isfield(ch, "doppler") && isfield(ch.doppler, "enable") && ch.doppler.enable
        dopplerEnable = true;
        if isfield(ch.doppler, "mode")
            dopplerMode = lower(string(ch.doppler.mode));
        else
            dopplerMode = "per_path_random";
        end
        [dopplerNormUsed, dopplerPhaseUsed] = resolve_doppler_profile(ch.doppler, numel(dly));
        xMp = complex(zeros(size(xCh)));
        for k = 1:numel(dly)
            xDelayed = integer_delay(xCh, dly(k));
            osc = exp(1j * (2*pi*dopplerNormUsed(k)*n + dopplerPhaseUsed(k)));
            xMp = xMp + cplxAmp(k) .* xDelayed .* osc;
        end
        xCh = xMp;
    else
        xCh = filter(mpTaps, 1, xCh);
    end
end

% 可选：多普勒（无多径时退化为平坦频移）
if ~mpEnable && isfield(ch, "doppler") && isfield(ch.doppler, "enable") && ch.doppler.enable
    dopplerEnable = true;
    if isfield(ch.doppler, "mode")
        dopplerMode = lower(string(ch.doppler.mode));
    else
        dopplerMode = "common";
    end
    [dopplerNormUsed, dopplerPhaseUsed] = resolve_doppler_profile(ch.doppler, 1);
    xCh = xCh .* exp(1j * (2*pi*dopplerNormUsed(1)*n + dopplerPhaseUsed(1)));
end

% 可选：大尺度路径损耗（对信号功率衰减，不改变噪声注入方式）
if isfield(ch, "pathLoss") && isfield(ch.pathLoss, "enable") && ch.pathLoss.enable
    pathLossEnable = true;
    [pathLossDb, pathLossLinear] = resolve_path_loss(ch.pathLoss);
    xCh = pathLossLinear * xCh;
end

% 可选：同步失配（分数定时偏移 + 载波频偏/相偏）
syncImpEnable = false;
timingOffset = 0;
cfoNorm = 0;
phaseOffsetRad = 0;
if isfield(ch, "syncImpairment") && isfield(ch.syncImpairment, "enable") && ch.syncImpairment.enable
    syncImpEnable = true;
    if isfield(ch.syncImpairment, "timingOffset"); timingOffset = double(ch.syncImpairment.timingOffset); end
    if isfield(ch.syncImpairment, "cfoNorm"); cfoNorm = double(ch.syncImpairment.cfoNorm); end
    if isfield(ch.syncImpairment, "phaseOffsetRad"); phaseOffsetRad = double(ch.syncImpairment.phaseOffsetRad); end

    if abs(timingOffset) > 1e-12
        xCh = fractional_delay(xCh, timingOffset);
    end
    if abs(cfoNorm) > 0 || abs(phaseOffsetRad) > 0
        xCh = xCh .* exp(1j * (2*pi*cfoNorm*n + phaseOffsetRad));
    end
end

% 背景高斯噪声 + BG脉冲噪声
nBg = sqrt(N0/2) * (randn(size(x)) + 1j*randn(size(x)));

impMask = rand(size(x)) < ch.impulseProb;
N0imp = ch.impulseToBgRatio * N0;
nImp = sqrt(N0imp/2) * (randn(size(x)) + 1j*randn(size(x)));

jammer = complex(zeros(size(x)));

% 可选单音干扰
singleToneEnable = false;
if isfield(ch, "singleTone") && isfield(ch.singleTone, "enable") && ch.singleTone.enable
    singleToneEnable = true;
    toneRatio = 10;
    toneFreq = 0.08;
    randomPhase = true;
    if isfield(ch.singleTone, "toBgRatio"); toneRatio = ch.singleTone.toBgRatio; end
    if isfield(ch.singleTone, "normFreq"); toneFreq = ch.singleTone.normFreq; end
    if isfield(ch.singleTone, "randomPhase"); randomPhase = logical(ch.singleTone.randomPhase); end
    if abs(toneFreq) >= 0.5
        error("singleTone.normFreq必须在(-0.5, 0.5)范围。");
    end
    phi0 = 0;
    if randomPhase
        phi0 = 2*pi*rand();
    end
    toneAmp = sqrt(max(toneRatio, 0) * N0);
    jammer = jammer + toneAmp * exp(1j * (2*pi*toneFreq*n + phi0));
end

% 可选窄带噪声干扰（频域成形）
narrowbandEnable = false;
if isfield(ch, "narrowband") && isfield(ch.narrowband, "enable") && ch.narrowband.enable
    narrowbandEnable = true;
    nbRatio = 8;
    nbFc = 0.12;
    nbBw = 0.08;
    if isfield(ch.narrowband, "toBgRatio"); nbRatio = ch.narrowband.toBgRatio; end
    if isfield(ch.narrowband, "centerFreq"); nbFc = ch.narrowband.centerFreq; end
    if isfield(ch.narrowband, "bandwidth"); nbBw = ch.narrowband.bandwidth; end
    if abs(nbFc) >= 0.5
        error("narrowband.centerFreq必须在(-0.5, 0.5)范围。");
    end
    nbBw = max(min(nbBw, 1.0), 1e-3);

    wn = (randn(size(x)) + 1j*randn(size(x))) / sqrt(2);
    W = fftshift(fft(wn));
    f = ((0:numel(x)-1).' / numel(x)) - 0.5;
    passMask = abs(f) <= (nbBw / 2);
    W(~passMask) = 0;
    nb = ifft(ifftshift(W));
    nb = nb .* exp(1j * 2*pi*nbFc*n);

    targetPow = max(nbRatio, 0) * N0;
    nowPow = mean(abs(nb).^2);
    if nowPow > 0
        nb = nb * sqrt(targetPow / nowPow);
    end
    jammer = jammer + nb;
end

y = xCh + nBg + impMask .* nImp + jammer;

if nargout >= 3
    chState = struct();
    chState.h = h;
    chState.fadingType = char(fadingType);
    chState.singleToneEnable = singleToneEnable;
    chState.narrowbandEnable = narrowbandEnable;
    chState.multipathEnable = mpEnable;
    chState.multipathTaps = mpTaps;
    chState.dopplerEnable = dopplerEnable;
    chState.dopplerMode = char(dopplerMode);
    chState.dopplerNorm = dopplerNormUsed;
    chState.dopplerPhaseRad = dopplerPhaseUsed;
    chState.pathLossEnable = pathLossEnable;
    chState.pathLossDb = pathLossDb;
    chState.pathLossLinear = pathLossLinear;
    chState.syncImpairmentEnable = syncImpEnable;
    chState.timingOffset = timingOffset;
    chState.cfoNorm = cfoNorm;
    chState.phaseOffsetRad = phaseOffsetRad;
end
end

function y = fractional_delay(x, d)
% y[n] = x[n-d]，d>0表示向右延时（抽样点更晚）。
idx = (1:numel(x)).';
query = idx - d;
y = interp1(idx, x, query, "linear", 0);
end

function y = integer_delay(x, d)
% y[n] = x[n-d]，d为非负整数；超出范围补零。
x = x(:);
d = round(double(d));
if d <= 0
    y = x;
    return;
end
if d >= numel(x)
    y = complex(zeros(size(x)));
    return;
end
y = [complex(zeros(d, 1)); x(1:end-d)];
end

function [fdNorm, phi0] = resolve_doppler_profile(dopplerCfg, nPaths)
% 根据配置生成每径多普勒（归一化频率，cycles/sample）与初相。
nPaths = max(1, round(double(nPaths)));
mode = "per_path_random";
if isfield(dopplerCfg, "mode")
    mode = lower(string(dopplerCfg.mode));
end

maxNorm = 0;
if isfield(dopplerCfg, "maxNorm")
    maxNorm = abs(double(dopplerCfg.maxNorm));
end
commonNorm = 0;
if isfield(dopplerCfg, "commonNorm")
    commonNorm = double(dopplerCfg.commonNorm);
end

if isfield(dopplerCfg, "pathNorm") && ~isempty(dopplerCfg.pathNorm)
    fdNorm = double(dopplerCfg.pathNorm(:));
    if numel(fdNorm) == 1
        fdNorm = repmat(fdNorm, nPaths, 1);
    elseif numel(fdNorm) ~= nPaths
        error("doppler.pathNorm长度需为1或与径数一致。");
    end
else
    switch mode
        case "common"
            fdNorm = commonNorm * ones(nPaths, 1);
        case "per_path_fixed"
            if nPaths == 1
                fdNorm = commonNorm;
            else
                fdNorm = linspace(-maxNorm, maxNorm, nPaths).';
            end
        case "per_path_random"
            fdNorm = (2*rand(nPaths, 1) - 1) * maxNorm;
        otherwise
            error("未知的doppler.mode: %s", string(mode));
    end
end

if isfield(dopplerCfg, "initialPhaseRad") && ~isempty(dopplerCfg.initialPhaseRad)
    phi0 = double(dopplerCfg.initialPhaseRad(:));
    if numel(phi0) == 1
        phi0 = repmat(phi0, nPaths, 1);
    elseif numel(phi0) ~= nPaths
        error("doppler.initialPhaseRad长度需为1或与径数一致。");
    end
else
    phi0 = 2*pi*rand(nPaths, 1);
end
end

function [lossDb, lossLinear] = resolve_path_loss(pathLossCfg)
% 大尺度路径损耗：fixed_db 或 log_distance 模型。
model = "log_distance";
if isfield(pathLossCfg, "model")
    model = lower(string(pathLossCfg.model));
end

switch model
    case "fixed_db"
        lossDb = 0;
        if isfield(pathLossCfg, "fixedLossDb")
            lossDb = double(pathLossCfg.fixedLossDb);
        end
    case "log_distance"
        d0 = 1.0;
        d = 1.0;
        nExp = 2.0;
        pl0 = 0.0;
        shadowStd = 0.0;
        if isfield(pathLossCfg, "referenceDistance"); d0 = double(pathLossCfg.referenceDistance); end
        if isfield(pathLossCfg, "distance"); d = double(pathLossCfg.distance); end
        if isfield(pathLossCfg, "pathLossExp"); nExp = double(pathLossCfg.pathLossExp); end
        if isfield(pathLossCfg, "referenceLossDb"); pl0 = double(pathLossCfg.referenceLossDb); end
        if isfield(pathLossCfg, "shadowStdDb"); shadowStd = abs(double(pathLossCfg.shadowStdDb)); end

        d0 = max(d0, eps);
        d = max(d, d0);
        shadowDb = shadowStd * randn(1, 1);
        lossDb = pl0 + 10*nExp*log10(d / d0) + shadowDb;
    otherwise
        error("未知的pathLoss.model: %s", string(model));
end

lossLinear = 10.^(-lossDb/20);
end
