function dataset = ml_generate_impulse_blocks(p, nBlocks, blockLen, ebN0dBRange, opts)
%ML_GENERATE_IMPULSE_BLOCKS  生成面向采样级脉冲抑制的训练/验证/测试窗口。
arguments
    p (1,1) struct
    nBlocks (1,1) double {mustBeInteger, mustBePositive}
    blockLen (1,1) double {mustBeInteger, mustBePositive}
    ebN0dBRange (1,2) double
    opts.labelScoreThreshold (1,1) double {mustBePositive} = 0.1
    opts.impulseEnableProbability (1,1) double = 1.0
    opts.impulseProbRange (1,2) double = [NaN NaN]
    opts.impulseToBgRatioRange (1,2) double = [NaN NaN]
    opts.singleToneProbability (1,1) double = 0.0
    opts.singleTonePowerRange (1,2) double = [NaN NaN]
    opts.singleToneFreqHzRange (1,2) double = [NaN NaN]
    opts.narrowbandProbability (1,1) double = 0.0
    opts.narrowbandPowerRange (1,2) double = [NaN NaN]
    opts.narrowbandCenterHzRange (1,2) double = [NaN NaN]
    opts.narrowbandBandwidthHzRange (1,2) double = [NaN NaN]
    opts.sweepProbability (1,1) double = 0.0
    opts.sweepPowerRange (1,2) double = [NaN NaN]
    opts.sweepStartHzRange (1,2) double = [NaN NaN]
    opts.sweepStopHzRange (1,2) double = [NaN NaN]
    opts.sweepPeriodSymbolsRange (1,2) double = [NaN NaN]
    opts.syncImpairmentProbability (1,1) double = 0.0
    opts.timingOffsetSymbolsRange (1,2) double = [NaN NaN]
    opts.phaseOffsetRadRange (1,2) double = [NaN NaN]
    opts.multipathProbability (1,1) double = 0.0
    opts.multipathRayleighProbability (1,1) double = 0.5
    opts.maxAdditionalImpairments (1,1) double {mustBeInteger, mustBeNonnegative} = 2
end

[~, modInfo] = modulate_bits(uint8([0; 1]), p.mod, p.fec);
modInfo.spreadFactor = dsss_effective_spread_factor(p.dsss);
codeRate = modInfo.codeRate / modInfo.spreadFactor;
bitsPerSym = modInfo.bitsPerSymbol;
Es = 1.0;
waveform = resolve_waveform_cfg(p);
sampleRateHz = waveform.sampleRateHz;
sampler = local_build_channel_sampler(p, sampleRateHz, opts);

dataset = struct();
dataset.domain = "raw_samples";
dataset.nBlocks = nBlocks;
dataset.blockLen = blockLen;
dataset.sampleWindowLen = blockLen;
dataset.ebN0dBRange = ebN0dBRange;
dataset.ebN0dBPerBlock = zeros(nBlocks, 1);
dataset.impulseProbPerBlock = zeros(nBlocks, 1);
dataset.impulseToBgRatioPerBlock = zeros(nBlocks, 1);
dataset.txClean = cell(nBlocks, 1);
dataset.rxInput = cell(nBlocks, 1);
dataset.impulseScore = cell(nBlocks, 1);
dataset.impMask = cell(nBlocks, 1);
dataset.labelPositiveRate = zeros(nBlocks, 1);
dataset.labeling = struct( ...
    "mode", "score_threshold", ...
    "scoreThreshold", opts.labelScoreThreshold);
dataset.channelSampling = sampler.summary;
dataset.channelProfile = local_allocate_channel_profile(nBlocks);

for b = 1:nBlocks
    ebN0dB = ebN0dBRange(1) + rand() * diff(ebN0dBRange);
    dataset.ebN0dBPerBlock(b) = ebN0dB;
    EbN0 = 10.^(ebN0dB / 10);
    N0 = ebn0_to_n0(EbN0, codeRate, bitsPerSym, Es);

    [pBlock, blockProfile] = local_sample_block_channel(p, sampler);
    dataset.impulseProbPerBlock(b) = pBlock.channel.impulseProb;
    dataset.impulseToBgRatioPerBlock(b) = pBlock.channel.impulseToBgRatio;
    dataset.channelProfile = local_store_channel_profile(dataset.channelProfile, b, blockProfile);

    nTrainSymbols = local_training_symbol_count_for_sample_window(pBlock, blockLen, waveform);
    bits = randi([0 1], nTrainSymbols * bitsPerSym, 1, 'uint8');
    txSym = modulate_bits(bits, p.mod);
    [txClean, rxInput, ~, impScore] = ml_simulate_training_chain(txSym, pBlock, N0, blockLen);
    impMask = impScore >= opts.labelScoreThreshold;

    dataset.txClean{b} = txClean;
    dataset.rxInput{b} = rxInput;
    dataset.impulseScore{b} = impScore;
    dataset.impMask{b} = logical(impMask ~= 0);
    dataset.labelPositiveRate(b) = mean(double(dataset.impMask{b}));
end
dataset.channelProfileSummary = local_summarize_channel_profile(dataset.channelProfile);
end

function nTrainSymbols = local_training_symbol_count_for_sample_window(p, sampleWindowLen, waveform)
sampleWindowLen = round(double(sampleWindowLen));
if ~(sampleWindowLen > 0)
    error("sampleWindowLen 必须为正整数。");
end

sps = double(waveform.sps);
if ~(isfinite(sps) && sps >= 1)
    error("waveform.sps 无效，无法按采样窗口长度生成训练符号。");
end

groupDelay = 0;
if isfield(waveform, "groupDelaySamples") && ~isempty(waveform.groupDelaySamples)
    groupDelay = max(0, round(double(waveform.groupDelaySamples)));
end

spreadFactor = dsss_effective_spread_factor(p.dsss);
channelSymbolsNeeded = ceil((sampleWindowLen + 2 * groupDelay + 8 * sps) / sps);
nTrainSymbols = ceil(channelSymbolsNeeded / max(spreadFactor, 1));
nTrainSymbols = max(nTrainSymbols, 64);
end

function sampler = local_build_channel_sampler(p, sampleRateHz, opts)
freqLimit = 0.499 * sampleRateHz;

sampler = struct();
sampler.sampleRateHz = sampleRateHz;
sampler.impulseEnableProbability = local_validate_probability(opts.impulseEnableProbability, "impulseEnableProbability");
sampler.impulseProbRange = local_resolve_range(double(p.channel.impulseProb), opts.impulseProbRange, ...
    "impulseProbRange", 0, 1);
sampler.impulseToBgRatioRange = local_resolve_range(double(p.channel.impulseToBgRatio), opts.impulseToBgRatioRange, ...
    "impulseToBgRatioRange", 0, inf);

sampler.singleToneProbability = local_validate_probability(opts.singleToneProbability, "singleToneProbability");
sampler.singleTonePowerRange = local_resolve_range(0.01, opts.singleTonePowerRange, ...
    "singleTonePowerRange", 0, inf);
sampler.singleToneFreqHzRange = local_resolve_range(double(p.channel.singleTone.freqHz), opts.singleToneFreqHzRange, ...
    "singleToneFreqHzRange", -freqLimit, freqLimit);

sampler.narrowbandProbability = local_validate_probability(opts.narrowbandProbability, "narrowbandProbability");
sampler.narrowbandPowerRange = local_resolve_range(0.1, opts.narrowbandPowerRange, ...
    "narrowbandPowerRange", 0, inf);
sampler.narrowbandCenterHzRange = local_resolve_range(double(p.channel.narrowband.centerHz), opts.narrowbandCenterHzRange, ...
    "narrowbandCenterHzRange", -freqLimit, freqLimit);
sampler.narrowbandBandwidthHzRange = local_resolve_range(double(p.channel.narrowband.bandwidthHz), opts.narrowbandBandwidthHzRange, ...
    "narrowbandBandwidthHzRange", 1e-6, sampleRateHz);

sampler.sweepProbability = local_validate_probability(opts.sweepProbability, "sweepProbability");
sampler.sweepPowerRange = local_resolve_range(0.01, opts.sweepPowerRange, ...
    "sweepPowerRange", 0, inf);
sampler.sweepStartHzRange = local_resolve_range(double(p.channel.sweep.startHz), opts.sweepStartHzRange, ...
    "sweepStartHzRange", -freqLimit, freqLimit);
sampler.sweepStopHzRange = local_resolve_range(double(p.channel.sweep.stopHz), opts.sweepStopHzRange, ...
    "sweepStopHzRange", -freqLimit, freqLimit);
if sampler.sweepStartHzRange(2) >= sampler.sweepStopHzRange(1)
    error("sweepStartHzRange 必须整体小于 sweepStopHzRange，避免训练采样到倒扫或零跨度扫频。");
end
sampler.sweepPeriodSymbolsRange = local_resolve_range(double(p.channel.sweep.periodSymbols), opts.sweepPeriodSymbolsRange, ...
    "sweepPeriodSymbolsRange", 2, inf);

sampler.syncImpairmentProbability = local_validate_probability(opts.syncImpairmentProbability, "syncImpairmentProbability");
sampler.timingOffsetSymbolsRange = local_resolve_unbounded_range(double(p.channel.syncImpairment.timingOffsetSymbols), ...
    opts.timingOffsetSymbolsRange, "timingOffsetSymbolsRange");
sampler.phaseOffsetRadRange = local_resolve_unbounded_range(double(p.channel.syncImpairment.phaseOffsetRad), ...
    opts.phaseOffsetRadRange, "phaseOffsetRadRange");

sampler.multipathProbability = local_validate_probability(opts.multipathProbability, "multipathProbability");
sampler.multipathRayleighProbability = local_validate_probability(opts.multipathRayleighProbability, "multipathRayleighProbability");
sampler.maxAdditionalImpairments = double(opts.maxAdditionalImpairments);

sampler.summary = struct( ...
    "sampleRateHz", sampleRateHz, ...
    "impulseEnableProbability", sampler.impulseEnableProbability, ...
    "impulseProbRange", sampler.impulseProbRange, ...
    "impulseToBgRatioRange", sampler.impulseToBgRatioRange, ...
    "singleToneProbability", sampler.singleToneProbability, ...
    "singleTonePowerRange", sampler.singleTonePowerRange, ...
    "singleToneFreqHzRange", sampler.singleToneFreqHzRange, ...
    "narrowbandProbability", sampler.narrowbandProbability, ...
    "narrowbandPowerRange", sampler.narrowbandPowerRange, ...
    "narrowbandCenterHzRange", sampler.narrowbandCenterHzRange, ...
    "narrowbandBandwidthHzRange", sampler.narrowbandBandwidthHzRange, ...
    "sweepProbability", sampler.sweepProbability, ...
    "sweepPowerRange", sampler.sweepPowerRange, ...
    "sweepStartHzRange", sampler.sweepStartHzRange, ...
    "sweepStopHzRange", sampler.sweepStopHzRange, ...
    "sweepPeriodSymbolsRange", sampler.sweepPeriodSymbolsRange, ...
    "syncImpairmentProbability", sampler.syncImpairmentProbability, ...
    "timingOffsetSymbolsRange", sampler.timingOffsetSymbolsRange, ...
    "phaseOffsetRadRange", sampler.phaseOffsetRadRange, ...
    "multipathProbability", sampler.multipathProbability, ...
    "multipathRayleighProbability", sampler.multipathRayleighProbability, ...
    "maxAdditionalImpairments", sampler.maxAdditionalImpairments);
end

function [pBlock, profile] = local_sample_block_channel(p, sampler)
pBlock = p;

profile = struct( ...
    "impulseEnable", false, ...
    "impulseProb", 0, ...
    "impulseToBgRatio", 0, ...
    "singleToneEnable", false, ...
    "singleTonePower", NaN, ...
    "singleToneFreqHz", NaN, ...
    "narrowbandEnable", false, ...
    "narrowbandPower", NaN, ...
    "narrowbandCenterHz", NaN, ...
    "narrowbandBandwidthHz", NaN, ...
    "sweepEnable", false, ...
    "sweepPower", NaN, ...
    "sweepStartHz", NaN, ...
    "sweepStopHz", NaN, ...
    "sweepPeriodSymbols", NaN, ...
    "syncImpairmentEnable", false, ...
    "timingOffsetSymbols", 0, ...
    "phaseOffsetRad", 0, ...
    "multipathEnable", false, ...
    "multipathRayleigh", false, ...
    "activeExtraCount", 0, ...
    "cleanBlock", false);

pBlock.channel.impulseProb = 0;
pBlock.channel.impulseToBgRatio = 0;
profile.impulseEnable = rand() < sampler.impulseEnableProbability;
if profile.impulseEnable
    pBlock.channel.impulseProb = local_sample_uniform(sampler.impulseProbRange);
    pBlock.channel.impulseToBgRatio = local_sample_uniform(sampler.impulseToBgRatioRange);
end
profile.impulseProb = pBlock.channel.impulseProb;
profile.impulseToBgRatio = pBlock.channel.impulseToBgRatio;

extraFlags = [ ...
    rand() < sampler.singleToneProbability; ...
    rand() < sampler.narrowbandProbability; ...
    rand() < sampler.sweepProbability; ...
    rand() < sampler.syncImpairmentProbability; ...
    rand() < sampler.multipathProbability];
if nnz(extraFlags) > sampler.maxAdditionalImpairments
    activeIdx = find(extraFlags);
    dropOrder = activeIdx(randperm(numel(activeIdx)));
    extraFlags(dropOrder(sampler.maxAdditionalImpairments+1:end)) = false;
end
profile.activeExtraCount = nnz(extraFlags);

pBlock.channel.singleTone.enable = false;
if extraFlags(1)
    pBlock.channel.singleTone.enable = true;
    pBlock.channel.singleTone.power = local_sample_uniform(sampler.singleTonePowerRange);
    pBlock.channel.singleTone.freqHz = local_sample_uniform(sampler.singleToneFreqHzRange);
    profile.singleToneEnable = true;
    profile.singleTonePower = pBlock.channel.singleTone.power;
    profile.singleToneFreqHz = pBlock.channel.singleTone.freqHz;
end

pBlock.channel.narrowband.enable = false;
if extraFlags(2)
    pBlock.channel.narrowband.enable = true;
    pBlock.channel.narrowband.power = local_sample_uniform(sampler.narrowbandPowerRange);
    pBlock.channel.narrowband.centerHz = local_sample_uniform(sampler.narrowbandCenterHzRange);
    pBlock.channel.narrowband.bandwidthHz = local_sample_uniform(sampler.narrowbandBandwidthHzRange);
    profile.narrowbandEnable = true;
    profile.narrowbandPower = pBlock.channel.narrowband.power;
    profile.narrowbandCenterHz = pBlock.channel.narrowband.centerHz;
    profile.narrowbandBandwidthHz = pBlock.channel.narrowband.bandwidthHz;
end

pBlock.channel.sweep.enable = false;
if extraFlags(3)
    pBlock.channel.sweep.enable = true;
    pBlock.channel.sweep.power = local_sample_uniform(sampler.sweepPowerRange);
    pBlock.channel.sweep.startHz = local_sample_uniform(sampler.sweepStartHzRange);
    pBlock.channel.sweep.stopHz = local_sample_uniform(sampler.sweepStopHzRange);
    pBlock.channel.sweep.periodSymbols = local_sample_integer(sampler.sweepPeriodSymbolsRange);
    profile.sweepEnable = true;
    profile.sweepPower = pBlock.channel.sweep.power;
    profile.sweepStartHz = pBlock.channel.sweep.startHz;
    profile.sweepStopHz = pBlock.channel.sweep.stopHz;
    profile.sweepPeriodSymbols = pBlock.channel.sweep.periodSymbols;
end

pBlock.channel.syncImpairment.enable = false;
pBlock.channel.syncImpairment.timingOffsetSymbols = 0;
pBlock.channel.syncImpairment.phaseOffsetRad = 0;
if extraFlags(4)
    pBlock.channel.syncImpairment.enable = true;
    pBlock.channel.syncImpairment.timingOffsetSymbols = local_sample_uniform(sampler.timingOffsetSymbolsRange);
    pBlock.channel.syncImpairment.phaseOffsetRad = local_sample_uniform(sampler.phaseOffsetRadRange);
    profile.syncImpairmentEnable = true;
    profile.timingOffsetSymbols = pBlock.channel.syncImpairment.timingOffsetSymbols;
    profile.phaseOffsetRad = pBlock.channel.syncImpairment.phaseOffsetRad;
end

pBlock.channel.multipath.enable = false;
pBlock.channel.multipath.rayleigh = false;
if extraFlags(5)
    pBlock.channel.multipath.enable = true;
    pBlock.channel.multipath.rayleigh = rand() < sampler.multipathRayleighProbability;
    profile.multipathEnable = true;
    profile.multipathRayleigh = pBlock.channel.multipath.rayleigh;
end

profile.cleanBlock = ~(profile.impulseEnable || profile.activeExtraCount > 0);
end

function rangeOut = local_resolve_range(defaultValue, requestedRange, rangeName, minAllowed, maxAllowed)
requestedRange = double(requestedRange(:).');
if all(isnan(requestedRange))
    rangeOut = [defaultValue, defaultValue];
else
    if numel(requestedRange) ~= 2 || any(~isfinite(requestedRange))
        error("%s 必须是长度为2的有限数值范围。", rangeName);
    end
    lo = requestedRange(1);
    hi = requestedRange(2);
    if lo > hi
        error("%s 的下界不能大于上界。", rangeName);
    end
    if lo < minAllowed || hi > maxAllowed
        error("%s 超出允许范围 [%.4g, %.4g]。", rangeName, minAllowed, maxAllowed);
    end
    rangeOut = [lo, hi];
end
end

function rangeOut = local_resolve_unbounded_range(defaultValue, requestedRange, rangeName)
requestedRange = double(requestedRange(:).');
if all(isnan(requestedRange))
    rangeOut = [defaultValue, defaultValue];
    return;
end
if numel(requestedRange) ~= 2 || any(~isfinite(requestedRange))
    error("%s 必须是长度为2的有限数值范围。", rangeName);
end
lo = requestedRange(1);
hi = requestedRange(2);
if lo > hi
    error("%s 的下界不能大于上界。", rangeName);
end
rangeOut = [lo, hi];
end

function value = local_sample_uniform(valueRange)
valueRange = double(valueRange(:).');
if valueRange(1) == valueRange(2)
    value = valueRange(1);
else
    value = valueRange(1) + rand() * diff(valueRange);
end
end

function value = local_sample_integer(valueRange)
valueRange = round(double(valueRange(:).'));
if valueRange(1) > valueRange(2)
    error("整数范围下界不能大于上界。");
end
if valueRange(1) == valueRange(2)
    value = valueRange(1);
else
    value = randi([valueRange(1), valueRange(2)], 1, 1);
end
end

function value = local_validate_probability(value, name)
value = double(value);
if ~isfinite(value) || value < 0 || value > 1
    error("%s 必须在 [0,1] 范围内。", name);
end
end

function profileSet = local_allocate_channel_profile(nBlocks)
profileSet = struct( ...
    "impulseEnable", false(nBlocks, 1), ...
    "impulseProb", zeros(nBlocks, 1), ...
    "impulseToBgRatio", zeros(nBlocks, 1), ...
    "singleToneEnable", false(nBlocks, 1), ...
    "singleTonePower", nan(nBlocks, 1), ...
    "singleToneFreqHz", nan(nBlocks, 1), ...
    "narrowbandEnable", false(nBlocks, 1), ...
    "narrowbandPower", nan(nBlocks, 1), ...
    "narrowbandCenterHz", nan(nBlocks, 1), ...
    "narrowbandBandwidthHz", nan(nBlocks, 1), ...
    "sweepEnable", false(nBlocks, 1), ...
    "sweepPower", nan(nBlocks, 1), ...
    "sweepStartHz", nan(nBlocks, 1), ...
    "sweepStopHz", nan(nBlocks, 1), ...
    "sweepPeriodSymbols", nan(nBlocks, 1), ...
    "syncImpairmentEnable", false(nBlocks, 1), ...
    "timingOffsetSymbols", zeros(nBlocks, 1), ...
    "phaseOffsetRad", zeros(nBlocks, 1), ...
    "multipathEnable", false(nBlocks, 1), ...
    "multipathRayleigh", false(nBlocks, 1), ...
    "activeExtraCount", zeros(nBlocks, 1), ...
    "cleanBlock", false(nBlocks, 1));
end

function profileSet = local_store_channel_profile(profileSet, idx, blockProfile)
fieldNames = string(fieldnames(profileSet));
for k = 1:numel(fieldNames)
    name = fieldNames(k);
    profileSet.(name)(idx) = blockProfile.(name);
end
end

function summary = local_summarize_channel_profile(profile)
summary = struct();
summary.nBlocks = numel(profile.impulseEnable);
summary.cleanBlocks = nnz(profile.cleanBlock);
summary.cleanRate = mean(double(profile.cleanBlock));
summary.impulseBlocks = nnz(profile.impulseEnable);
summary.singleToneBlocks = nnz(profile.singleToneEnable);
summary.narrowbandBlocks = nnz(profile.narrowbandEnable);
summary.sweepBlocks = nnz(profile.sweepEnable);
summary.syncImpairmentBlocks = nnz(profile.syncImpairmentEnable);
summary.multipathBlocks = nnz(profile.multipathEnable);
summary.rayleighBlocks = nnz(profile.multipathRayleigh);
summary.extraImpairmentBlocks = nnz(profile.activeExtraCount > 0);
summary.mixedExtraBlocks = nnz(profile.activeExtraCount >= 2);
summary.realizedImpulseProbRange = local_realized_range(profile.impulseProb, profile.impulseEnable);
summary.realizedImpulseToBgRatioRange = local_realized_range(profile.impulseToBgRatio, profile.impulseEnable);
summary.realizedSingleTonePowerRange = local_realized_range(profile.singleTonePower, profile.singleToneEnable);
summary.realizedSingleToneFreqHzRange = local_realized_range(profile.singleToneFreqHz, profile.singleToneEnable);
summary.realizedNarrowbandPowerRange = local_realized_range(profile.narrowbandPower, profile.narrowbandEnable);
summary.realizedNarrowbandCenterHzRange = local_realized_range(profile.narrowbandCenterHz, profile.narrowbandEnable);
summary.realizedNarrowbandBandwidthHzRange = local_realized_range(profile.narrowbandBandwidthHz, profile.narrowbandEnable);
summary.realizedSweepPowerRange = local_realized_range(profile.sweepPower, profile.sweepEnable);
summary.realizedSweepStartHzRange = local_realized_range(profile.sweepStartHz, profile.sweepEnable);
summary.realizedSweepStopHzRange = local_realized_range(profile.sweepStopHz, profile.sweepEnable);
summary.realizedSweepPeriodSymbolsRange = local_realized_range(profile.sweepPeriodSymbols, profile.sweepEnable);
summary.realizedTimingOffsetSymbolsRange = local_realized_range(profile.timingOffsetSymbols, profile.syncImpairmentEnable);
summary.realizedPhaseOffsetRadRange = local_realized_range(profile.phaseOffsetRad, profile.syncImpairmentEnable);
end

function rangeOut = local_realized_range(values, mask)
values = double(values(:));
mask = logical(mask(:));
sel = values(mask);
sel = sel(isfinite(sel));
if isempty(sel)
    rangeOut = [NaN NaN];
else
    rangeOut = [min(sel), max(sel)];
end
end
