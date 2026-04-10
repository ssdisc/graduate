function dataset = ml_generate_narrowband_dataset(p, nBlocks, ebN0dBRange, opts)
%ML_GENERATE_NARROWBAND_DATASET  Generate binary action labels for narrowband bandstop gating.

arguments
    p (1,1) struct
    nBlocks (1,1) double {mustBeInteger, mustBePositive}
    ebN0dBRange (1,2) double
    opts.blockLenRange (1,2) double {mustBePositive} = [96 1024]
    opts.maxRetriesPerBlock (1,1) double {mustBeInteger, mustBePositive} = 8
    opts.bpskProbability (1,1) double = 0.35
    opts.verbose (1,1) logical = true
end

blockLenRange = round(double(opts.blockLenRange(:).'));
if blockLenRange(1) > blockLenRange(2)
    error("blockLenRange must be an ascending [min max] range.");
end
if ~(opts.bpskProbability >= 0 && opts.bpskProbability <= 1)
    error("bpskProbability must be within [0, 1].");
end

classNames = ["pass" "bandstop"];
featureNames = ml_narrowband_feature_names();
waveform = resolve_waveform_cfg(p);

labelSchedule = repmat(classNames, 1, ceil(nBlocks / numel(classNames)));
labelSchedule = labelSchedule(1:nBlocks);
labelSchedule = labelSchedule(randperm(nBlocks));

dataset = struct();
dataset.nBlocks = nBlocks;
dataset.ebN0dBRange = ebN0dBRange;
dataset.classNames = classNames;
dataset.featureNames = featureNames;
dataset.featureMatrix = zeros(nBlocks, numel(featureNames));
dataset.labels = strings(nBlocks, 1);
dataset.labelIndex = zeros(nBlocks, 1);
dataset.ebN0dBPerBlock = zeros(nBlocks, 1);
dataset.blockLenPerBlock = zeros(nBlocks, 1);
dataset.modulationPerBlock = strings(nBlocks, 1);
dataset.scenarioPerBlock = strings(nBlocks, 1);

for b = 1:nBlocks
    labelNow = labelSchedule(b);
    success = false;
    for attempt = 1:opts.maxRetriesPerBlock
        blockLen = randi(blockLenRange, 1, 1);
        ebN0dB = ebN0dBRange(1) + rand() * diff(ebN0dBRange);
        N0 = 10^(-ebN0dB / 10);

        if rand() < opts.bpskProbability
            modType = "BPSK";
        else
            modType = "QPSK";
        end

        txSym = local_random_symbols(blockLen, modType);
        txSample = pulse_tx_from_symbol_rate(txSym, waveform);

        [pBlock, scenarioName] = local_channel_for_label(p, labelNow, waveform);
        channelSample = adapt_channel_for_sps(pBlock.channel, waveform, pBlock.fh);
        rxSample = channel_bg_impulsive(txSample, N0, channelSample);
        rxSym = pulse_rx_to_symbol_rate(rxSample, waveform);
        rxSym = local_fit_complex_length(rxSym, blockLen);
        if numel(rxSym) < 32 || ~any(abs(rxSym) > 0)
            continue;
        end

        [featureRow, ~] = ml_extract_narrowband_features(rxSym, pBlock.mitigation.fftBandstop);
        if any(~isfinite(featureRow))
            continue;
        end

        dataset.featureMatrix(b, :) = featureRow;
        dataset.labels(b) = labelNow;
        dataset.labelIndex(b) = find(classNames == labelNow, 1, "first");
        dataset.ebN0dBPerBlock(b) = ebN0dB;
        dataset.blockLenPerBlock(b) = blockLen;
        dataset.modulationPerBlock(b) = modType;
        dataset.scenarioPerBlock(b) = scenarioName;
        success = true;
        break;
    end

    if ~success
        error("Failed to generate a valid narrowband ML sample for label %s after %d retries.", ...
            char(labelNow), opts.maxRetriesPerBlock);
    end
end

dataset.classCounts = zeros(numel(classNames), 1);
for k = 1:numel(classNames)
    dataset.classCounts(k) = nnz(dataset.labels == classNames(k));
end

if opts.verbose
    fprintf("Narrowband action dataset generated: %d blocks.\n", nBlocks);
end
end

function sym = local_random_symbols(nSym, modType)
nSym = max(1, round(double(nSym)));
switch upper(string(modType))
    case "BPSK"
        bits = randi([0 1], nSym, 1, "uint8");
        sym = 1 - 2 * double(bits);
    case "QPSK"
        bits = randi([0 1], 2 * nSym, 1, "uint8");
        bI = bits(1:2:end);
        bQ = bits(2:2:end);
        sym = (1 - 2 * double(bI) + 1j * (1 - 2 * double(bQ))) / sqrt(2);
    otherwise
        error("Unsupported modulation type for narrowband dataset: %s", char(modType));
end
sym = sym(:);
end

function [pBlock, scenarioName] = local_channel_for_label(p, labelName, waveform)
pBlock = p;
pBlock.channel.impulseProb = 0;
pBlock.channel.impulseToBgRatio = 0;
pBlock.channel.singleTone.enable = false;
pBlock.channel.narrowband.enable = false;
pBlock.channel.sweep.enable = false;
pBlock.channel.syncImpairment.enable = false;
pBlock.channel.multipath.enable = false;
pBlock.channel.multipath.rayleigh = false;

labelName = lower(string(labelName));
switch labelName
    case "bandstop"
        scenarioName = "narrowband";
        pBlock.channel.narrowband.enable = true;
        pBlock.channel.narrowband.power = 0.004 + 0.08 * rand();
        pBlock.channel.narrowband.bandwidthFreqPoints = 0.6 + 1.0 * rand();
        [maxCenterFreqPoints, ~] = narrowband_center_freq_points_limit( ...
            pBlock.fh, waveform, pBlock.channel.narrowband.bandwidthFreqPoints);
        pBlock.channel.narrowband.centerFreqPoints = -maxCenterFreqPoints + 2 * maxCenterFreqPoints * rand();
    case "pass"
        scenarios = ["clean" "impulse" "tone" "sweep" "multipath"];
        weights = [0.30 0.18 0.20 0.12 0.20];
        scenarioName = local_sample_weighted_string(scenarios, weights);
        switch scenarioName
            case "clean"
                % keep all impairments disabled
            case "impulse"
                pBlock.channel.impulseProb = 0.004 + 0.028 * rand();
                pBlock.channel.impulseToBgRatio = 15 + 55 * rand();
            case "tone"
                pBlock.channel.singleTone.enable = true;
                pBlock.channel.singleTone.power = 0.004 + 0.08 * rand();
                pBlock.channel.singleTone.freqHz = -0.22 * waveform.sampleRateHz + 0.44 * waveform.sampleRateHz * rand();
                pBlock.channel.singleTone.randomPhase = true;
            case "sweep"
                pBlock.channel.sweep.enable = true;
                pBlock.channel.sweep.power = 0.004 + 0.06 * rand();
                pBlock.channel.sweep.startHz = -0.18 * waveform.sampleRateHz + 0.08 * waveform.sampleRateHz * rand();
                pBlock.channel.sweep.stopHz = 0.10 * waveform.sampleRateHz + 0.10 * waveform.sampleRateHz * rand();
                pBlock.channel.sweep.periodSymbols = randi([64 384], 1, 1);
                pBlock.channel.sweep.randomPhase = true;
            case "multipath"
                pBlock.channel.multipath.enable = true;
                pBlock.channel.multipath.pathDelaysSymbols = [0 1 2];
                pBlock.channel.multipath.pathGainsDb = [0, -4 - 6 * rand(), -8 - 8 * rand()];
                pBlock.channel.multipath.rayleigh = rand() < 0.5;
            otherwise
                error("Unsupported negative scenario: %s", char(scenarioName));
        end
    otherwise
        error("Unsupported narrowband action label: %s", char(labelName));
end
end

function value = local_sample_weighted_string(values, weights)
weights = double(weights(:));
if numel(values) ~= numel(weights) || any(weights < 0) || ~any(weights > 0)
    error("Weighted string sampling requires aligned positive weights.");
end
cdf = cumsum(weights / sum(weights));
u = rand();
idx = find(u <= cdf, 1, "first");
if isempty(idx)
    idx = numel(values);
end
value = string(values(idx));
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
