function dataset = ml_generate_interference_selector_dataset(p, nBlocks, dataSymbolsPerBlock, ebN0dBRange, opts)
%ML_GENERATE_INTERFERENCE_SELECTOR_DATASET  Generate balanced frame-level features for interference selection.

arguments
    p (1,1) struct
    nBlocks (1,1) double {mustBeInteger, mustBePositive}
    dataSymbolsPerBlock (1,1) double {mustBeInteger, mustBePositive}
    ebN0dBRange (1,2) double
    opts.maxRetriesPerBlock (1,1) double {mustBeInteger, mustBePositive} = 8
    opts.classNames string = ml_interference_selector_class_names()
    opts.verbose (1,1) logical = true
end

classNames = string(opts.classNames(:).');
featureNames = ml_interference_selector_feature_names();
waveform = resolve_waveform_cfg(p);
[~, syncSym] = make_packet_sync(p.frame, 1);
syncCfg = local_selector_sync_cfg(p.rxSync, p.channel, waveform);
[~, modInfo] = modulate_bits(uint8(zeros(bits_per_symbol_local(p.mod), 1)), p.mod, p.fec);
modInfo.spreadFactor = dsss_effective_spread_factor(p.dsss);
bitsPerSym = modInfo.bitsPerSymbol;
codeRate = modInfo.codeRate / modInfo.spreadFactor;

labelSchedule = repmat(classNames, 1, ceil(nBlocks / numel(classNames)));
labelSchedule = labelSchedule(1:nBlocks);
labelSchedule = labelSchedule(randperm(nBlocks));

dataset = struct();
dataset.nBlocks = nBlocks;
dataset.dataSymbolsPerBlock = dataSymbolsPerBlock;
dataset.ebN0dBRange = ebN0dBRange;
dataset.classNames = classNames;
dataset.featureNames = featureNames;
dataset.featureMatrix = zeros(nBlocks, numel(featureNames));
dataset.labels = strings(nBlocks, 1);
dataset.labelIndex = zeros(nBlocks, 1);
dataset.ebN0dBPerBlock = zeros(nBlocks, 1);
dataset.bootstrapPath = strings(nBlocks, 1);

for b = 1:nBlocks
    labelNow = labelSchedule(b);
    success = false;
    for attempt = 1:opts.maxRetriesPerBlock
        ebN0dB = ebN0dBRange(1) + rand() * diff(ebN0dBRange);
        EbN0 = 10.^(ebN0dB / 10);
        N0 = ebn0_to_n0(EbN0, codeRate, bitsPerSym, 1.0);

        pBlock = local_selector_channel_for_class(p, labelNow);
        txFrame = local_build_training_frame(pBlock, syncSym, dataSymbolsPerBlock);
        frameDelaySym = randi([0, max(0, round(double(pBlock.channel.maxDelaySymbols)))], 1, 1);
        frameDelay = round(double(frameDelaySym) * waveform.sps);
        txSample = [zeros(frameDelay, 1); pulse_tx_from_symbol_rate(txFrame, waveform)];
        channelSample = adapt_channel_for_sps(pBlock.channel, waveform);
        rxSample = channel_bg_impulsive(txSample, N0, channelSample);
        rxRaw = pulse_rx_to_symbol_rate(rxSample, waveform);

        totalLen = numel(txFrame);
        capture = adaptive_frontend_bootstrap_capture(rxRaw, syncSym, totalLen, syncCfg, pBlock.mitigation, pBlock.mod);
        if ~capture.ok
            continue;
        end

        channelLenSymbols = local_selector_channel_len_symbols(pBlock.channel, waveform);
        [featureRow, ~] = adaptive_frontend_extract_features(capture, syncSym, N0, ...
            "channelLenSymbols", channelLenSymbols);
        if any(~isfinite(featureRow))
            continue;
        end

        dataset.featureMatrix(b, :) = featureRow;
        dataset.labels(b) = labelNow;
        dataset.labelIndex(b) = find(classNames == labelNow, 1, "first");
        dataset.ebN0dBPerBlock(b) = ebN0dB;
        dataset.bootstrapPath(b) = string(capture.bootstrapPath);
        success = true;
        break;
    end

    if ~success
        error("Failed to generate a valid selector sample for class %s after %d retries.", ...
            char(labelNow), opts.maxRetriesPerBlock);
    end
end

dataset.classCounts = zeros(numel(classNames), 1);
for k = 1:numel(classNames)
    dataset.classCounts(k) = nnz(dataset.labels == classNames(k));
end

if opts.verbose
    fprintf("Selector dataset generated: %d blocks.\n", nBlocks);
end
end

function syncCfg = local_selector_sync_cfg(rxSync, channelCfg, waveform)
syncCfg = rxSync;
syncCfg.minSearchIndex = 1;
mpExtra = 0;
if isfield(channelCfg, "multipath") && isstruct(channelCfg.multipath) ...
        && isfield(channelCfg.multipath, "enable") && channelCfg.multipath.enable
    if isfield(channelCfg.multipath, "pathDelaysSymbols") && ~isempty(channelCfg.multipath.pathDelaysSymbols)
        mpExtra = max(double(channelCfg.multipath.pathDelaysSymbols(:)));
    elseif isfield(channelCfg.multipath, "pathDelays") && ~isempty(channelCfg.multipath.pathDelays)
        dly = double(channelCfg.multipath.pathDelays(:));
        if isfield(waveform, "sps") && waveform.sps > 0
            dly = dly / double(waveform.sps);
        end
        mpExtra = max(dly);
    end
end
syncCfg.maxSearchIndex = double(channelCfg.maxDelaySymbols) + mpExtra + 6;
end

function pBlock = local_selector_channel_for_class(p, labelName)
pBlock = p;
pBlock.channel.impulseProb = 0;
pBlock.channel.impulseToBgRatio = 0;
pBlock.channel.singleTone.enable = false;
pBlock.channel.narrowband.enable = false;
pBlock.channel.sweep.enable = false;
pBlock.channel.syncImpairment.enable = false;
pBlock.channel.multipath.enable = false;
pBlock.channel.multipath.rayleigh = false;

switch lower(string(labelName))
    case "clean"
        % keep all extra impairments disabled
    case "impulse"
        pBlock.channel.impulseProb = 0.004 + 0.028 * rand();
        pBlock.channel.impulseToBgRatio = 15 + 55 * rand();
    case "tone"
        pBlock.channel.singleTone.enable = true;
        pBlock.channel.singleTone.power = 0.004 + 0.08 * rand();
        pBlock.channel.singleTone.freqHz = -2500 + 5000 * rand();
        pBlock.channel.singleTone.randomPhase = true;
    case "narrowband"
        pBlock.channel.narrowband.enable = true;
        pBlock.channel.narrowband.power = 0.004 + 0.08 * rand();
        pBlock.channel.narrowband.centerHz = -2200 + 4400 * rand();
        pBlock.channel.narrowband.bandwidthHz = 300 + 1400 * rand();
    case "sweep"
        pBlock.channel.sweep.enable = true;
        pBlock.channel.sweep.power = 0.004 + 0.06 * rand();
        pBlock.channel.sweep.startHz = -3500 + 1500 * rand();
        pBlock.channel.sweep.stopHz = 2000 + 1500 * rand();
        pBlock.channel.sweep.periodSymbols = randi([64 384], 1, 1);
        pBlock.channel.sweep.randomPhase = true;
    case "multipath"
        pBlock.channel.multipath.enable = true;
        pBlock.channel.multipath.pathDelaysSymbols = [0 1 2];
        pBlock.channel.multipath.pathGainsDb = [0, -4 - 6 * rand(), -8 - 8 * rand()];
        pBlock.channel.multipath.rayleigh = rand() < 0.5;
    otherwise
        error("Unsupported selector class: %s", char(labelName));
end
end

function txFrame = local_build_training_frame(p, syncSym, dataSymbolsPerBlock)
syncSym = syncSym(:);
bitsPerSym = bits_per_symbol_local(p.mod);
dataBits = randi([0 1], dataSymbolsPerBlock * bitsPerSym, 1, "uint8");
[dataSym, ~] = modulate_bits(dataBits, p.mod);
dataDsssCfg = derive_packet_dsss_cfg(p.dsss, 1, 0, numel(dataSym));
[dataSym, ~] = dsss_spread(dataSym, dataDsssCfg);
if isfield(p, "fh") && isfield(p.fh, "enable") && p.fh.enable
    [dataSym, ~] = fh_modulate(dataSym, p.fh);
end
txFrame = [syncSym; dataSym(:)];
end

function Lh = local_selector_channel_len_symbols(channelCfg, waveform)
Lh = 1;
if ~isfield(channelCfg, "multipath") || ~isstruct(channelCfg.multipath) ...
        || ~isfield(channelCfg.multipath, "enable") || ~channelCfg.multipath.enable
    return;
end
if isfield(channelCfg.multipath, "pathDelaysSymbols") && ~isempty(channelCfg.multipath.pathDelaysSymbols)
    Lh = max(1, round(max(double(channelCfg.multipath.pathDelaysSymbols(:)))) + 1);
    return;
end
if isfield(channelCfg.multipath, "pathDelays") && ~isempty(channelCfg.multipath.pathDelays)
    dly = double(channelCfg.multipath.pathDelays(:));
    if isfield(waveform, "sps") && waveform.sps > 0
        dly = dly / double(waveform.sps);
    end
    Lh = max(1, round(max(dly)) + 1);
end
end

function bitsPerSym = bits_per_symbol_local(modCfg)
switch upper(string(modCfg.type))
    case "BPSK"
        bitsPerSym = 1;
    case "QPSK"
        bitsPerSym = 2;
    case "MSK"
        bitsPerSym = 1;
    otherwise
        error("Unsupported modulation for selector dataset: %s", char(modCfg.type));
end
end
