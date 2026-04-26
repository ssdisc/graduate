function front = capture_synced_block_with_diversity(rxCapture, syncSymRef, totalLen, syncCfgUse, mitigation, modCfg, waveform, sampleAction, bootstrapChain, fhCaptureCfg, rxDiversityCfg)
%CAPTURE_SYNCED_BLOCK_WITH_DIVERSITY Capture and MRC-combine one or more RX branches.

if nargin < 9
    bootstrapChain = strings(1, 0);
end
if nargin < 10 || isempty(fhCaptureCfg)
    fhCaptureCfg = struct("enable", false);
end
if nargin < 11 || isempty(rxDiversityCfg)
    rxDiversityCfg = struct("enable", false, "nRx", 1, "combineMethod", "mrc");
end

branchSamples = rx_capture_branch_list(rxCapture);
if isscalar(branchSamples)
    cfgSingle = rx_validate_diversity_cfg(rxDiversityCfg, "rxDiversity");
    if cfgSingle.enable
        error("RX diversity capture requires multiple branches when rxDiversity.enable=true.");
    end
    front = capture_synced_block_from_samples( ...
        branchSamples{1}, syncSymRef, totalLen, syncCfgUse, mitigation, modCfg, waveform, sampleAction, bootstrapChain, fhCaptureCfg);
    front.branchFronts = {front};
    front.branchOkMask = true;
    front.branchCombineWeights = complex(1, 0);
    front.branchPowerWeights = 1;
    return;
end

cfg = rx_validate_diversity_cfg(rxDiversityCfg, "rxDiversity");
if ~cfg.enable
    error("Multi-branch capture requires rxDiversity.enable=true.");
end
if numel(branchSamples) ~= double(cfg.nRx)
    error("RX diversity capture expects %d branches, got %d.", double(cfg.nRx), numel(branchSamples));
end

fronts = cell(numel(branchSamples), 1);
okMask = false(numel(branchSamples), 1);
for branchIdx = 1:numel(branchSamples)
    fronts{branchIdx} = capture_synced_block_from_samples( ...
        branchSamples{branchIdx}, syncSymRef, totalLen, syncCfgUse, mitigation, modCfg, waveform, sampleAction, bootstrapChain, fhCaptureCfg);
    okMask(branchIdx) = fronts{branchIdx}.ok;
end
if ~any(okMask)
    front = fronts{1};
    front.branchFronts = fronts;
    front.branchOkMask = okMask;
    front.branchCombineWeights = complex(zeros(numel(fronts), 1));
    front.branchPowerWeights = zeros(numel(fronts), 1);
    return;
end

usedIdx = find(okMask);
combineWeights = complex(zeros(numel(usedIdx), 1));
powerWeights = zeros(numel(usedIdx), 1);
for idx = 1:numel(usedIdx)
    [combineWeights(idx), powerWeights(idx)] = local_diversity_branch_combine_weights_local( ...
        syncSymRef, fronts{usedIdx(idx)}, syncCfgUse);
end
if any(~isfinite(powerWeights)) || any(powerWeights <= 0)
    error("RX diversity combining produced invalid branch power weights.");
end

rMat = complex(zeros(totalLen, numel(usedIdx)));
relMat = zeros(totalLen, numel(usedIdx));
for idx = 1:numel(usedIdx)
    frontNow = fronts{usedIdx(idx)};
    rMat(:, idx) = rx_fit_complex_length(frontNow.rFull, totalLen);
    relMat(:, idx) = rx_expand_reliability(frontNow.reliabilityFull, totalLen);
end

switch cfg.combineMethod
    case "mrc"
        denom = sum(powerWeights);
        if ~(isfinite(denom) && denom > 0)
            error("RX diversity MRC denominator is invalid.");
        end
        rComb = (rMat * combineWeights) / denom;
        relComb = (relMat * powerWeights) / denom;
    otherwise
        error("Unsupported rxDiversity.combineMethod: %s.", char(cfg.combineMethod));
end

[~, refLocalIdx] = max(powerWeights);
front = fronts{usedIdx(refLocalIdx)};
front.ok = true;
front.rFull = rComb;
front.reliabilityFull = rx_expand_reliability(relComb, totalLen);
branchCombineWeights = complex(zeros(numel(fronts), 1));
branchPowerWeights = zeros(numel(fronts), 1);
branchCombineWeights(usedIdx) = combineWeights;
branchPowerWeights(usedIdx) = powerWeights;
front.branchFronts = fronts;
front.branchOkMask = okMask;
front.branchCombineWeights = branchCombineWeights;
front.branchPowerWeights = branchPowerWeights;
end

function [combineWeight, powerWeight] = local_diversity_branch_combine_weights_local(syncSymRef, front, syncCfgUse)
if ~(isstruct(front) && isfield(front, "syncInfo") && isstruct(front.syncInfo))
    error("RX diversity branch is missing syncInfo for combining.");
end

gainRaw = complex(NaN, NaN);
if isfield(front.syncInfo, "chanGainEstimate") && ~isempty(front.syncInfo.chanGainEstimate)
    gainRaw = front.syncInfo.chanGainEstimate;
end
gainRawValid = isfinite(gainRaw) && abs(gainRaw) > 1e-12;

compApplied = false;
if isfield(front.syncInfo, "compensated") && ~isempty(front.syncInfo.compensated)
    compApplied = logical(front.syncInfo.compensated);
    if ~isscalar(compApplied)
        error("RX diversity branch syncInfo.compensated must be a logical scalar.");
    end
end

equalizeAmplitude = true;
if isstruct(syncCfgUse) && isfield(syncCfgUse, "equalizeAmplitude") && ~isempty(syncCfgUse.equalizeAmplitude)
    equalizeAmplitude = logical(syncCfgUse.equalizeAmplitude);
    if ~isscalar(equalizeAmplitude)
        error("rxSync.equalizeAmplitude must be a logical scalar.");
    end
end

if compApplied && gainRawValid
    gainMag = abs(gainRaw);
    powerWeight = gainMag ^ 2;
    if equalizeAmplitude
        % The branch has already been amplitude-equalized by sync, so use
        % post-equalization power weights for MRC.
        combineWeight = complex(powerWeight, 0);
    else
        % Only phase was removed; the residual branch amplitude is |hHat|.
        combineWeight = complex(gainMag, 0);
    end
    return;
end

gainRaw = local_estimate_diversity_branch_gain_local(syncSymRef, front);
powerWeight = abs(gainRaw) ^ 2;
combineWeight = conj(gainRaw);
end

function gain = local_estimate_diversity_branch_gain_local(syncSymRef, front)
syncSymRef = syncSymRef(:);
if ~(isstruct(front) && isfield(front, "rFull") && numel(front.rFull) >= numel(syncSymRef))
    error("RX diversity branch is missing a valid synchronized preamble.");
end
den = sum(abs(syncSymRef).^2);
if ~(isfinite(den) && den > 0)
    error("RX diversity reference preamble energy is invalid.");
end
preambleRx = front.rFull(1:numel(syncSymRef));
gain = sum(conj(syncSymRef) .* preambleRx) / den;
if ~isfinite(gain)
    error("RX diversity branch gain estimate is invalid.");
end
end
