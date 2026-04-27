function [dataSymOut, reliabilitySym, diagOut] = narrowband_profile_frontend(dataSymIn, pkt, runtimeCfg, method)
%NARROWBAND_PROFILE_FRONTEND Dedicated narrowband payload front-end.

arguments
    dataSymIn (:,1)
    pkt (1,1) struct
    runtimeCfg (1,1) struct
    method (1,1) string
end

dataSym = dataSymIn(:);
method = lower(string(method));

switch method
    case "none"
        dataSymOut = dataSym;
        reliabilitySym = ones(numel(dataSym), 1);
        diagOut = struct("frontEndMethod", method, "ok", true);

    case "fh_erasure"
        dataSymOut = dataSym;
        [reliabilitySym, infoOut] = local_narrowband_hop_reliability_local(dataSym, pkt, runtimeCfg);
        diagOut = struct( ...
            "frontEndMethod", method, ...
            "ok", true, ...
            "hopReliability", infoOut.hopReliability, ...
            "freqReliability", infoOut.freqReliability, ...
            "featureInfo", infoOut.featureInfo);

    case "narrowband_notch_soft"
        [dataSymOut, reliabilitySym, diagOut] = local_narrowband_notch_soft_local(dataSym, pkt, runtimeCfg);

    case "narrowband_subband_excision_soft"
        [dataSymOut, reliabilitySym, diagOut] = local_narrowband_subband_excision_soft_local(dataSym, pkt, runtimeCfg);

    case "narrowband_cnn_residual_soft"
        [dataSymOut, reliabilitySym, diagOut] = local_narrowband_cnn_residual_soft_local(dataSym, pkt, runtimeCfg);

    otherwise
        error("Unsupported narrowband profile method: %s.", char(method));
end
end

function [dataSymOut, reliabilitySym, diagOut] = local_narrowband_notch_soft_local(dataSym, pkt, runtimeCfg)
cfg = local_required_narrowband_notch_soft_cfg_local(runtimeCfg.mitigation);
[hopLen, nHops, freqIdx, nFreqs] = local_validate_hop_layout_local(pkt.hopInfo, numel(dataSym));

dataSymOut = dataSym(:);
hopApplied = false(nHops, 1);
hopMaskFraction = zeros(nHops, 1);
freqApplied = false(nFreqs, 1);
freqBounds = cell(nFreqs, 1);
freqObservationSymbols = zeros(nFreqs, 1);

detectCfg = local_build_bandstop_cfg_local(runtimeCfg.mitigation, cfg);

for freqNow = 1:nFreqs
    hopList = find(freqIdx == freqNow);
    if isempty(hopList)
        continue;
    end

    [obs, obsHops] = local_frequency_observation_local( ...
        dataSymOut, hopList, hopLen, cfg.edgeGuardSymbols, cfg.observationSymbolsPerFreq);
    freqObservationSymbols(freqNow) = numel(obs);
    if numel(obs) < cfg.minObservationSymbolsPerFreq
        continue;
    end

    [~, probeInfo] = fft_bandstop_filter(obs, detectCfg);
    if ~(isstruct(probeInfo) && isfield(probeInfo, "applied") && logical(probeInfo.applied) ...
            && isfield(probeInfo, "selectedFreqBounds") && ~isempty(probeInfo.selectedFreqBounds))
        continue;
    end

    applyCfg = detectCfg;
    applyCfg.forcedFreqBounds = double(probeInfo.selectedFreqBounds);
    freqApplied(freqNow) = true;
    freqBounds{freqNow} = double(probeInfo.selectedFreqBounds);

    for hopPos = 1:numel(obsHops)
        hopNow = obsHops(hopPos);
        idxFull = local_hop_symbol_indices_local(hopNow, hopLen, numel(dataSymOut), 0);
        if isempty(idxFull)
            continue;
        end
        [segOut, applyInfo] = fft_bandstop_filter(dataSymOut(idxFull), applyCfg);
        dataSymOut(idxFull) = segOut;
        hopApplied(hopNow) = true;
        if isstruct(applyInfo) && isfield(applyInfo, "maskFraction") && isfinite(double(applyInfo.maskFraction))
            hopMaskFraction(hopNow) = max(hopMaskFraction(hopNow), double(applyInfo.maskFraction));
        end
    end
end

hopPowerPre = local_hop_power_local(dataSym, hopLen, cfg.edgeGuardSymbols);
hopPowerPost = local_hop_power_local(dataSymOut, hopLen, cfg.edgeGuardSymbols);
hopRelPre = local_rule_reliability_local(dataSym, pkt, runtimeCfg);
hopRelPost = local_rule_reliability_local(dataSymOut, pkt, runtimeCfg);

removedPowerFraction = zeros(nHops, 1);
validPower = isfinite(hopPowerPre) & hopPowerPre > 0 & isfinite(hopPowerPost) & hopPowerPost >= 0;
removedPowerFraction(validPower) = max(0, 1 - hopPowerPost(validPower) ./ hopPowerPre(validPower));

hopPenalty = ones(nHops, 1);
active = hopApplied;
hopPenalty(active) = 1 ...
    - double(cfg.maskFractionPenaltySlope) * hopMaskFraction(active) ...
    - double(cfg.powerRemovalPenaltySlope) * removedPowerFraction(active);
hopPenalty = max(double(cfg.minReliability), min(1, hopPenalty));

hopReliability = max(double(cfg.minReliability), min(1, hopRelPost .* hopPenalty));
reliabilitySym = repelem(hopReliability, hopLen, 1);
reliabilitySym = rx_expand_reliability(reliabilitySym, numel(dataSymOut));

if logical(cfg.attenuateSymbols)
    dataSymOut = reliabilitySym .* dataSymOut;
end

freqReliability = ones(nFreqs, 1);
for freqNow = 1:nFreqs
    use = freqIdx == freqNow;
    if any(use)
        freqReliability(freqNow) = median(hopReliability(use));
    end
end

diagOut = struct( ...
    "frontEndMethod", "narrowband_notch_soft", ...
    "ok", true, ...
    "hopReliability", hopReliability, ...
    "hopReliabilityPre", hopRelPre, ...
    "hopReliabilityPost", hopRelPost, ...
    "freqReliability", freqReliability, ...
    "hopApplied", hopApplied, ...
    "hopMaskFraction", hopMaskFraction, ...
    "hopPowerPre", hopPowerPre, ...
    "hopPowerPost", hopPowerPost, ...
    "removedPowerFraction", removedPowerFraction, ...
    "freqApplied", freqApplied, ...
    "freqBounds", {freqBounds}, ...
    "freqObservationSymbols", freqObservationSymbols);
end

function [dataSymOut, reliabilitySym, diagOut] = local_narrowband_subband_excision_soft_local(dataSym, pkt, runtimeCfg)
cfg = local_required_narrowband_notch_soft_cfg_local(runtimeCfg.mitigation);
[hopLen, nHops, freqIdx, nFreqs] = local_validate_hop_layout_local(pkt.hopInfo, numel(dataSym));

dataSymOut = dataSym(:);
hopApplied = false(nHops, 1);
hopMaskFraction = zeros(nHops, 1);
freqApplied = false(nFreqs, 1);
freqBounds = cell(nFreqs, 1);
freqObservationSymbols = zeros(nFreqs, 1);

detectCfg = local_build_bandstop_cfg_local(runtimeCfg.mitigation, cfg);

for freqNow = 1:nFreqs
    hopList = find(freqIdx == freqNow);
    if isempty(hopList)
        continue;
    end

    idxDetect = local_frequency_symbol_indices_local(dataSymOut, hopList, hopLen, cfg.edgeGuardSymbols);
    freqObservationSymbols(freqNow) = numel(idxDetect);
    if numel(idxDetect) < cfg.minObservationSymbolsPerFreq
        continue;
    end

    [~, probeInfo] = fft_bandstop_filter(dataSymOut(idxDetect), detectCfg);
    if ~(isstruct(probeInfo) && isfield(probeInfo, "applied") && logical(probeInfo.applied) ...
            && isfield(probeInfo, "selectedFreqBounds") && ~isempty(probeInfo.selectedFreqBounds))
        continue;
    end

    idxApply = local_frequency_symbol_indices_local(dataSymOut, hopList, hopLen, 0);
    if isempty(idxApply)
        continue;
    end

    applyCfg = detectCfg;
    applyCfg.forcedFreqBounds = double(probeInfo.selectedFreqBounds);
    [obsOut, applyInfo] = fft_bandstop_filter(dataSymOut(idxApply), applyCfg);
    dataSymOut(idxApply) = obsOut;

    freqApplied(freqNow) = true;
    freqBounds{freqNow} = double(probeInfo.selectedFreqBounds);
    hopApplied(hopList) = true;
    if isstruct(applyInfo) && isfield(applyInfo, "maskFraction") && isfinite(double(applyInfo.maskFraction))
        hopMaskFraction(hopList) = max(hopMaskFraction(hopList), double(applyInfo.maskFraction));
    end
end

hopPowerPre = local_hop_power_local(dataSym, hopLen, cfg.edgeGuardSymbols);
hopPowerPost = local_hop_power_local(dataSymOut, hopLen, cfg.edgeGuardSymbols);
hopRelPre = local_rule_reliability_local(dataSym, pkt, runtimeCfg);
hopRelPost = local_rule_reliability_local(dataSymOut, pkt, runtimeCfg);

removedPowerFraction = zeros(nHops, 1);
validPower = isfinite(hopPowerPre) & hopPowerPre > 0 & isfinite(hopPowerPost) & hopPowerPost >= 0;
removedPowerFraction(validPower) = max(0, 1 - hopPowerPost(validPower) ./ hopPowerPre(validPower));

hopPenalty = ones(nHops, 1);
active = hopApplied;
hopPenalty(active) = 1 ...
    - double(cfg.maskFractionPenaltySlope) * hopMaskFraction(active) ...
    - double(cfg.powerRemovalPenaltySlope) * removedPowerFraction(active);
hopPenalty = max(double(cfg.minReliability), min(1, hopPenalty));

hopReliability = max(double(cfg.minReliability), min(1, hopRelPost .* hopPenalty));
reliabilitySym = repelem(hopReliability, hopLen, 1);
reliabilitySym = rx_expand_reliability(reliabilitySym, numel(dataSymOut));

if logical(cfg.attenuateSymbols)
    dataSymOut = reliabilitySym .* dataSymOut;
end

freqReliability = ones(nFreqs, 1);
for freqNow = 1:nFreqs
    use = freqIdx == freqNow;
    if any(use)
        freqReliability(freqNow) = median(hopReliability(use));
    end
end

diagOut = struct( ...
    "frontEndMethod", "narrowband_subband_excision_soft", ...
    "ok", true, ...
    "hopReliability", hopReliability, ...
    "hopReliabilityPre", hopRelPre, ...
    "hopReliabilityPost", hopRelPost, ...
    "freqReliability", freqReliability, ...
    "hopApplied", hopApplied, ...
    "hopMaskFraction", hopMaskFraction, ...
    "hopPowerPre", hopPowerPre, ...
    "hopPowerPost", hopPowerPost, ...
    "removedPowerFraction", removedPowerFraction, ...
    "freqApplied", freqApplied, ...
    "freqBounds", {freqBounds}, ...
    "freqObservationSymbols", freqObservationSymbols);
end

function [dataSymOut, reliabilitySym, diagOut] = local_narrowband_cnn_residual_soft_local(dataSym, pkt, runtimeCfg)
[dataSymExcised, reliabilitySym, baseDiag] = local_narrowband_subband_excision_soft_local(dataSym, pkt, runtimeCfg);
model = local_required_narrowband_residual_model_local(runtimeCfg.mitigation);
[dataSymOut, cnnDiag] = ml_narrowband_residual_predict(dataSymExcised, model);
diagOut = baseDiag;
diagOut.frontEndMethod = "narrowband_cnn_residual_soft";
diagOut.residualCnn = cnnDiag;
end

function [reliabilitySym, infoOut] = local_narrowband_hop_reliability_local(dataSym, pkt, runtimeCfg)
featureNames = ml_fh_erasure_feature_names();
ruleIdx = find(featureNames == "ruleReliability", 1, "first");
if isempty(ruleIdx)
    error("FH erasure feature set is missing ruleReliability.");
end

[featureMatrix, info] = ml_extract_fh_erasure_features(dataSym, pkt.hopInfo, runtimeCfg.mitigation.fhErasure, runtimeCfg.mod);
hopReliability = featureMatrix(:, ruleIdx);
reliabilitySym = repelem(hopReliability, round(double(pkt.hopInfo.hopLen)), 1);
reliabilitySym = rx_expand_reliability(reliabilitySym, numel(dataSym));

nFreqs = max(1, round(double(info.nFreqs)));
freqReliability = zeros(nFreqs, 1);
for freqIdxNow = 1:nFreqs
    use = info.freqIdx == freqIdxNow;
    if any(use)
        freqReliability(freqIdxNow) = median(hopReliability(use));
    else
        freqReliability(freqIdxNow) = 1;
    end
end
infoOut = struct( ...
    "hopReliability", hopReliability, ...
    "freqReliability", freqReliability, ...
    "featureInfo", info);
end

function hopReliability = local_rule_reliability_local(dataSym, pkt, runtimeCfg)
featureNames = ml_fh_erasure_feature_names();
ruleIdx = find(featureNames == "ruleReliability", 1, "first");
if isempty(ruleIdx)
    error("FH erasure feature set is missing ruleReliability.");
end
featureMatrix = ml_extract_fh_erasure_features(dataSym(:), pkt.hopInfo, runtimeCfg.mitigation.fhErasure, runtimeCfg.mod);
hopReliability = featureMatrix(:, ruleIdx);
hopReliability = double(hopReliability(:));
hopReliability(~isfinite(hopReliability)) = 0;
hopReliability = max(0, min(1, hopReliability));
end

function cfg = local_required_narrowband_notch_soft_cfg_local(mitigation)
if ~(isstruct(mitigation) && isfield(mitigation, "narrowbandNotchSoft") && isstruct(mitigation.narrowbandNotchSoft))
    error("mitigation.narrowbandNotchSoft is required for narrowband_notch_soft.");
end
cfg = mitigation.narrowbandNotchSoft;

requiredFields = ["observationSymbolsPerFreq" "minObservationSymbolsPerFreq" "edgeGuardSymbols" ...
    "minReliability" "maskFractionPenaltySlope" "powerRemovalPenaltySlope" "attenuateSymbols" "bandstop"];
for idx = 1:numel(requiredFields)
    fieldName = requiredFields(idx);
    if ~isfield(cfg, fieldName)
        error("mitigation.narrowbandNotchSoft.%s is required.", char(fieldName));
    end
end
if ~(isstruct(cfg.bandstop))
    error("mitigation.narrowbandNotchSoft.bandstop must be a struct.");
end

cfg.observationSymbolsPerFreq = local_positive_integer_local(cfg.observationSymbolsPerFreq, ...
    "mitigation.narrowbandNotchSoft.observationSymbolsPerFreq");
cfg.minObservationSymbolsPerFreq = local_positive_integer_local(cfg.minObservationSymbolsPerFreq, ...
    "mitigation.narrowbandNotchSoft.minObservationSymbolsPerFreq");
cfg.edgeGuardSymbols = local_nonnegative_integer_local(cfg.edgeGuardSymbols, ...
    "mitigation.narrowbandNotchSoft.edgeGuardSymbols");
cfg.minReliability = local_probability_local(cfg.minReliability, "mitigation.narrowbandNotchSoft.minReliability");
cfg.maskFractionPenaltySlope = local_nonnegative_scalar_local(cfg.maskFractionPenaltySlope, ...
    "mitigation.narrowbandNotchSoft.maskFractionPenaltySlope");
cfg.powerRemovalPenaltySlope = local_nonnegative_scalar_local(cfg.powerRemovalPenaltySlope, ...
    "mitigation.narrowbandNotchSoft.powerRemovalPenaltySlope");
cfg.attenuateSymbols = logical(cfg.attenuateSymbols);
end

function model = local_required_narrowband_residual_model_local(mitigation)
if ~(isstruct(mitigation) && isfield(mitigation, "mlNarrowbandResidual") ...
        && isstruct(mitigation.mlNarrowbandResidual))
    error("mitigation.mlNarrowbandResidual is required for narrowband_cnn_residual_soft.");
end
model = mitigation.mlNarrowbandResidual;
end

function detectCfg = local_build_bandstop_cfg_local(mitigation, cfg)
detectCfg = struct();
if isfield(mitigation, "fftBandstop") && isstruct(mitigation.fftBandstop)
    detectCfg = mitigation.fftBandstop;
end
bandstopFields = string(fieldnames(cfg.bandstop));
for idx = 1:numel(bandstopFields)
    fieldName = bandstopFields(idx);
    detectCfg.(fieldName) = cfg.bandstop.(fieldName);
end
detectCfg.forcedFreqBounds = zeros(0, 2);
end

function [hopLen, nHops, freqIdx, nFreqs] = local_validate_hop_layout_local(hopInfo, totalLen)
if ~(isstruct(hopInfo) && isfield(hopInfo, "enable") && logical(hopInfo.enable))
    error("Narrowband payload front-end requires pkt.hopInfo.enable=true.");
end
if isfield(hopInfo, "mode") && lower(string(hopInfo.mode)) == "fast"
    error("Narrowband payload front-end only supports slow FH hopInfo.");
end
if ~(isfield(hopInfo, "hopLen") && isfinite(double(hopInfo.hopLen)) && double(hopInfo.hopLen) > 0)
    error("pkt.hopInfo.hopLen must be a positive finite scalar.");
end
if ~(isfield(hopInfo, "freqIdx") && ~isempty(hopInfo.freqIdx))
    error("pkt.hopInfo.freqIdx is required.");
end

hopLen = round(double(hopInfo.hopLen));
nHops = ceil(double(totalLen) / double(hopLen));
freqIdx = round(double(hopInfo.freqIdx(:)));
if numel(freqIdx) < nHops
    error("Narrowband payload front-end needs %d hop indices, got %d.", nHops, numel(freqIdx));
end
freqIdx = freqIdx(1:nHops);
if any(~isfinite(freqIdx)) || any(freqIdx < 1)
    error("pkt.hopInfo.freqIdx must contain positive finite indices.");
end

nFreqs = max(freqIdx);
if isfield(hopInfo, "nFreqs") && ~isempty(hopInfo.nFreqs)
    nFreqs = max(nFreqs, round(double(hopInfo.nFreqs)));
end
if ~(isscalar(nFreqs) && isfinite(nFreqs) && nFreqs >= 1)
    error("pkt.hopInfo.nFreqs must be a positive finite scalar.");
end
end

function [obs, usedHops] = local_frequency_observation_local(dataSym, hopList, hopLen, edgeGuardSymbols, targetSymbols)
obs = complex(zeros(0, 1));
usedHops = zeros(0, 1);
for idx = 1:numel(hopList)
    hopNow = hopList(idx);
    idxObs = local_hop_symbol_indices_local(hopNow, hopLen, numel(dataSym), edgeGuardSymbols);
    if isempty(idxObs)
        idxObs = local_hop_symbol_indices_local(hopNow, hopLen, numel(dataSym), 0);
    end
    if isempty(idxObs)
        continue;
    end
    obs = [obs; dataSym(idxObs)]; %#ok<AGROW>
    usedHops(end + 1, 1) = hopNow; %#ok<AGROW>
    if numel(obs) >= targetSymbols
        break;
    end
end
end

function idxAll = local_frequency_symbol_indices_local(dataSym, hopList, hopLen, edgeGuardSymbols)
idxAll = zeros(0, 1);
for idx = 1:numel(hopList)
    hopNow = hopList(idx);
    idxHop = local_hop_symbol_indices_local(hopNow, hopLen, numel(dataSym), edgeGuardSymbols);
    if isempty(idxHop)
        idxHop = local_hop_symbol_indices_local(hopNow, hopLen, numel(dataSym), 0);
    end
    if ~isempty(idxHop)
        idxAll = [idxAll; idxHop(:)]; %#ok<AGROW>
    end
end
end

function hopPower = local_hop_power_local(dataSym, hopLen, edgeGuardSymbols)
nHops = ceil(double(numel(dataSym)) / double(hopLen));
hopPower = zeros(nHops, 1);
for hopIdx = 1:nHops
    idx = local_hop_symbol_indices_local(hopIdx, hopLen, numel(dataSym), edgeGuardSymbols);
    if isempty(idx)
        idx = local_hop_symbol_indices_local(hopIdx, hopLen, numel(dataSym), 0);
    end
    if isempty(idx)
        hopPower(hopIdx) = 0;
    else
        seg = dataSym(idx);
        hopPower(hopIdx) = mean(abs(seg).^2);
    end
end
end

function idx = local_hop_symbol_indices_local(hopIdx, hopLen, totalLen, edgeGuardSymbols)
startIdx = (hopIdx - 1) * hopLen + 1;
stopIdx = min(totalLen, hopIdx * hopLen);
edgeGuardSymbols = max(0, round(double(edgeGuardSymbols)));
startIdx = min(stopIdx + 1, startIdx + edgeGuardSymbols);
stopIdx = max(startIdx - 1, stopIdx - edgeGuardSymbols);
idx = (startIdx:stopIdx).';
end

function value = local_positive_integer_local(rawValue, ownerName)
value = double(rawValue);
if ~(isscalar(value) && isfinite(value) && abs(value - round(value)) < 1e-12 && value >= 1)
    error("%s must be a positive integer scalar, got %g.", ownerName, value);
end
value = round(value);
end

function value = local_nonnegative_integer_local(rawValue, ownerName)
value = double(rawValue);
if ~(isscalar(value) && isfinite(value) && abs(value - round(value)) < 1e-12 && value >= 0)
    error("%s must be a nonnegative integer scalar, got %g.", ownerName, value);
end
value = round(value);
end

function value = local_probability_local(rawValue, ownerName)
value = double(rawValue);
if ~(isscalar(value) && isfinite(value) && value >= 0 && value <= 1)
    error("%s must be a scalar in [0, 1], got %g.", ownerName, value);
end
end

function value = local_nonnegative_scalar_local(rawValue, ownerName)
value = double(rawValue);
if ~(isscalar(value) && isfinite(value) && value >= 0)
    error("%s must be a nonnegative finite scalar, got %g.", ownerName, value);
end
end
