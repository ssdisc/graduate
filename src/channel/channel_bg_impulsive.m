function [y, impMask, chState] = channel_bg_impulsive(x, N0, ch)
%CHANNEL_BG_IMPULSIVE  复基带信道：AWGN + BG脉冲（可选静态多径/干扰/同步失配）。
%
% 输入:
%   x  - 输入符号（列向量）
%   N0 - 背景噪声功率谱密度
%   ch - 采样级信道参数结构体（通常由adapt_channel_for_sps转换得到）
%        .impulseProb      - 脉冲噪声出现概率
%        .impulseToBgRatio - 脉冲噪声功率与背景噪声功率比
%        .multipath.enable/.pathDelays/.pathGainsDb（可选，pathDelays单位: sample）
%        .singleTone.enable/.powerMode/.power/.toBgRatio/.normFreq（可选，normFreq单位: cycles/sample）
%        .narrowband.enable/.powerMode/.power/.toBgRatio/.centerFreq/.bandwidth（可选）
%        .sweep.enable/.powerMode/.power/.toBgRatio/.startFreq/.stopFreq/.periodSamples（可选）
%        .syncImpairment.enable/.timingOffset/.phaseOffsetRad（可选，timingOffset单位: sample）
%
% 输出:
%   y       - 加噪后符号
%   impMask - 脉冲样本掩码（logical）
%   chState - 信道状态（可选）

x = x(:);
n = (0:numel(x)-1).';
xCh = x;

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
    if isfield(ch.multipath, "pathPhasesRad") && ~isempty(ch.multipath.pathPhasesRad)
        phase = double(ch.multipath.pathPhasesRad(:));
        if numel(phase) ~= numel(amp)
            error("pathPhasesRad长度需与pathDelays一致。");
        end
    else
        phase = 2*pi*rand(size(amp));
    end

    useRayleigh = isfield(ch.multipath, "rayleigh") && ch.multipath.rayleigh;
    if useRayleigh
        % 瑞利衰落：各径复高斯系数，均方 = 线性功率增益
        cplxAmp = amp .* (randn(size(amp)) + 1j*randn(size(amp))) / sqrt(2);
    else
        cplxAmp = amp .* exp(1j*phase);
    end

    mpTaps = complex(zeros(max(dly)+1, 1));
    for k = 1:numel(dly)
        mpTaps(dly(k)+1) = mpTaps(dly(k)+1) + cplxAmp(k);
    end
    xCh = filter(mpTaps, 1, xCh);
end

% 可选：同步失配（分数定时偏移 + 初始相位偏移）
syncImpEnable = false;
timingOffset = 0;
phaseOffsetRad = 0;
if isfield(ch, "syncImpairment") && isfield(ch.syncImpairment, "enable") && ch.syncImpairment.enable
    syncImpEnable = true;
    if isfield(ch.syncImpairment, "timingOffset"); timingOffset = double(ch.syncImpairment.timingOffset); end
    if isfield(ch.syncImpairment, "phaseOffsetRad"); phaseOffsetRad = double(ch.syncImpairment.phaseOffsetRad); end

    if abs(timingOffset) > 1e-12
        xCh = fractional_delay(xCh, timingOffset);
    end
    if abs(phaseOffsetRad) > 0
        xCh = xCh .* exp(1j * phaseOffsetRad);
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
    toneFreq = 0.08;
    randomPhase = true;
    if isfield(ch.singleTone, "normFreq"); toneFreq = ch.singleTone.normFreq; end
    if isfield(ch.singleTone, "randomPhase"); randomPhase = logical(ch.singleTone.randomPhase); end
    if abs(toneFreq) >= 0.5
        error("singleTone.normFreq必须在(-0.5, 0.5)范围。");
    end
    phi0 = 0;
    if randomPhase
        phi0 = 2*pi*rand();
    end
    tonePow = local_interference_power(ch.singleTone, N0, 10 * N0);
    toneAmp = sqrt(tonePow);
    jammer = jammer + toneAmp * exp(1j * (2*pi*toneFreq*n + phi0));
end

% 可选窄带噪声干扰（频域成形）
narrowbandEnable = false;
if isfield(ch, "narrowband") && isfield(ch.narrowband, "enable") && ch.narrowband.enable
    narrowbandEnable = true;
    nbFc = 0.12;
    nbBw = 0.08;
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

    targetPow = local_interference_power(ch.narrowband, N0, 8 * N0);
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
    swF0 = -0.2;
    swF1 = 0.2;
    swPeriod = numel(x);
    swRandomPhase = true;

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

    targetPow = local_interference_power(ch.sweep, N0, 8 * N0);
    nowPow = mean(abs(sweepJam).^2);
    if nowPow > 0
        sweepJam = sweepJam * sqrt(targetPow / nowPow);
    end
    jammer = jammer + sweepJam;
end

y = xCh + nBg + impMask .* nImp + jammer;

if nargout >= 3
    chState = struct();
    chState.singleToneEnable = singleToneEnable;
    chState.narrowbandEnable = narrowbandEnable;
    chState.sweepEnable = sweepEnable;
    chState.multipathEnable = mpEnable;
    chState.multipathTaps = mpTaps;
    chState.syncImpairmentEnable = syncImpEnable;
    chState.timingOffset = timingOffset;
    chState.phaseOffsetRad = phaseOffsetRad;
end
end

function targetPow = local_interference_power(cfg, N0, legacyDefault)
targetPow = legacyDefault;

if isfield(cfg, "powerMode") && strlength(string(cfg.powerMode)) > 0
    switch lower(string(cfg.powerMode))
        case "absolute"
            if isfield(cfg, "power") && ~isempty(cfg.power)
                targetPow = max(double(cfg.power), 0);
                return;
            end
        case "relative_to_bg"
            if isfield(cfg, "toBgRatio") && ~isempty(cfg.toBgRatio)
                targetPow = max(double(cfg.toBgRatio), 0) * N0;
                return;
            end
        otherwise
            error("Unsupported interference powerMode: %s", string(cfg.powerMode));
    end
end

if isfield(cfg, "power") && ~isempty(cfg.power)
    targetPow = max(double(cfg.power), 0);
elseif isfield(cfg, "toBgRatio") && ~isempty(cfg.toBgRatio)
    targetPow = max(double(cfg.toBgRatio), 0) * N0;
end
end
