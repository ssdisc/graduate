function [featureMatrix, info] = ml_extract_fh_erasure_features(rSym, hopInfo, erasureCfg, modCfg)
%ML_EXTRACT_FH_ERASURE_FEATURES  Extract per-hop features for FH soft erasure.

arguments
    rSym (:,1)
    hopInfo (1,1) struct
    erasureCfg (1,1) struct
    modCfg (1,1) struct
end

if ~(isfield(hopInfo, "enable") && hopInfo.enable)
    error("ml_extract_fh_erasure_features requires hopInfo.enable=true.");
end
if ~(isfield(hopInfo, "hopLen") && double(hopInfo.hopLen) > 0)
    error("ml_extract_fh_erasure_features requires slow-FH hopInfo.hopLen.");
end
if ~(isfield(hopInfo, "freqIdx") && ~isempty(hopInfo.freqIdx))
    error("ml_extract_fh_erasure_features requires hopInfo.freqIdx.");
end

rSym = rSym(:);
nSym = numel(rSym);
hopLen = round(double(hopInfo.hopLen));
nHops = ceil(double(nSym) / double(hopLen));
freqIdx = round(double(hopInfo.freqIdx(:)));
if numel(freqIdx) < nHops
    error("ml_extract_fh_erasure_features needs %d hop frequency indices, got %d.", nHops, numel(freqIdx));
end
freqIdx = freqIdx(1:nHops);
if any(~isfinite(freqIdx)) || any(freqIdx < 1)
    error("hopInfo.freqIdx must contain positive finite indices.");
end

nFreqs = max(freqIdx);
if isfield(hopInfo, "nFreqs") && ~isempty(hopInfo.nFreqs)
    nFreqs = max(nFreqs, round(double(hopInfo.nFreqs)));
end
if ~(isscalar(nFreqs) && isfinite(nFreqs) && nFreqs >= 1)
    error("hopInfo.nFreqs must be a positive finite scalar.");
end

edgeGuard = local_cfg_nonnegative(erasureCfg, "edgeGuardSymbols");
hopPower = nan(nHops, 1);
hopAbsMean = nan(nHops, 1);
hopAbsStd = nan(nHops, 1);
constellationMse = nan(nHops, 1);
iqPowerImbalance = nan(nHops, 1);
edgeHop = zeros(nHops, 1);

for hopIdx = 1:nHops
    idx = local_hop_indices(hopIdx, hopLen, nSym, edgeGuard);
    if isempty(idx)
        idx = local_hop_indices(hopIdx, hopLen, nSym, 0);
    end
    seg = rSym(idx);
    mag = abs(seg);
    hopPower(hopIdx) = mean(abs(seg).^2);
    hopAbsMean(hopIdx) = mean(mag);
    hopAbsStd(hopIdx) = std(mag, 0);
    constellationMse(hopIdx) = local_constellation_mse(seg, modCfg);
    iPow = mean(real(seg).^2);
    qPow = mean(imag(seg).^2);
    iqPowerImbalance(hopIdx) = abs(iPow - qPow) / max(iPow + qPow, eps);
    edgeHop(hopIdx) = double(hopIdx == 1 || hopIdx == nHops || numel(idx) < hopLen - 2 * edgeGuard);
end

validPower = isfinite(hopPower) & hopPower > 0;
if ~any(validPower)
    error("Unable to extract FH-erasure features from an all-zero/invalid block.");
end
powerRef = local_positive_ref(hopPower(validPower));
absMeanRef = local_positive_ref(hopAbsMean(isfinite(hopAbsMean) & hopAbsMean > 0));
absStdRef = local_positive_ref(hopAbsStd(isfinite(hopAbsStd) & hopAbsStd > 0));

freqMedianPower = nan(nFreqs, 1);
freqMeanPower = nan(nFreqs, 1);
freqMaxPower = nan(nFreqs, 1);
freqHotFraction = zeros(nFreqs, 1);
hotThreshold = local_cfg_positive(erasureCfg, "hopPowerRatioThreshold");
for freqNow = 1:nFreqs
    use = validPower & freqIdx == freqNow;
    if any(use)
        pNow = hopPower(use);
        freqMedianPower(freqNow) = median(pNow);
        freqMeanPower(freqNow) = mean(pNow);
        freqMaxPower(freqNow) = max(pNow);
        freqHotFraction(freqNow) = mean((pNow ./ powerRef) >= hotThreshold);
    end
end

freqMedianForHop = local_map_freq_stat(freqMedianPower, freqIdx, powerRef);
freqMeanForHop = local_map_freq_stat(freqMeanPower, freqIdx, powerRef);
freqMaxForHop = local_map_freq_stat(freqMaxPower, freqIdx, powerRef);
freqHotForHop = freqHotFraction(freqIdx);

prevHopPower = [hopPower(1); hopPower(1:end-1)];
nextHopPower = [hopPower(2:end); hopPower(end)];
hopPowerRatio = hopPower ./ powerRef;
freqMedianPowerRatio = freqMedianForHop ./ powerRef;
freqMeanPowerRatio = freqMeanForHop ./ powerRef;
freqMaxPowerRatio = freqMaxForHop ./ powerRef;
hopToFreqPowerRatio = hopPower ./ max(freqMedianForHop, eps);
ruleFreqReliability = local_erasure_reliability_from_ratio( ...
    freqMedianPowerRatio, local_cfg_positive(erasureCfg, "freqPowerRatioThreshold"), ...
    local_cfg_probability(erasureCfg, "minReliability"), local_cfg_positive(erasureCfg, "softSlope"));
ruleHopReliability = local_erasure_reliability_from_ratio( ...
    hopPowerRatio, local_cfg_positive(erasureCfg, "hopPowerRatioThreshold"), ...
    local_cfg_probability(erasureCfg, "minReliability"), local_cfg_positive(erasureCfg, "softSlope"));
ruleReliability = min(ruleFreqReliability, ruleHopReliability);

if nFreqs > 1
    freqIndexNorm = 2 * (double(freqIdx) - 1) / double(nFreqs - 1) - 1;
else
    freqIndexNorm = zeros(nHops, 1);
end
absFreqOffsetNorm = zeros(nHops, 1);
if isfield(hopInfo, "freqOffsets") && ~isempty(hopInfo.freqOffsets)
    freqOffsets = double(hopInfo.freqOffsets(:));
    if numel(freqOffsets) >= nHops
        freqOffsets = freqOffsets(1:nHops);
        maxAbsFreq = max(abs(freqOffsets));
        if isfinite(maxAbsFreq) && maxAbsFreq > 0
            absFreqOffsetNorm = abs(freqOffsets) ./ maxAbsFreq;
        end
    end
end
if nHops > 1
    hopIndexNorm = 2 * ((1:nHops).' - 1) / double(nHops - 1) - 1;
else
    hopIndexNorm = 0;
end

featureMatrix = [ ...
    hopPowerRatio, ...
    hopAbsMean ./ absMeanRef, ...
    hopAbsStd ./ absStdRef, ...
    freqMedianPowerRatio, ...
    freqMeanPowerRatio, ...
    freqMaxPowerRatio, ...
    prevHopPower ./ powerRef, ...
    nextHopPower ./ powerRef, ...
    hopToFreqPowerRatio, ...
    freqHotForHop, ...
    freqIndexNorm, ...
    absFreqOffsetNorm, ...
    hopIndexNorm, ...
    constellationMse, ...
    iqPowerImbalance, ...
    edgeHop, ...
    ruleFreqReliability, ...
    ruleHopReliability, ...
    ruleReliability];
featureMatrix(~isfinite(featureMatrix)) = 0;

expectedNames = ml_fh_erasure_feature_names();
if size(featureMatrix, 2) ~= numel(expectedNames)
    error("FH-erasure feature count mismatch.");
end

info = struct();
info.nHops = nHops;
info.hopLen = hopLen;
info.freqIdx = freqIdx;
info.nFreqs = nFreqs;
info.hopPower = hopPower;
info.powerRef = powerRef;
info.freqMedianPower = freqMedianPower;
info.featureNames = expectedNames;
end

function value = local_cfg_positive(cfg, fieldName)
if ~(isfield(cfg, fieldName) && ~isempty(cfg.(fieldName)))
    error("erasureCfg.%s is required.", fieldName);
end
value = double(cfg.(fieldName));
if ~(isscalar(value) && isfinite(value) && value > 0)
    error("erasureCfg.%s must be a positive finite scalar.", fieldName);
end
end

function value = local_cfg_nonnegative(cfg, fieldName)
if ~(isfield(cfg, fieldName) && ~isempty(cfg.(fieldName)))
    error("erasureCfg.%s is required.", fieldName);
end
value = double(cfg.(fieldName));
if ~(isscalar(value) && isfinite(value) && value >= 0)
    error("erasureCfg.%s must be a nonnegative finite scalar.", fieldName);
end
end

function value = local_cfg_probability(cfg, fieldName)
value = local_cfg_nonnegative(cfg, fieldName);
if value > 1
    error("erasureCfg.%s must be in [0, 1].", fieldName);
end
end

function idx = local_hop_indices(hopIdx, hopLen, totalLen, edgeGuard)
startIdx = (hopIdx - 1) * hopLen + 1;
stopIdx = min(totalLen, hopIdx * hopLen);
edgeGuard = max(0, round(double(edgeGuard)));
startIdx = min(stopIdx + 1, startIdx + edgeGuard);
stopIdx = max(startIdx - 1, stopIdx - edgeGuard);
idx = (startIdx:stopIdx).';
end

function ref = local_positive_ref(x)
x = double(x(:));
x = x(isfinite(x) & x > 0);
if isempty(x)
    ref = 1;
else
    ref = median(x);
end
if ~(isfinite(ref) && ref > 0)
    ref = 1;
end
end

function mapped = local_map_freq_stat(freqStat, freqIdx, defaultValue)
mapped = freqStat(freqIdx);
bad = ~isfinite(mapped) | mapped <= 0;
mapped(bad) = defaultValue;
end

function mse = local_constellation_mse(seg, modCfg)
seg = seg(:);
if isempty(seg)
    mse = 0;
    return;
end
switch upper(string(modCfg.type))
    case "BPSK"
        dec = sign(real(seg));
        dec(dec == 0) = 1;
        ref = complex(dec, 0);
    case {"QPSK", "MSK"}
        decI = sign(real(seg));
        decQ = sign(imag(seg));
        decI(decI == 0) = 1;
        decQ(decQ == 0) = 1;
        ref = (decI + 1j * decQ) / sqrt(2);
    otherwise
        error("Unsupported modulation for FH-erasure features: %s", char(string(modCfg.type)));
end
mse = mean(abs(seg - ref).^2) / max(mean(abs(seg).^2), eps);
if ~(isscalar(mse) && isfinite(mse))
    mse = 0;
end
end

function rel = local_erasure_reliability_from_ratio(ratio, threshold, minReliability, softSlope)
ratio = double(ratio);
threshold = double(threshold);
excess = max(ratio - threshold, 0);
rel = 1 ./ (1 + double(softSlope) .* excess);
rel = max(double(minReliability), min(1, rel));
end
