function front = capture_synced_block_from_samples(rxSampleRaw, syncSymRef, totalLen, syncCfgUse, mitigation, modCfg, waveform, sampleAction, bootstrapChain, fhCaptureCfg)
%CAPTURE_SYNCED_BLOCK_FROM_SAMPLES  Layered RX front-end from raw samples.

if nargin < 9
    bootstrapChain = strings(1, 0);
end
if nargin < 10 || isempty(fhCaptureCfg)
    fhCaptureCfg = struct("enable", false);
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
    "packetStartSample", NaN, ...
    "packetStopSample", NaN, ...
    "packetSampleLen", NaN, ...
    "syncInfo", struct(), ...
    "rxSync", complex(zeros(0, 1)), ...
    "rFull", complex(zeros(0, 1)), ...
    "reliabilityFull", zeros(0, 1), ...
    "rxPrepForCapture", complex(zeros(0, 1)), ...
    "relSamplePrepForCapture", zeros(0, 1), ...
    "syncStageSps", double(syncStageSps));

if local_preamble_diversity_enabled_local(fhCaptureCfg)
    front = local_capture_with_preamble_diversity_local( ...
        rxSampleRaw, syncSymRef, totalLen, syncCfgUse, mitigation, modCfg, waveform, ...
        sampleAction, bootstrapChain, fhCaptureCfg, syncStageSps, front);
    return;
end

[rxStage, rawReliability, rxPrep, relSamplePrep] = local_sync_stage_observation_from_samples_local( ...
    rxSampleRaw, waveform, sampleAction, mitigation, syncStageSps);
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
if isfield(syncCfgStage, "maxSearchIndex") && isfinite(double(syncCfgStage.maxSearchIndex))
    searchRadius = min(searchRadius, max(4 * syncStageSps, round(double(syncCfgStage.maxSearchIndex))));
end
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

[rFull, reliabilityFull, okFull] = local_extract_symbol_block_local( ...
    capture, rawReliability, rxPrep, relSamplePrep, startIdx, totalLen, fhCaptureCfg, syncCfgUse, mitigation, modCfg, waveform, syncStageSps);
if ~okFull
    return;
end
[rFull, syncCompInfo] = local_apply_symbol_block_sync_compensation_local(rFull, syncSymRef, syncCfgUse);
syncInfo = local_merge_stage_sync_info_local(syncInfoStage, timingInfo, syncCompInfo, startIdxStage, startIdx, syncStageSps);

front.ok = true;
front.startIdx = startIdx;
front.packetStartSample = local_packet_raw_start_sample_local(startIdx, waveform, syncStageSps);
front.packetSampleLen = local_packet_sample_length_local(totalLen, waveform);
front.packetStopSample = double(front.packetStartSample) + double(front.packetSampleLen) - 1;
front.syncInfo = syncInfo;
front.rxSync = capture.rxSync;
front.rFull = rFull;
front.reliabilityFull = local_fit_reliability_length_local(reliabilityFull, totalLen);
front.rxPrepForCapture = rxPrep;
front.relSamplePrepForCapture = relSamplePrep;
front.syncStageSps = double(syncStageSps);
end

function [rxStage, relStage, rxPrep, relSample] = local_sync_stage_observation_from_samples_local(rxSample, waveform, sampleAction, mitigation, stageSps)
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

function [rFull, reliabilityFull, ok] = local_extract_symbol_block_local( ...
    capture, rawReliabilityStage, rxPrep, relSamplePrep, startIdx, totalLen, fhCaptureCfg, syncCfgUse, ~, modCfg, waveform, syncStageSps)
rFull = complex(zeros(0, 1));
reliabilityFull = zeros(0, 1);
ok = false;

if local_fast_fh_capture_enabled_local(fhCaptureCfg)
    [rFull, reliabilityFull, ok] = local_extract_sample_fh_symbol_block_local( ...
        rxPrep, relSamplePrep, startIdx, totalLen, fhCaptureCfg, syncCfgUse, modCfg, waveform, syncStageSps);
    return;
end

[rFull, okBlock, extractInfo] = extract_fractional_block(capture.rxSync, startIdx, totalLen, ...
    local_symbol_extract_sync_cfg_local(syncCfgUse), modCfg, syncStageSps);
if ~okBlock
    return;
end

rawReliabilityBlk = local_extract_reliability_from_sample_times_local(rawReliabilityStage, extractInfo.sampleTimes);
captureReliabilityBlk = local_extract_reliability_from_sample_times_local(capture.reliabilityTrack, extractInfo.sampleTimes);
rawReliabilityBlk = local_fit_reliability_length_local(rawReliabilityBlk, totalLen);
captureReliabilityBlk = local_fit_reliability_length_local(captureReliabilityBlk, totalLen);
reliabilityFull = min(rawReliabilityBlk, captureReliabilityBlk);
ok = true;
end

function [rFull, reliabilityFull, ok] = local_extract_sample_fh_symbol_block_local( ...
    rxPrep, relSamplePrep, startIdx, totalLen, fhCaptureCfg, syncCfgUse, modCfg, waveform, syncStageSps)
rFull = complex(zeros(0, 1));
reliabilityFull = zeros(0, 1);
ok = false;

if ~(isstruct(waveform) && isfield(waveform, "enable") && waveform.enable)
    error("Sample-domain FH capture requires waveform.enable=true.");
end
if ~(isfield(waveform, "sps") && double(waveform.sps) >= 2)
    error("Sample-domain FH capture requires waveform.sps>=2.");
end

decim = round(double(waveform.sps) / double(syncStageSps));
packetStartSample = 1 + (double(startIdx) - 1) * decim;
packetSampleLen = local_packet_sample_length_local(totalLen, waveform);

[pktSample, okPkt, extractInfo] = extract_fractional_block( ...
    rxPrep, packetStartSample, packetSampleLen, local_symbol_extract_sync_cfg_local(syncCfgUse), modCfg, 1);
if ~okPkt
    return;
end

relPkt = local_extract_reliability_from_sample_times_local(relSamplePrep, extractInfo.sampleTimes);
pktSample = local_apply_fast_fh_packet_demod_local(pktSample, fhCaptureCfg, waveform);
pktMf = local_matched_filter_samples_local(pktSample, waveform);
relMf = local_matched_filter_reliability_samples_local(relPkt, waveform);
[rFull, reliabilityFull] = local_decimate_stage_branch_local(pktMf, relMf, waveform, 1);
rFull = local_fit_complex_length_local(rFull, totalLen);
reliabilityFull = local_fit_reliability_length_local(reliabilityFull, totalLen);
ok = numel(rFull) == totalLen && any(abs(rFull) > 0);
end

function tf = local_fast_fh_capture_enabled_local(fhCaptureCfg)
tf = isstruct(fhCaptureCfg) && isfield(fhCaptureCfg, "enable") && logical(fhCaptureCfg.enable);
end

function pktOut = local_apply_fast_fh_packet_demod_local(pktIn, fhCaptureCfg, waveform)
pktOut = pktIn(:);
syncSymbols = local_fast_fh_capture_scalar_local(fhCaptureCfg, "syncSymbols");
headerSymbols = local_fast_fh_capture_scalar_local(fhCaptureCfg, "headerSymbols");
headerStart = local_symbol_boundary_sample_index_local(syncSymbols, waveform);
dataStart = local_symbol_boundary_sample_index_local(syncSymbols + headerSymbols, waveform);

if isfield(fhCaptureCfg, "preambleFhCfg") && isstruct(fhCaptureCfg.preambleFhCfg) ...
        && isfield(fhCaptureCfg.preambleFhCfg, "enable") && fhCaptureCfg.preambleFhCfg.enable
    preambleStop = min(numel(pktOut), headerStart - 1);
    if 1 <= preambleStop
        pktOut(1:preambleStop) = local_fast_fh_segment_demod_local( ...
            pktOut(1:preambleStop), fhCaptureCfg.preambleFhCfg, waveform);
    end
end

if isfield(fhCaptureCfg, "headerFhCfg") && isstruct(fhCaptureCfg.headerFhCfg) ...
        && isfield(fhCaptureCfg.headerFhCfg, "enable") && fhCaptureCfg.headerFhCfg.enable
    headerStop = min(numel(pktOut), dataStart - 1);
    if headerStart <= headerStop
        pktOut(headerStart:headerStop) = local_fast_fh_segment_demod_local( ...
            pktOut(headerStart:headerStop), fhCaptureCfg.headerFhCfg, waveform);
    end
end

if isfield(fhCaptureCfg, "dataFhCfg") && isstruct(fhCaptureCfg.dataFhCfg) ...
        && isfield(fhCaptureCfg.dataFhCfg, "enable") && fhCaptureCfg.dataFhCfg.enable
    dataStart = min(max(1, dataStart), numel(pktOut) + 1);
    if dataStart <= numel(pktOut)
        pktOut(dataStart:end) = local_fast_fh_segment_demod_local( ...
            pktOut(dataStart:end), fhCaptureCfg.dataFhCfg, waveform);
    end
end
end

function segOut = local_fast_fh_segment_demod_local(segIn, fhCfg, waveform)
hopInfo = fh_sample_hop_info_from_cfg(fhCfg, waveform, numel(segIn));
if fh_is_fast(fhCfg)
    segOut = fh_demodulate_samples(segIn, hopInfo, waveform);
    return;
end
segOut = local_slow_fh_segment_demod_with_preselect_local(segIn, hopInfo, waveform);
end

function segOut = local_slow_fh_segment_demod_with_preselect_local(segIn, hopInfo, waveform)
segIn = segIn(:);
segOut = complex(zeros(size(segIn)));
if isempty(segIn)
    return;
end
if ~(isstruct(hopInfo) && isfield(hopInfo, "enable") && hopInfo.enable)
    segOut = segIn;
    return;
end
if ~(isfield(hopInfo, "hopLenSamples") && ~isempty(hopInfo.hopLenSamples))
    error("slow FH sample demodulation requires hopInfo.hopLenSamples.");
end
if ~(isfield(hopInfo, "freqOffsets") && ~isempty(hopInfo.freqOffsets))
    error("slow FH sample demodulation requires hopInfo.freqOffsets.");
end

hopLenSamples = round(double(hopInfo.hopLenSamples));
if hopLenSamples < 1
    error("slow FH sample demodulation requires hopLenSamples >= 1.");
end
nSample = numel(segIn);
nHops = ceil(double(nSample) / double(hopLenSamples));
freqOffsets = double(hopInfo.freqOffsets(:));
if numel(freqOffsets) < nHops
    error("slow FH sample demodulation needs %d hop frequencies, got %d.", nHops, numel(freqOffsets));
end

phaseRotFull = conj(fh_phase_sequence_samples(freqOffsets, hopLenSamples, nSample, waveform));
overlap = local_fh_preselect_overlap_samples_local(waveform);

for hopIdx = 1:nHops
    coreStart = (hopIdx - 1) * hopLenSamples + 1;
    coreStop = min(nSample, hopIdx * hopLenSamples);
    winStart = max(1, coreStart - overlap);
    winStop = min(nSample, coreStop + overlap);
    win = segIn(winStart:winStop);
    win = local_band_select_samples_local(win, freqOffsets(hopIdx), waveform);
    win = win .* phaseRotFull(winStart:winStop);
    coreRange = (coreStart:coreStop) - winStart + 1;
    segOut(coreStart:coreStop) = win(coreRange);
end
end

function overlap = local_fh_preselect_overlap_samples_local(waveform)
if ~(isstruct(waveform) && isfield(waveform, "enable") && waveform.enable)
    overlap = 0;
    return;
end
if ~(isfield(waveform, "rrcTaps") && ~isempty(waveform.rrcTaps))
    error("waveform.rrcTaps is required for FH sample preselection.");
end
overlap = max(0, round(double(numel(waveform.rrcTaps))));
end

function y = local_band_select_samples_local(x, centerFreqRs, waveform)
x = x(:);
if isempty(x)
    y = x;
    return;
end
if ~(isstruct(waveform) && isfield(waveform, "enable") && waveform.enable)
    y = x;
    return;
end
if ~(isfield(waveform, "sps") && isfinite(double(waveform.sps)) && double(waveform.sps) > 0)
    error("waveform.sps must be a positive finite scalar for FH sample preselection.");
end
if ~(isfield(waveform, "rolloff") && isfinite(double(waveform.rolloff)) && double(waveform.rolloff) >= 0)
    error("waveform.rolloff must be a nonnegative finite scalar for FH sample preselection.");
end

sps = double(waveform.sps);
centerNorm = double(centerFreqRs) / sps;
halfWidthNorm = (1 + double(waveform.rolloff)) / (2 * sps);
if ~(isfinite(centerNorm) && isfinite(halfWidthNorm) && halfWidthNorm > 0)
    error("FH sample preselection requires finite center frequency and positive channel width.");
end

n = numel(x);
f = ((0:n-1).' / n) - 0.5;
dist = abs(mod(f - centerNorm + 0.5, 1.0) - 0.5);
mask = double(dist <= halfWidthNorm);
X = fftshift(fft(x));
y = ifft(ifftshift(X .* mask));
end

function value = local_fast_fh_capture_scalar_local(fhCaptureCfg, fieldName)
if ~(isfield(fhCaptureCfg, fieldName) && ~isempty(fhCaptureCfg.(fieldName)))
    error("fhCaptureCfg.%s is required for sample-domain FH capture.", fieldName);
end
value = round(double(fhCaptureCfg.(fieldName)));
if ~(isscalar(value) && isfinite(value) && value >= 0)
    error("fhCaptureCfg.%s must be a nonnegative finite scalar.", fieldName);
end
end

function nSample = local_packet_sample_length_local(nSym, waveform)
nSym = max(0, round(double(nSym)));
if ~waveform.enable
    nSample = nSym;
    return;
end
nSample = (nSym - 1) * round(double(waveform.sps)) + numel(waveform.rrcTaps);
end

function startSample = local_packet_raw_start_sample_local(startIdx, waveform, stageSps)
startIdx = double(startIdx);
if ~(isfinite(startIdx) && startIdx >= 1)
    startSample = NaN;
    return;
end
if ~(isstruct(waveform) && isfield(waveform, "enable") && logical(waveform.enable))
    startSample = startIdx;
    return;
end
stageSps = max(1, round(double(stageSps)));
decim = round(double(waveform.sps) / double(stageSps));
startSample = 1 + (startIdx - 1) * double(decim);
end

function sampleIdx = local_symbol_boundary_sample_index_local(nLeadingSym, waveform)
nLeadingSym = max(0, round(double(nLeadingSym)));
sampleIdx = nLeadingSym * round(double(waveform.sps)) + 1;
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
[rComp, compInfo] = local_apply_symbol_block_sync_compensation_window_local( ...
    rSym, syncSymRef, syncCfgUse, 1);
end

function [rComp, compInfo] = local_apply_symbol_block_sync_compensation_window_local(rSym, syncSymRef, syncCfgUse, segStartIdx)
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
if nargin < 4 || isempty(segStartIdx)
    segStartIdx = 1;
end
segStartIdx = max(1, round(double(segStartIdx)));
if segStartIdx > numel(rSym)
    return;
end

if ~isfield(syncCfgUse, "compensateCarrier") || ~logical(syncCfgUse.compensateCarrier)
    return;
end

segStopIdx = min(numel(rSym), segStartIdx + numel(syncSymRef) - 1);
pre = rSym(segStartIdx:segStopIdx);
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
    [cfoRad, phiHatLocal] = local_estimate_cfo_phase_local(pre, syncRefUse, symAxis);
    phiHat = phiHatLocal - cfoRad * double(segStartIdx - 1);
    rComp = rSym .* exp(-1j * (cfoRad * (0:numel(rSym)-1).' + phiHat));
end

preComp = rComp(segStartIdx:segStartIdx + numel(syncRefUse) - 1);
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

function tf = local_preamble_diversity_enabled_local(fhCaptureCfg)
tf = false;
if ~(isstruct(fhCaptureCfg) && isfield(fhCaptureCfg, "preambleFhCfg") ...
        && isstruct(fhCaptureCfg.preambleFhCfg))
    return;
end
pf = fhCaptureCfg.preambleFhCfg;
if ~(isfield(pf, "enable") && logical(pf.enable))
    return;
end
if ~(isfield(pf, "nFreqs") && ~isempty(pf.nFreqs) && double(pf.nFreqs) >= 1)
    return;
end
if ~(isfield(pf, "freqSet") && ~isempty(pf.freqSet))
    return;
end
if ~(isfield(pf, "symbolsPerHop") && ~isempty(pf.symbolsPerHop))
    return;
end
tf = true;
end

function front = local_capture_with_preamble_diversity_local( ...
    rxSampleRaw, syncSymRef, totalLen, syncCfgUse, mitigation, modCfg, waveform, ...
    sampleAction, bootstrapChain, fhCaptureCfg, syncStageSps, front)
% Multi-frequency preamble diversity capture. The long preamble was split
% into K copies, each on a different FH frequency. Search at each known
% frequency, pick the strongest peak as the winner, then snap to packet
% start and run the normal extraction on the non-rotated stream (letting
% local_apply_fast_fh_packet_demod_local dehop all three regions).

rxSampleRaw = rxSampleRaw(:);
syncSymRef = syncSymRef(:);

preambleFhCfg = fhCaptureCfg.preambleFhCfg;
K = max(1, round(double(preambleFhCfg.nFreqs)));
freqSet = double(preambleFhCfg.freqSet(:).');
if numel(freqSet) < K
    return;
end
copyLenSym = max(1, round(double(preambleFhCfg.symbolsPerHop)));

if numel(syncSymRef) < copyLenSym
    return;
end
singleCopyRef = syncSymRef(1:copyLenSym);

stageTotalLenSingle = local_stage_symbol_sequence_length_local(copyLenSym, syncStageSps);
syncRefStageSingle = local_sync_reference_stage_local(singleCopyRef, waveform, syncStageSps);
syncCfgStage = local_sync_cfg_for_stage_local(syncCfgUse, syncStageSps);
syncCfgStageSearch = syncCfgStage;
copyLenStage = round(double(copyLenSym) * double(syncStageSps));
if isfield(syncCfgStageSearch, "maxSearchIndex") && isfinite(double(syncCfgStageSearch.maxSearchIndex))
    syncCfgStageSearch.maxSearchIndex = double(syncCfgStageSearch.maxSearchIndex) + ...
        double(K - 1) * double(copyLenStage);
end

sps = max(1, round(double(waveform.sps)));
nSample = numel(rxSampleRaw);
nAbs = (0:nSample-1).';

bestPeak = -inf;
bestK = 0;
bestCapture = struct('ok', false);
bestPacketStart = NaN;
bestWinnerStartIdxStage = NaN;
bestWinnerStartIdxFinal = NaN;
bestWinnerSyncInfoStage = struct();
bestTimingInfo = struct();
rxStageByFreq = cell(K, 1);
candidateList = repmat(struct( ...
    'k', 0, ...
    'capture', struct('ok', false), ...
    'packetStart', NaN, ...
    'winnerStartIdxStage', NaN, ...
    'winnerStartIdxFinal', NaN, ...
    'winnerSyncInfoStage', struct(), ...
    'timingInfo', struct()), 0, 1);

for k = 1:K
    fk = double(freqSet(k));
    rxBand = local_band_select_samples_local(rxSampleRaw, fk, waveform);
    phaseRot = exp(-1j * 2 * pi * fk * nAbs / sps);
    rxRot = rxBand .* phaseRot;

    [rxStageK, ~, ~, ~] = local_sync_stage_observation_from_samples_local( ...
        rxRot, waveform, sampleAction, mitigation, syncStageSps);
    rxStageByFreq{k} = rxStageK;

    captureK = adaptive_frontend_bootstrap_capture( ...
        rxStageK, syncRefStageSingle, stageTotalLenSingle, syncCfgStageSearch, mitigation, modCfg, bootstrapChain);
    if ~captureK.ok
        continue;
    end

    fineSearchRadiusStage = 0;
    if isfield(syncCfgStage, "fineSearchRadius") && ~isempty(syncCfgStage.fineSearchRadius)
        fineSearchRadiusStage = round(double(syncCfgStage.fineSearchRadius));
    end
    searchRadiusWinner = max([8 * syncStageSps, round(numel(syncRefStageSingle) / 4), ...
        fineSearchRadiusStage + 4 * syncStageSps]);
    if isfield(syncCfgStage, "maxSearchIndex") && isfinite(double(syncCfgStage.maxSearchIndex))
        searchRadiusWinner = min(searchRadiusWinner, max(4 * syncStageSps, round(double(syncCfgStage.maxSearchIndex))));
    end

    [winnerStartIdxStageK, winnerSyncInfoStageK] = local_refine_stage_capture_local( ...
        captureK.rxSync, syncRefStageSingle, captureK.startIdx, syncCfgStage, searchRadiusWinner);
    if isempty(winnerStartIdxStageK) || ~isfinite(winnerStartIdxStageK)
        continue;
    end

    [winnerStartIdxFinalK, timingInfoK] = local_estimate_symbol_timing_from_stage_local( ...
        captureK.rxSync, winnerStartIdxStageK, singleCopyRef, syncCfgUse, modCfg, syncStageSps);
    if isempty(winnerStartIdxFinalK) || ~isfinite(winnerStartIdxFinalK)
        continue;
    end

    packetStartCandidate = double(winnerStartIdxFinalK) - (double(k) - 1) * double(copyLenStage);
    if ~isfinite(packetStartCandidate) || packetStartCandidate < 1
        continue;
    end

    candidateList(end + 1, 1) = struct( ...
        'k', k, ...
        'capture', captureK, ...
        'packetStart', packetStartCandidate, ...
        'winnerStartIdxStage', winnerStartIdxStageK, ...
        'winnerStartIdxFinal', winnerStartIdxFinalK, ...
        'winnerSyncInfoStage', winnerSyncInfoStageK, ...
        'timingInfo', timingInfoK); %#ok<AGROW>
end

for candidateIdx = 1:numel(candidateList)
    candidate = candidateList(candidateIdx);
    peakK = local_score_preamble_diversity_packet_start_local( ...
        candidate.packetStart, rxStageByFreq, syncRefStageSingle, syncCfgUse, modCfg, syncStageSps, copyLenStage);
    if ~(isfinite(peakK))
        continue;
    end
    if peakK > bestPeak
        bestPeak = peakK;
        bestK = candidate.k;
        bestCapture = candidate.capture;
        bestPacketStart = candidate.packetStart;
        bestWinnerStartIdxStage = candidate.winnerStartIdxStage;
        bestWinnerStartIdxFinal = candidate.winnerStartIdxFinal;
        bestWinnerSyncInfoStage = candidate.winnerSyncInfoStage;
        bestTimingInfo = candidate.timingInfo;
    end
end

if ~isstruct(bestCapture) || ~(isfield(bestCapture, 'ok') && bestCapture.ok) || bestK < 1 ...
        || ~(isfinite(bestPacketStart))
    return;
end

[rxStageOrig, rawReliability, rxPrep, relSamplePrep] = local_sync_stage_observation_from_samples_local( ...
    rxSampleRaw, waveform, sampleAction, mitigation, syncStageSps);

captureMock = bestCapture;
captureMock.ok = true;
captureMock.startIdx = bestPacketStart;
captureMock.rxSync = rxStageOrig;
captureMock.reliabilityTrack = rawReliability;

[rFull, reliabilityFull, okFull] = local_extract_symbol_block_local( ...
    captureMock, rawReliability, rxPrep, relSamplePrep, bestPacketStart, totalLen, ...
    fhCaptureCfg, syncCfgUse, mitigation, modCfg, waveform, syncStageSps);
if ~okFull
    return;
end

winnerCopyStartSym = (bestK - 1) * copyLenSym + 1;
[rFull, syncCompInfo] = local_apply_symbol_block_sync_compensation_window_local( ...
    rFull, singleCopyRef, syncCfgUse, winnerCopyStartSym);
syncInfo = local_merge_stage_sync_info_local(bestWinnerSyncInfoStage, bestTimingInfo, syncCompInfo, ...
    bestWinnerStartIdxStage, bestPacketStart, syncStageSps);
syncInfo.preambleDiversityCopyIndex = double(bestK);
syncInfo.preambleDiversityCorrPeak = double(bestPeak);
syncInfo.preambleDiversityCopies = double(K);
syncInfo.preambleDiversityWinnerStartIdx = double(bestWinnerStartIdxFinal);

front.ok = true;
front.startIdx = bestPacketStart;
front.syncInfo = syncInfo;
front.rxSync = rxStageOrig;
front.rFull = rFull;
front.reliabilityFull = local_fit_reliability_length_local(reliabilityFull, totalLen);
front.rxPrepForCapture = rxPrep;
front.relSamplePrepForCapture = relSamplePrep;
front.syncStageSps = double(syncStageSps);
front.bootstrapPath = string(bestCapture.bootstrapPath);
front.bootstrapCapture = bestCapture;
end

function score = local_score_preamble_diversity_packet_start_local( ...
    packetStartStage, rxStageByFreq, syncRefStageSingle, syncCfgUse, modCfg, syncStageSps, copyLenStage)
score = -inf;
if ~(isfinite(packetStartStage) && packetStartStage >= 1)
    return;
end
if isempty(rxStageByFreq)
    return;
end

copyLenStage = round(double(copyLenStage));
if copyLenStage < 1
    error("Preamble-diversity packet-start scoring requires copyLenStage >= 1.");
end

scoreNow = 0;
for k = 1:numel(rxStageByFreq)
    rxStageK = rxStageByFreq{k};
    if isempty(rxStageK)
        return;
    end
    startK = double(packetStartStage) + double(k - 1) * double(copyLenStage);
    [segK, okSeg] = extract_fractional_block(rxStageK, startK, numel(syncRefStageSingle), ...
        local_symbol_extract_sync_cfg_local(syncCfgUse), modCfg, syncStageSps);
    if ~okSeg
        return;
    end

    if isfield(syncCfgUse, "estimateCfo") && logical(syncCfgUse.estimateCfo)
        symAxis = (0:numel(syncRefStageSingle)-1).';
        [wTmp, phiTmp] = local_estimate_cfo_phase_local(segK, syncRefStageSingle, symAxis);
        segUse = segK .* exp(-1j * (wTmp * symAxis + phiTmp));
    else
        segUse = segK;
    end
    scoreNow = scoreNow + abs(sum(segUse .* conj(syncRefStageSingle)));
end

score = double(scoreNow);
end
