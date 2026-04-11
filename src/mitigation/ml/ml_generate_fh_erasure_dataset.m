function dataset = ml_generate_fh_erasure_dataset(p, nBlocks, ebN0dBRange, opts)
%ML_GENERATE_FH_ERASURE_DATASET  Generate per-frequency labels for FH erasure.

arguments
    p (1,1) struct
    nBlocks (1,1) double {mustBeInteger, mustBePositive}
    ebN0dBRange (1,2) double
    opts.hopsPerBlockRange (1,2) double {mustBePositive} = [64 256]
    opts.jsrDbRange (1,2) double = [-12 3]
    opts.narrowbandProbability (1,1) double = 0.90
    opts.bandwidthFreqPointsRange (1,2) double {mustBePositive} = [0.6 1.4]
    opts.centerFreqPointsRange (1,2) double = [NaN NaN]
    opts.configuredCenterProbability (1,1) double = 0.35
    opts.minOverlapFraction (1,1) double = 0.15
    opts.badHopErrorRateThreshold (1,1) double = 0.22
    opts.badFreqHopFractionThreshold (1,1) double = 0.35
    opts.badFreqErrorRateThreshold (1,1) double = 0.28
    opts.badFreqErrorExcessThreshold (1,1) double = 0.10
    opts.verbose (1,1) logical = true
end

if ~isfield(p, "fh") || ~isstruct(p.fh) || ~isfield(p.fh, "enable") || ~p.fh.enable
    error("FH-erasure training requires p.fh.enable=true.");
end
if fh_is_fast(p.fh)
    error("FH-erasure training currently targets slow FH only.");
end
if ~(opts.narrowbandProbability >= 0 && opts.narrowbandProbability <= 1)
    error("narrowbandProbability must be in [0, 1].");
end
if ~(opts.minOverlapFraction >= 0 && opts.minOverlapFraction <= 1)
    error("minOverlapFraction must be in [0, 1].");
end
if ~(opts.configuredCenterProbability >= 0 && opts.configuredCenterProbability <= 1)
    error("configuredCenterProbability must be in [0, 1].");
end
if ~(opts.badFreqHopFractionThreshold >= 0 && opts.badFreqHopFractionThreshold <= 1)
    error("badFreqHopFractionThreshold must be in [0, 1].");
end

waveform = resolve_waveform_cfg(p);
hopLen = round(double(p.fh.symbolsPerHop));
nFreqs = round(double(p.fh.nFreqs));
if ~(isscalar(nFreqs) && isfinite(nFreqs) && nFreqs >= 2)
    error("FH-erasure frequency-level training requires p.fh.nFreqs >= 2.");
end
hopsPerBlockRange = round(double(opts.hopsPerBlockRange(:).'));
if hopsPerBlockRange(1) > hopsPerBlockRange(2)
    error("hopsPerBlockRange must be ascending.");
end
maxRows = nBlocks * nFreqs;

featureNames = ml_fh_erasure_freq_feature_names();
classNames = ["good" "bad"];
featureMatrix = zeros(maxRows, numel(featureNames));
labelIndex = zeros(maxRows, 1);
labels = strings(maxRows, 1);
blockIndex = zeros(maxRows, 1);
freqIndex = zeros(maxRows, 1);
ebN0dBPerRow = zeros(maxRows, 1);
jsrDbPerRow = nan(maxRows, 1);
overlapFractionPerFreq = zeros(maxRows, 1);
bitErrorRatePerFreq = zeros(maxRows, 1);
badHopFractionPerFreq = zeros(maxRows, 1);
scenarioPerRow = strings(maxRows, 1);
totalHopCount = 0;

rowCount = 0;
for blockIdx = 1:nBlocks
    nHops = randi(hopsPerBlockRange, 1, 1);
    nSym = hopLen * nHops;
    ebN0dB = ebN0dBRange(1) + rand() * diff(ebN0dBRange);
    N0 = 10^(-ebN0dB / 10);

    txSym = local_random_symbols(nSym, p.mod);
    txSample = pulse_tx_from_symbol_rate(txSym, waveform);
    [txHopped, sampleHopInfo] = fh_modulate_samples(txSample, p.fh, waveform);
    signalPower = mean(abs(txHopped).^2);

    pBlock = local_clean_training_channel(p);
    narrowbandOn = rand() < opts.narrowbandProbability;
    jsrDb = NaN;
    if narrowbandOn
        jsrDb = opts.jsrDbRange(1) + rand() * diff(opts.jsrDbRange);
        pBlock.channel.narrowband.enable = true;
        pBlock.channel.narrowband.power = signalPower * 10^(jsrDb / 10);
        pBlock.channel.narrowband.bandwidthFreqPoints = opts.bandwidthFreqPointsRange(1) ...
            + rand() * diff(opts.bandwidthFreqPointsRange);
        [maxCenterFreqPoints, ~] = narrowband_center_freq_points_limit( ...
            pBlock.fh, waveform, pBlock.channel.narrowband.bandwidthFreqPoints);
        centerRange = local_resolve_center_range(opts.centerFreqPointsRange, maxCenterFreqPoints);
        if rand() < opts.configuredCenterProbability
            pBlock.channel.narrowband.centerFreqPoints = local_configured_center_freq_points(p, maxCenterFreqPoints);
        else
            pBlock.channel.narrowband.centerFreqPoints = centerRange(1) + rand() * diff(centerRange);
        end
        scenarioName = "narrowband";
    else
        scenarioName = "clean";
    end

    channelSample = adapt_channel_for_sps(pBlock.channel, waveform, pBlock.fh);
    rxSample = channel_bg_impulsive(txHopped, N0, channelSample);
    rxDehopped = fh_demodulate_samples(rxSample, sampleHopInfo, waveform);
    rxSym = pulse_rx_to_symbol_rate(rxDehopped, waveform);
    rxSym = local_fit_complex_length(rxSym, nSym);
    hopInfoSym = fh_hop_info_from_cfg(p.fh, nSym);

    [hopFeatures, hopFeatureInfo] = ml_extract_fh_erasure_features(rxSym, hopInfoSym, p.mitigation.fhErasure, p.mod);
    if size(hopFeatures, 1) ~= nHops
        error("FH-erasure feature rows must equal nHops.");
    end
    [freqFeatures, freqFeatureInfo] = ml_extract_fh_erasure_freq_features(hopFeatures, hopFeatureInfo);
    if size(freqFeatures, 1) ~= nFreqs
        error("FH-erasure frequency feature rows must equal nFreqs.");
    end

    overlapFraction = zeros(nHops, 1);
    if narrowbandOn
        overlapFraction = local_narrowband_overlap_fraction( ...
            hopInfoSym, p.fh, waveform, pBlock.channel.narrowband);
    end
    bitErrorRate = local_hop_bit_error_rate(txSym, rxSym, hopLen, p.mod);
    powerRatio = hopFeatures(:, ml_fh_erasure_feature_index("hopPowerRatio"));
    badByError = narrowbandOn ...
        & bitErrorRate >= opts.badHopErrorRateThreshold ...
        & powerRatio >= 0.8 * double(p.mitigation.fhErasure.hopPowerRatioThreshold);
    badHop = (narrowbandOn & overlapFraction >= opts.minOverlapFraction) | badByError;
    eraseFreq = local_frequency_labels( ...
        hopInfoSym.freqIdx(:), nFreqs, narrowbandOn, overlapFraction, bitErrorRate, badHop, opts);

    rows = rowCount + (1:nFreqs);
    featureMatrix(rows, :) = freqFeatures;
    labelIndex(rows) = 1 + double(eraseFreq(:));
    labels(rows) = classNames(labelIndex(rows));
    blockIndex(rows) = blockIdx;
    freqIndex(rows) = freqFeatureInfo.freqIndex;
    ebN0dBPerRow(rows) = ebN0dB;
    jsrDbPerRow(rows) = jsrDb;
    overlapFractionPerFreq(rows) = local_frequency_stat(hopInfoSym.freqIdx(:), nFreqs, overlapFraction, "max");
    bitErrorRatePerFreq(rows) = local_frequency_stat(hopInfoSym.freqIdx(:), nFreqs, bitErrorRate, "mean");
    badHopFractionPerFreq(rows) = local_frequency_stat(hopInfoSym.freqIdx(:), nFreqs, double(badHop), "mean");
    scenarioPerRow(rows) = scenarioName;
    rowCount = rowCount + nFreqs;
    totalHopCount = totalHopCount + nHops;
end

featureMatrix = featureMatrix(1:rowCount, :);
labelIndex = labelIndex(1:rowCount);
labels = labels(1:rowCount);

dataset = struct();
dataset.nBlocks = nBlocks;
dataset.nRows = rowCount;
dataset.nFreqRows = rowCount;
dataset.nHops = totalHopCount;
dataset.ebN0dBRange = ebN0dBRange;
dataset.classNames = classNames;
dataset.featureNames = featureNames;
dataset.featureMatrix = featureMatrix;
dataset.labels = labels;
dataset.labelIndex = labelIndex;
dataset.blockIndex = blockIndex(1:rowCount);
dataset.freqIndex = freqIndex(1:rowCount);
dataset.ebN0dBPerRow = ebN0dBPerRow(1:rowCount);
dataset.jsrDbPerRow = jsrDbPerRow(1:rowCount);
dataset.overlapFractionPerFreq = overlapFractionPerFreq(1:rowCount);
dataset.bitErrorRatePerFreq = bitErrorRatePerFreq(1:rowCount);
dataset.badHopFractionPerFreq = badHopFractionPerFreq(1:rowCount);
dataset.scenarioPerRow = scenarioPerRow(1:rowCount);
dataset.classCounts = accumarray(labelIndex(:), 1, [numel(classNames) 1], @sum, 0);

if opts.verbose
    fprintf("FH-erasure dataset generated: %d blocks, %d frequency rows, bad-frequency rate %.3f.\n", ...
        nBlocks, rowCount, mean(labels == "bad"));
end
end

function eraseFreq = local_frequency_labels(freqIdx, nFreqs, narrowbandOn, overlapFraction, bitErrorRate, badHop, opts)
freqOverlap = local_frequency_stat(freqIdx, nFreqs, overlapFraction, "max");
freqBitErrorRate = local_frequency_stat(freqIdx, nFreqs, bitErrorRate, "mean");
freqBadHopFraction = local_frequency_stat(freqIdx, nFreqs, double(badHop), "mean");
globalErrorRef = median(bitErrorRate(isfinite(bitErrorRate)));
if isempty(globalErrorRef) || ~isfinite(globalErrorRef)
    globalErrorRef = 0;
end

badByGeometry = freqOverlap >= opts.minOverlapFraction;
badByHopFraction = freqBadHopFraction >= opts.badFreqHopFractionThreshold;
badByError = freqBitErrorRate >= opts.badFreqErrorRateThreshold ...
    & freqBitErrorRate >= globalErrorRef + opts.badFreqErrorExcessThreshold;
eraseFreq = narrowbandOn & (badByGeometry | badByHopFraction | badByError);
eraseFreq = eraseFreq(:);
end

function value = local_frequency_stat(freqIdx, nFreqs, x, modeName)
freqIdx = round(double(freqIdx(:)));
x = double(x(:));
if numel(freqIdx) ~= numel(x)
    error("Frequency statistic input length mismatch.");
end
nFreqs = round(double(nFreqs));
value = zeros(nFreqs, 1);
modeName = string(modeName);
for freqNow = 1:nFreqs
    use = freqIdx == freqNow;
    if ~any(use)
        error("Frequency %d has no hop observations for label aggregation.", freqNow);
    end
    xNow = x(use);
    switch modeName
        case "max"
            value(freqNow) = max(xNow);
        case "mean"
            value(freqNow) = mean(xNow);
        otherwise
            error("Unsupported frequency statistic mode: %s.", char(modeName));
    end
end
end

function idx = ml_fh_erasure_feature_index(name)
names = ml_fh_erasure_feature_names();
idx = find(names == string(name), 1, "first");
if isempty(idx)
    error("Unknown FH-erasure feature: %s", char(string(name)));
end
end

function pBlock = local_clean_training_channel(p)
pBlock = p;
pBlock.channel.impulseProb = 0;
pBlock.channel.impulseToBgRatio = 0;
pBlock.channel.impulseWeight = 0;
pBlock.channel.singleTone.enable = false;
pBlock.channel.narrowband.enable = false;
pBlock.channel.sweep.enable = false;
pBlock.channel.syncImpairment.enable = false;
pBlock.channel.multipath.enable = false;
pBlock.channel.multipath.rayleigh = false;
end

function centerRange = local_resolve_center_range(rawRange, maxCenterFreqPoints)
if any(isnan(rawRange))
    centerRange = [-maxCenterFreqPoints, maxCenterFreqPoints];
else
    centerRange = double(rawRange(:).');
    if centerRange(1) > centerRange(2)
        error("centerFreqPointsRange must be ascending.");
    end
    if centerRange(1) < -maxCenterFreqPoints || centerRange(2) > maxCenterFreqPoints
        error("centerFreqPointsRange [%g %g] exceeds valid range [%g %g].", ...
            centerRange(1), centerRange(2), -maxCenterFreqPoints, maxCenterFreqPoints);
    end
end
end

function centerFreqPoints = local_configured_center_freq_points(p, maxCenterFreqPoints)
if ~(isfield(p, "channel") && isstruct(p.channel) ...
        && isfield(p.channel, "narrowband") && isstruct(p.channel.narrowband) ...
        && isfield(p.channel.narrowband, "centerFreqPoints") && ~isempty(p.channel.narrowband.centerFreqPoints))
    error("configuredCenterProbability>0 requires p.channel.narrowband.centerFreqPoints.");
end
centerFreqPoints = double(p.channel.narrowband.centerFreqPoints);
if ~(isscalar(centerFreqPoints) && isfinite(centerFreqPoints))
    error("p.channel.narrowband.centerFreqPoints must be a finite scalar.");
end
if abs(centerFreqPoints) > maxCenterFreqPoints
    error("Configured centerFreqPoints=%g exceeds valid range +/-%.6g.", ...
        centerFreqPoints, maxCenterFreqPoints);
end
end

function sym = local_random_symbols(nSym, modCfg)
nSym = max(1, round(double(nSym)));
switch upper(string(modCfg.type))
    case "BPSK"
        bits = randi([0 1], nSym, 1, "uint8");
        sym = 1 - 2 * double(bits);
    case "QPSK"
        bits = randi([0 1], 2 * nSym, 1, "uint8");
        bI = bits(1:2:end);
        bQ = bits(2:2:end);
        sym = (1 - 2 * double(bI) + 1j * (1 - 2 * double(bQ))) / sqrt(2);
    otherwise
        error("Unsupported modulation for FH-erasure dataset: %s", char(string(modCfg.type)));
end
sym = sym(:);
end

function y = local_fit_complex_length(x, targetLen)
x = x(:);
targetLen = max(0, round(double(targetLen)));
if numel(x) >= targetLen
    y = x(1:targetLen);
else
    y = [x; complex(zeros(targetLen - numel(x), 1))];
end
end

function overlapFraction = local_narrowband_overlap_fraction(hopInfo, fhCfg, waveform, narrowbandCfg)
freqOffsets = double(hopInfo.freqOffsets(:));
nHops = round(double(hopInfo.nHops));
freqOffsets = freqOffsets(1:nHops);
freqSet = unique(sort(double(fhCfg.freqSet(:))));
if numel(freqSet) < 2
    error("FH-erasure geometry labels require at least two FH frequencies.");
end
spacingRs = median(diff(freqSet));
channelWidthRs = 1;
if isfield(waveform, "rolloff") && ~isempty(waveform.rolloff)
    channelWidthRs = 1 + double(waveform.rolloff);
end
signalHalf = channelWidthRs / 2;
centerRs = double(narrowbandCfg.centerFreqPoints) * spacingRs;
bandwidthRs = double(narrowbandCfg.bandwidthFreqPoints) * spacingRs;
jamHalf = bandwidthRs / 2;

sigLeft = freqOffsets - signalHalf;
sigRight = freqOffsets + signalHalf;
jamLeft = centerRs - jamHalf;
jamRight = centerRs + jamHalf;
overlap = max(0, min(sigRight, jamRight) - max(sigLeft, jamLeft));
overlapFraction = overlap ./ max(channelWidthRs, eps);
overlapFraction = max(min(overlapFraction, 1), 0);
end

function bitErrorRate = local_hop_bit_error_rate(txSym, rxSym, hopLen, modCfg)
txSym = txSym(:);
rxSym = rxSym(:);
nSym = min(numel(txSym), numel(rxSym));
nHops = ceil(double(nSym) / double(hopLen));
bitErrorRate = zeros(nHops, 1);
for hopIdx = 1:nHops
    startIdx = (hopIdx - 1) * hopLen + 1;
    stopIdx = min(nSym, hopIdx * hopLen);
    tx = txSym(startIdx:stopIdx);
    rx = rxSym(startIdx:stopIdx);
    switch upper(string(modCfg.type))
        case "BPSK"
            txBits = real(tx) < 0;
            rxBits = real(rx) < 0;
        case "QPSK"
            txBits = reshape([real(tx).' < 0; imag(tx).' < 0], [], 1);
            rxBits = reshape([real(rx).' < 0; imag(rx).' < 0], [], 1);
        otherwise
            error("Unsupported modulation for FH-erasure labels: %s", char(string(modCfg.type)));
    end
    bitErrorRate(hopIdx) = mean(txBits(:) ~= rxBits(:));
end
end
