function front = capture_synced_block_from_samples(rxSampleRaw, syncSymRef, totalLen, syncCfgUse, mitigation, modCfg, waveform, sampleAction, bootstrapChain)
%CAPTURE_SYNCED_BLOCK_FROM_SAMPLES  Layered RX front-end from raw samples.

if nargin < 9
    bootstrapChain = strings(1, 0);
end

rxSampleRaw = rxSampleRaw(:);
syncSymRef = syncSymRef(:);
sampleAction = string(sampleAction);
bootstrapChain = string(bootstrapChain(:).');
syncStageSps = local_sync_stage_sps_local(waveform);
stageTotalLen = local_stage_symbol_sequence_length_local(totalLen, syncStageSps);

front = struct( ...
    "ok", false, ...
    "bootstrapPath", "", ...
    "bootstrapCapture", struct(), ...
    "startIdx", NaN, ...
    "syncInfo", struct(), ...
    "rxSync", complex(zeros(0, 1)), ...
    "rFull", complex(zeros(0, 1)), ...
    "reliabilityFull", zeros(0, 1));

[rxStage, rawReliability] = local_sync_stage_observation_from_samples_local(rxSampleRaw, waveform, sampleAction, mitigation, syncStageSps);
syncRefStage = local_sync_reference_stage_local(syncSymRef, waveform, syncStageSps);
syncCfgStage = local_sync_cfg_for_stage_local(syncCfgUse, syncStageSps);
capture = adaptive_frontend_bootstrap_capture(rxStage, syncRefStage, stageTotalLen, syncCfgStage, mitigation, modCfg, bootstrapChain);
front.bootstrapCapture = capture;
front.bootstrapPath = string(capture.bootstrapPath);
if ~capture.ok
    return;
end

fineSearchRadius = 0;
if isfield(syncCfgStage, "fineSearchRadius") && ~isempty(syncCfgStage.fineSearchRadius)
    fineSearchRadius = round(double(syncCfgStage.fineSearchRadius));
end
searchRadius = max([8 * syncStageSps, round(numel(syncRefStage) / 4), fineSearchRadius + 4 * syncStageSps]);
[startIdxStage, syncInfoStage] = local_refine_stage_capture_local( ...
    capture.rxSync, syncRefStage, capture.startIdx, syncCfgStage, searchRadius);
if isempty(startIdxStage) || ~isfinite(startIdxStage)
    return;
end

[startIdx, timingInfo] = local_estimate_symbol_timing_from_stage_local( ...
    capture.rxSync, startIdxStage, syncSymRef, syncCfgUse, modCfg, syncStageSps);
if isempty(startIdx) || ~isfinite(startIdx)
    return;
end

[rFull, okFull, extractInfo] = extract_fractional_block(capture.rxSync, startIdx, totalLen, ...
    local_symbol_extract_sync_cfg_local(syncCfgUse), modCfg, syncStageSps);
if ~okFull
    return;
end
[rFull, syncCompInfo] = local_apply_symbol_block_sync_compensation_local(rFull, syncSymRef, syncCfgUse);
syncInfo = local_merge_stage_sync_info_local(syncInfoStage, timingInfo, syncCompInfo, startIdxStage, startIdx, syncStageSps);

front.ok = true;
front.startIdx = startIdx;
front.syncInfo = syncInfo;
front.rxSync = capture.rxSync;
front.rFull = rFull;
rawReliabilityBlk = local_extract_reliability_from_sample_times_local(rawReliability, extractInfo.sampleTimes);
captureReliabilityBlk = local_extract_reliability_from_sample_times_local(capture.reliabilityTrack, extractInfo.sampleTimes);
rawReliabilityBlk = local_fit_reliability_length_local(rawReliabilityBlk, totalLen);
captureReliabilityBlk = local_fit_reliability_length_local(captureReliabilityBlk, totalLen);
front.reliabilityFull = min(rawReliabilityBlk, captureReliabilityBlk);
end

function [rxStage, relStage] = local_sync_stage_observation_from_samples_local(rxSample, waveform, sampleAction, mitigation, stageSps)
rxSample = rxSample(:);
sampleAction = string(sampleAction);
relSample = ones(numel(rxSample), 1);
if sampleAction == "none"
    rxPrep = rxSample;
else
    [rxPrep, relSample] = mitigate_impulses(rxSample, sampleAction, mitigation);
end

rxMf = local_matched_filter_samples_local(rxPrep, waveform);
relMf = local_matched_filter_reliability_samples_local(relSample, waveform);
[rxStage, relStage] = local_decimate_stage_branch_local(rxMf, relMf, waveform, stageSps);
relStage = local_fit_reliability_length_local(relStage, numel(rxStage));
end

function yMf = local_matched_filter_samples_local(ySample, waveform)
ySample = ySample(:);
if ~waveform.enable
    yMf = ySample;
    return;
end
if waveform.rxMatchedFilter
    yMf = filter(waveform.rrcTaps(:), 1, ySample);
    totalGd = 2 * waveform.groupDelaySamples;
    if numel(yMf) <= totalGd
        yMf = complex(zeros(0, 1));
        return;
    end
    yMf = yMf(totalGd+1:end);
else
    yMf = ySample;
end
end

function relMf = local_matched_filter_reliability_samples_local(relSample, waveform)
relSample = double(relSample(:));
relSample(~isfinite(relSample)) = 0;
relSample = max(min(relSample, 1), 0);
if ~waveform.enable
    relMf = relSample;
    return;
end
if waveform.rxMatchedFilter
    taps = abs(double(waveform.rrcTaps(:)));
    if ~any(taps > 0)
        taps = ones(size(taps));
    end
    taps = taps / sum(taps);
    relMf = filter(taps, 1, relSample);
    totalGd = 2 * waveform.groupDelaySamples;
    if numel(relMf) <= totalGd
        relMf = zeros(0, 1);
        return;
    end
    relMf = relMf(totalGd+1:end);
else
    relMf = relSample;
end
relMf = max(min(relMf, 1), 0);
end

function [yStage, relStage] = local_decimate_stage_branch_local(yMf, relMf, waveform, stageSps)
yMf = yMf(:);
relMf = relMf(:);
if ~waveform.enable
    if stageSps ~= 1
        error("未启用波形成型时，接收同步级采样率只能为1 sps。");
    end
    yStage = yMf;
    relStage = relMf;
    return;
end

stageSps = max(1, round(double(stageSps)));
if mod(double(waveform.sps), double(stageSps)) ~= 0
    error("waveform.sps=%d 不能整数降采样到 %d sps。", waveform.sps, stageSps);
end
decim = round(double(waveform.sps) / double(stageSps));
yStage = yMf(1:decim:end);
relStage = relMf(1:decim:end);
relStage = max(min(relStage, 1), 0);
end

function stageSps = local_sync_stage_sps_local(waveform)
stageSps = 1;
if ~isstruct(waveform)
    return;
end
if ~(isfield(waveform, "enable") && waveform.enable && isfield(waveform, "sps"))
    return;
end
if double(waveform.sps) < 2
    return;
end
if mod(double(waveform.sps), 2) ~= 0
    error("接收链重构要求 waveform.sps 能够整数降采样到 2 sps，当前 waveform.sps=%d。", waveform.sps);
end
stageSps = 2;
end

function nStage = local_stage_symbol_sequence_length_local(nSym, stageSps)
nSym = max(0, round(double(nSym)));
stageSps = max(1, round(double(stageSps)));
if nSym == 0
    nStage = 0;
    return;
end
if stageSps == 1
    nStage = nSym;
    return;
end
nStage = (nSym - 1) * stageSps + 1;
end

function syncRefStage = local_sync_reference_stage_local(syncSymRef, waveform, stageSps)
syncSymRef = syncSymRef(:);
stageSps = max(1, round(double(stageSps)));
if stageSps == 1 || ~waveform.enable
    syncRefStage = syncSymRef;
    return;
end

txSyncSample = pulse_tx_from_symbol_rate(syncSymRef, waveform);
syncMf = local_matched_filter_samples_local(txSyncSample, waveform);
[syncRefStage, ~] = local_decimate_stage_branch_local(syncMf, ones(numel(syncMf), 1), waveform, stageSps);
syncRefStage = local_fit_complex_length_local(syncRefStage, local_stage_symbol_sequence_length_local(numel(syncSymRef), stageSps));
syncRefPower = mean(abs(syncRefStage).^2);
if syncRefPower > 0
    syncRefStage = syncRefStage / sqrt(syncRefPower);
end
end

function syncCfgStage = local_sync_cfg_for_stage_local(syncCfgUse, stageSps)
syncCfgStage = syncCfgUse;
stageSps = max(1, round(double(stageSps)));
if stageSps <= 1
    return;
end

if isfield(syncCfgStage, "fineSearchRadius") && ~isempty(syncCfgStage.fineSearchRadius)
    syncCfgStage.fineSearchRadius = round(double(syncCfgStage.fineSearchRadius) * stageSps);
end
if isfield(syncCfgStage, "corrExclusionRadius") && ~isempty(syncCfgStage.corrExclusionRadius)
    syncCfgStage.corrExclusionRadius = round(double(syncCfgStage.corrExclusionRadius) * stageSps);
end
if isfield(syncCfgStage, "minSearchIndex") && isfinite(double(syncCfgStage.minSearchIndex))
    syncCfgStage.minSearchIndex = double(syncCfgStage.minSearchIndex) * stageSps;
end
if isfield(syncCfgStage, "maxSearchIndex") && isfinite(double(syncCfgStage.maxSearchIndex))
    syncCfgStage.maxSearchIndex = double(syncCfgStage.maxSearchIndex) * stageSps;
end
syncCfgStage.enableFractionalTiming = false;
syncCfgStage.compensateCarrier = false;
syncCfgStage.equalizeAmplitude = false;
syncCfgStage.estimateCfo = false;
if isfield(syncCfgStage, "fractionalRange")
    syncCfgStage.fractionalRange = 0;
end
if isfield(syncCfgStage, "fractionalStep")
    syncCfgStage.fractionalStep = 0;
end
if isfield(syncCfgStage, "timingDll") && isstruct(syncCfgStage.timingDll) ...
        && isfield(syncCfgStage.timingDll, "enable")
    syncCfgStage.timingDll.enable = false;
end
end

function cfgOut = local_symbol_extract_sync_cfg_local(syncCfgUse)
cfgOut = syncCfgUse;
cfgOut.enableFractionalTiming = false;
if isfield(cfgOut, "fractionalRange")
    cfgOut.fractionalRange = 0;
end
if isfield(cfgOut, "fractionalStep")
    cfgOut.fractionalStep = 0;
end
end

function [startIdxStage, syncInfo] = local_refine_stage_capture_local(rxStage, syncRefStage, startHintStage, syncCfgStage, searchRadiusStage)
rxStage = rxStage(:);
searchRadiusStage = max(0, round(double(searchRadiusStage)));
syncInfo = struct();
startIdxStage = [];
if isempty(rxStage) || isempty(syncRefStage)
    return;
end

cfg = syncCfgStage;
maxIdx = max(1, numel(rxStage) - numel(syncRefStage) + 1);
cfg.minSearchIndex = max(1, floor(double(startHintStage) - searchRadiusStage));
cfg.maxSearchIndex = min(maxIdx, ceil(double(startHintStage) + searchRadiusStage));
[startIdxStage, ~, syncInfo] = frame_sync(rxStage, syncRefStage, cfg);
end

function [startIdxStage, timingInfo] = local_estimate_symbol_timing_from_stage_local(rxStage, startHintStage, syncSymRef, syncCfgUse, modCfg, stageSps)
rxStage = rxStage(:);
syncSymRef = syncSymRef(:);
stageSps = max(1, round(double(stageSps)));
timingInfo = struct( ...
    "fractionalOffsetSymbols", 0, ...
    "corrPeak", NaN, ...
    "timingCompensated", false);
startIdxStage = [];
if isempty(rxStage) || isempty(syncSymRef)
    return;
end

fracGrid = 0;
if isfield(syncCfgUse, "enableFractionalTiming") && logical(syncCfgUse.enableFractionalTiming)
    fracRange = 0.5;
    fracStep = 0.05;
    if isfield(syncCfgUse, "fractionalRange") && ~isempty(syncCfgUse.fractionalRange)
        fracRange = abs(double(syncCfgUse.fractionalRange));
    end
    if isfield(syncCfgUse, "fractionalStep") && ~isempty(syncCfgUse.fractionalStep)
        fracStep = abs(double(syncCfgUse.fractionalStep));
    end
    if fracRange > 0 && fracStep > 0
        fracGrid = -fracRange:fracStep:fracRange;
        if isempty(fracGrid) || ~any(abs(fracGrid) < 1e-12)
            fracGrid = unique([fracGrid 0]);
        end
    end
end

bestScore = -inf;
bestOffsetSym = 0;
for offsetSym = fracGrid
    startNow = double(startHintStage) + double(offsetSym) * double(stageSps);
    [seg, okSeg] = extract_fractional_block(rxStage, startNow, numel(syncSymRef), ...
        local_symbol_extract_sync_cfg_local(syncCfgUse), modCfg, stageSps);
    if ~okSeg
        continue;
    end

    if isfield(syncCfgUse, "estimateCfo") && logical(syncCfgUse.estimateCfo)
        symAxis = (0:numel(syncSymRef)-1).';
        [wTmp, phiTmp] = local_estimate_cfo_phase_local(seg, syncSymRef, symAxis);
        segUse = seg .* exp(-1j * (wTmp * symAxis + phiTmp));
    else
        segUse = seg;
    end
    score = abs(sum(segUse .* conj(syncSymRef)));
    if score <= bestScore
        continue;
    end

    bestScore = score;
    bestOffsetSym = double(offsetSym);
end

if ~isfinite(bestScore)
    return;
end

startIdxStage = double(startHintStage) + bestOffsetSym * double(stageSps);
timingInfo.fractionalOffsetSymbols = bestOffsetSym;
timingInfo.corrPeak = bestScore;
timingInfo.timingCompensated = abs(bestOffsetSym) > 1e-12;
end

function [rComp, compInfo] = local_apply_symbol_block_sync_compensation_local(rSym, syncSymRef, syncCfgUse)
rSym = rSym(:);
syncSymRef = syncSymRef(:);
rComp = rSym;
compInfo = struct( ...
    "compensated", false, ...
    "cfoRadPerSample", 0, ...
    "chanGainEstimate", complex(NaN, NaN), ...
    "phaseEstimateRad", NaN, ...
    "amplitudeEstimate", NaN);
if isempty(rSym) || isempty(syncSymRef)
    return;
end

if ~isfield(syncCfgUse, "compensateCarrier") || ~logical(syncCfgUse.compensateCarrier)
    return;
end

pre = rSym(1:min(numel(rSym), numel(syncSymRef)));
syncRefUse = syncSymRef(1:numel(pre));
if numel(pre) ~= numel(syncRefUse) || isempty(pre) || ~any(abs(pre) > 0)
    return;
end

denom = sum(abs(syncRefUse).^2);
if denom <= 0
    return;
end

cfoRad = 0;
phiHat = 0;
if isfield(syncCfgUse, "estimateCfo") && logical(syncCfgUse.estimateCfo)
    symAxis = (0:numel(pre)-1).';
    [cfoRad, phiHat] = local_estimate_cfo_phase_local(pre, syncRefUse, symAxis);
    rComp = rSym .* exp(-1j * (cfoRad * (0:numel(rSym)-1).' + phiHat));
end

preComp = rComp(1:numel(syncRefUse));
hHat = sum(preComp .* conj(syncRefUse)) / denom;
if abs(hHat) <= 1e-12
    return;
end

if ~isfield(syncCfgUse, "equalizeAmplitude") || logical(syncCfgUse.equalizeAmplitude)
    compGain = hHat;
else
    compGain = exp(1j * angle(hHat));
end
rComp = rComp ./ compGain;

compInfo.compensated = true;
compInfo.cfoRadPerSample = double(cfoRad);
compInfo.chanGainEstimate = hHat;
compInfo.phaseEstimateRad = angle(hHat);
compInfo.amplitudeEstimate = abs(hHat);
end

function syncInfo = local_merge_stage_sync_info_local(syncInfoStage, timingInfo, compInfo, coarseStartIdxStage, symbolStartIdxStage, stageSps)
syncInfo = syncInfoStage;
syncInfo.coarseStageStartIdx = double(coarseStartIdxStage);
syncInfo.stageStartIdx = double(symbolStartIdxStage);
syncInfo.stageSps = double(stageSps);
syncInfo.fineIdx = floor(double(symbolStartIdxStage));
syncInfo.fineFrac = double(symbolStartIdxStage) - floor(double(symbolStartIdxStage));
syncInfo.timingOffsetSymbols = double(timingInfo.fractionalOffsetSymbols);
syncInfo.timingCorrPeak = double(timingInfo.corrPeak);
syncInfo.timingCompensated = logical(timingInfo.timingCompensated);
syncInfo.cfoRadPerSample = double(compInfo.cfoRadPerSample);
syncInfo.chanGainEstimate = compInfo.chanGainEstimate;
syncInfo.phaseEstimateRad = double(compInfo.phaseEstimateRad);
syncInfo.amplitudeEstimate = double(compInfo.amplitudeEstimate);
syncInfo.compensated = logical(compInfo.compensated);
end

function [wHat, phiHat] = local_estimate_cfo_phase_local(seg, pre, nAbs)
z = seg(:) .* conj(pre(:));
z(abs(z) < 1e-12) = 1e-12;
phaseVec = unwrap(angle(z));
coef = polyfit(nAbs(:), phaseVec, 1);
wHat = coef(1);
phiHat = coef(2);
end

function relOut = local_extract_reliability_from_sample_times_local(reliabilityTrack, sampleTimes)
reliabilityTrack = double(reliabilityTrack(:));
sampleTimes = double(sampleTimes(:));
if isempty(reliabilityTrack) || isempty(sampleTimes)
    relOut = zeros(0, 1);
    return;
end
reliabilityTrack(~isfinite(reliabilityTrack)) = 0;
reliabilityTrack = max(min(reliabilityTrack, 1), 0);
idx = (1:numel(reliabilityTrack)).';
relOut = interp1(idx, reliabilityTrack, sampleTimes, "linear", 0);
relOut(~isfinite(relOut)) = 0;
relOut = max(min(relOut, 1), 0);
end

function relPrep = local_fit_reliability_length_local(reliability, targetLen)
reliability = double(reliability(:));
reliability(~isfinite(reliability)) = 0;
reliability = max(min(reliability, 1), 0);
targetLen = max(0, round(double(targetLen)));
if numel(reliability) >= targetLen
    relPrep = reliability(1:targetLen);
else
    relPrep = [reliability; ones(targetLen - numel(reliability), 1)];
end
end

function y = local_fit_complex_length_local(x, targetLen)
x = x(:);
targetLen = max(0, round(double(targetLen)));
if numel(x) >= targetLen
    y = x(1:targetLen);
else
    y = [x; complex(zeros(targetLen - numel(x), 1))];
end
end
