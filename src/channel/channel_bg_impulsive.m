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
%        .sweep.enable/.toBgRatio/.startFreq/.stopFreq/.periodSamples（可选）
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

% 可选扫频干扰（线性chirp，可重复）
sweepEnable = false;
if isfield(ch, "sweep") && isfield(ch.sweep, "enable") && ch.sweep.enable
    sweepEnable = true;
    swRatio = 8;
    swF0 = -0.2;
    swF1 = 0.2;
    swPeriod = numel(x);
    swRandomPhase = true;

    if isfield(ch.sweep, "toBgRatio"); swRatio = ch.sweep.toBgRatio; end
    if isfield(ch.sweep, "startFreq"); swF0 = ch.sweep.startFreq; end
    if isfield(ch.sweep, "stopFreq"); swF1 = ch.sweep.stopFreq; end
    if isfield(ch.sweep, "periodSymbols"); swPeriod = ch.sweep.periodSymbols; end
    if isfield(ch.sweep, "periodSamples"); swPeriod = ch.sweep.periodSamples; end
    if isfield(ch.sweep, "randomPhase"); swRandomPhase = logical(ch.sweep.randomPhase); end

    swF0 = double(swF0);
    swF1 = double(swF1);
    swPeriod = max(2, round(double(swPeriod)));
    if abs(swF0) >= 0.5 || abs(swF1) >= 0.5
        error("sweep.startFreq和sweep.stopFreq必须在(-0.5, 0.5)范围。");
    end

    phi0 = 0;
    if swRandomPhase
        phi0 = 2*pi*rand();
    end

    k = mod(n, swPeriod);
    frac = k / max(swPeriod - 1, 1);
    instFreq = swF0 + (swF1 - swF0) .* frac;
    sweepPhase = phi0 + 2*pi*cumsum(instFreq);
    sweepJam = exp(1j * sweepPhase);

    targetPow = max(swRatio, 0) * N0;
    nowPow = mean(abs(sweepJam).^2);
    if nowPow > 0
        sweepJam = sweepJam * sqrt(targetPow / nowPow);
    end
    jammer = jammer + sweepJam;
end

y = xCh + nBg + impMask .* nImp + jammer;

if nargout >= 3
    chState = struct();
    chState.h = h;
    chState.fadingType = char(fadingType);
    chState.singleToneEnable = singleToneEnable;
    chState.narrowbandEnable = narrowbandEnable;
    chState.sweepEnable = sweepEnable;
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
