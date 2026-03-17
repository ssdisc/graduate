function [idx, rComp, info] = frame_sync(r, preambleSym, syncCfg)
%FRAME_SYNC  完整同步前端：帧捕获 + 分数定时估计 + CFO/相位补偿。

if nargin < 3
    syncCfg = struct();
end

if ~isfield(syncCfg, "fineSearchRadius"); syncCfg.fineSearchRadius = 0; end
if ~isfield(syncCfg, "compensateCarrier"); syncCfg.compensateCarrier = false; end
if ~isfield(syncCfg, "equalizeAmplitude"); syncCfg.equalizeAmplitude = true; end
if ~isfield(syncCfg, "enableFractionalTiming"); syncCfg.enableFractionalTiming = false; end
if ~isfield(syncCfg, "fractionalRange"); syncCfg.fractionalRange = 0.5; end
if ~isfield(syncCfg, "fractionalStep"); syncCfg.fractionalStep = 0.05; end
if ~isfield(syncCfg, "estimateCfo"); syncCfg.estimateCfo = false; end
if ~isfield(syncCfg, "minCorrPeakToMedian"); syncCfg.minCorrPeakToMedian = 0; end
if ~isfield(syncCfg, "minCorrPeakToSecond"); syncCfg.minCorrPeakToSecond = 0; end
if ~isfield(syncCfg, "corrExclusionRadius"); syncCfg.corrExclusionRadius = []; end
if ~isfield(syncCfg, "minSearchIndex"); syncCfg.minSearchIndex = 1; end
if ~isfield(syncCfg, "maxSearchIndex"); syncCfg.maxSearchIndex = inf; end

r = r(:);
p = preambleSym(:);
rComp = r;
idxAxis = (1:numel(r)).';
dp = p(2:end) .* conj(p(1:end-1)); % 差分前导，用于CFO鲁棒捕获

info = struct("coarseIdx", [], "fineIdx", [], "fineFrac", 0, "corrPeak", NaN, ...
    "corrPeakToMedian", NaN, "corrPeakToSecond", NaN, "syncAccepted", false, ...
    "cfoRadPerSample", 0, ...
    "chanGainEstimate", complex(NaN, NaN), "phaseEstimateRad", NaN, ...
    "amplitudeEstimate", NaN, "compensated", false);

if numel(r) < numel(p)
    idx = [];
    return;
end

% 粗同步优先采用差分相关（对恒定CFO更鲁棒）
if numel(p) >= 2
    q = r(2:end) .* conj(r(1:end-1));
    c = abs(conv(q, flipud(conj(dp)), 'valid'));
else
    c = abs(conv(r, flipud(conj(p)), 'valid'));
end
searchMin = max(1, floor(double(syncCfg.minSearchIndex)));
searchMax = min(numel(c), floor(double(syncCfg.maxSearchIndex)));
if searchMin > searchMax
    idx = [];
    return;
end
cWin = c(searchMin:searchMax);
[peak, kRel] = max(cWin);
k = searchMin + kRel - 1;
info.coarseIdx = k;

% 在粗同步附近做整数符号级细搜索
searchRadius = max(0, floor(double(syncCfg.fineSearchRadius)));
if searchRadius > 0
    kMin = max(1, k - searchRadius);
    kMax = min(numel(c), k + searchRadius);
    bestVal = -inf;
    bestK = k;
    for kc = kMin:kMax
        seg = r(kc:kc+numel(p)-1);
        if numel(p) >= 2
            qSeg = seg(2:end) .* conj(seg(1:end-1));
            val = abs(sum(qSeg .* conj(dp)));
        else
            val = abs(sum(seg .* conj(p)));
        end
        if val > bestVal
            bestVal = val;
            bestK = kc;
        end
    end
    k = bestK;
    peak = bestVal;
end

% 分数符号定时估计（在整数捕获点附近做亚符号搜索）
fracBest = 0;
if logical(syncCfg.enableFractionalTiming)
    fracRange = abs(double(syncCfg.fractionalRange));
    fracStep = abs(double(syncCfg.fractionalStep));
    if fracStep > 0 && fracRange > 0
        fracGrid = -fracRange:fracStep:fracRange;
        if isempty(fracGrid)
            fracGrid = 0;
        end
        bestFracVal = -inf;
        bestFrac = 0;
        for t = fracGrid
            tNow = k + (0:numel(p)-1).' + t;
            seg = interp1(idxAxis, r, tNow, "linear", 0);
            if logical(syncCfg.estimateCfo) || logical(syncCfg.compensateCarrier)
                [wTmp, phiTmp] = estimate_cfo_phase(seg, p, tNow);
                segUse = seg .* exp(-1j * (wTmp * tNow + phiTmp));
                val = abs(sum(segUse .* conj(p)));
            else
                if numel(p) >= 2
                    qSeg = seg(2:end) .* conj(seg(1:end-1));
                    val = abs(sum(qSeg .* conj(dp)));
                else
                    val = abs(sum(seg .* conj(p)));
                end
            end
            if val > bestFracVal
                bestFracVal = val;
                bestFrac = t;
            end
        end
        fracBest = bestFrac;
        peak = bestFracVal;
    end
end

idx = k + fracBest;
info.fineIdx = k;
info.fineFrac = fracBest;
info.corrPeak = peak;

[peakToMedian, peakToSecond] = local_sync_confidence_metrics(cWin, k, searchMin, peak, local_corr_exclusion_radius(syncCfg));
info.corrPeakToMedian = peakToMedian;
info.corrPeakToSecond = peakToSecond;
if local_sync_confidence_failed(syncCfg, peakToMedian, peakToSecond)
    idx = [];
    return;
end
info.syncAccepted = true;

% 用前导估计载波偏移与复增益并进行补偿
if logical(syncCfg.compensateCarrier)
    preTimes = idx + (0:numel(p)-1).';
    pre = interp1(idxAxis, r, preTimes, "linear", 0);
    denom = sum(abs(p).^2);
    cfoRad = 0;
    if logical(syncCfg.estimateCfo)
        [cfoRad, phiHat] = estimate_cfo_phase(pre, p, preTimes);
        nAll = idxAxis;
        rComp = r .* exp(-1j * (cfoRad * nAll + phiHat));
    else
        rComp = r;
    end
    preComp = interp1(idxAxis, rComp, preTimes, "linear", 0);
    if denom > 0
        hHat = sum(preComp .* conj(p)) / denom;
    else
        hHat = 1;
    end
    if abs(hHat) > 1e-12
        if logical(syncCfg.equalizeAmplitude)
            compGain = hHat;
        else
            compGain = exp(1j * angle(hHat));
        end
        rComp = rComp ./ compGain;
        info.compensated = true;
    end
    info.cfoRadPerSample = cfoRad;
    info.chanGainEstimate = hHat;
    info.phaseEstimateRad = angle(hHat);
    info.amplitudeEstimate = abs(hHat);
end
end

function [wHat, phiHat] = estimate_cfo_phase(seg, pre, nAbs)
% 基于已知前导做相位线性拟合：phase(n)=w*n+phi。
z = seg(:) .* conj(pre(:));
z(abs(z) < 1e-12) = 1e-12;
phaseVec = unwrap(angle(z));
coef = polyfit(nAbs(:), phaseVec, 1);
wHat = coef(1);
phiHat = coef(2);
end

function [peakToMedian, peakToSecond] = local_sync_confidence_metrics(cWin, kGlobal, searchMin, peak, exclusionRadius)
if isempty(cWin)
    peakToMedian = 0;
    peakToSecond = 0;
    return;
end

floorNow = median(cWin);
peakToMedian = peak / max(floorNow, 1e-12);

kLocal = round(double(kGlobal)) - round(double(searchMin)) + 1;
kLocal = min(max(kLocal, 1), numel(cWin));
mask = true(size(cWin));
lo = max(1, kLocal - exclusionRadius);
hi = min(numel(cWin), kLocal + exclusionRadius);
mask(lo:hi) = false;
if any(mask)
    secondPeak = max(cWin(mask));
else
    secondPeak = floorNow;
end
peakToSecond = peak / max(secondPeak, 1e-12);
end

function tf = local_sync_confidence_failed(syncCfg, peakToMedian, peakToSecond)
tf = false;
if isfield(syncCfg, "minCorrPeakToMedian") && double(syncCfg.minCorrPeakToMedian) > 0
    tf = tf || (peakToMedian < double(syncCfg.minCorrPeakToMedian));
end
if isfield(syncCfg, "minCorrPeakToSecond") && double(syncCfg.minCorrPeakToSecond) > 0
    tf = tf || (peakToSecond < double(syncCfg.minCorrPeakToSecond));
end
end

function radius = local_corr_exclusion_radius(syncCfg)
radius = 4;
if isfield(syncCfg, "corrExclusionRadius") && ~isempty(syncCfg.corrExclusionRadius)
    radius = max(0, round(double(syncCfg.corrExclusionRadius)));
end
end

