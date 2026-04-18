function dataset = ml_generate_interference_selector_dataset(p, nBlocks, dataSymbolsPerBlock, ebN0dBRange, opts)
%ML_GENERATE_INTERFERENCE_SELECTOR_DATASET  Generate balanced frame-level features on the layered RX chain.

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
dataset.primaryLabels = strings(nBlocks, 1);
dataset.primaryLabelIndex = zeros(nBlocks, 1);
dataset.labelMatrix = zeros(nBlocks, numel(classNames));
dataset.ebN0dBPerBlock = zeros(nBlocks, 1);
dataset.bootstrapPath = strings(nBlocks, 1);

for b = 1:nBlocks
    primaryLabel = labelSchedule(b);
    success = false;
    for attempt = 1:opts.maxRetriesPerBlock
        ebN0dB = ebN0dBRange(1) + rand() * diff(ebN0dBRange);
        EbN0 = 10.^(ebN0dB / 10);
        N0 = ebn0_to_n0(EbN0, codeRate, bitsPerSym, 1.0);

        pBlock = local_selector_reset_channel_local(p);
        labelMask = false(1, numel(classNames));
        [pBlock, labelMask] = local_apply_selector_class_to_channel_local(pBlock, p, primaryLabel, classNames, labelMask);
        auxiliaryClasses = local_selector_enabled_auxiliary_classes_local(p, primaryLabel, classNames);
        [pBlock, labelMask] = local_selector_apply_auxiliary_classes_local( ...
            pBlock, p, auxiliaryClasses, classNames, labelMask);
        [txFrame, fhCaptureCfg] = local_build_training_packet(pBlock, dataSymbolsPerBlock);
        frameDelaySym = randi([0, max(0, round(double(pBlock.channel.maxDelaySymbols)))], 1, 1);
        frameDelay = round(double(frameDelaySym) * waveform.sps);
        txSampleFrame = pulse_tx_from_symbol_rate(txFrame, waveform);
        txSampleFrame = local_apply_fast_training_packet_samples(txSampleFrame, fhCaptureCfg, waveform);
        txSample = [zeros(frameDelay, 1); txSampleFrame];
        channelSample = adapt_channel_for_sps(pBlock.channel, waveform, pBlock.fh);
        rxSample = channel_bg_impulsive(txSample, N0, channelSample);

        totalLen = numel(txFrame);
        front = capture_synced_block_from_samples( ...
            rxSample, syncSym, totalLen, syncCfg, pBlock.mitigation, pBlock.mod, waveform, "none", strings(1, 0), fhCaptureCfg);
        if ~front.ok
            continue;
        end

        channelLenSymbols = local_selector_channel_len_symbols(pBlock.channel, waveform);
        [featureRow, ~] = adaptive_frontend_extract_features(front, syncSym, N0, ...
            "channelLenSymbols", channelLenSymbols);
        if any(~isfinite(featureRow))
            continue;
        end

        dataset.featureMatrix(b, :) = featureRow;
        dataset.primaryLabels(b) = primaryLabel;
        dataset.primaryLabelIndex(b) = find(classNames == primaryLabel, 1, "first");
        dataset.labelMatrix(b, :) = double(labelMask);
        dataset.ebN0dBPerBlock(b) = ebN0dB;
        dataset.bootstrapPath(b) = string(front.bootstrapPath);
        success = true;
        break;
    end

    if ~success
        error("Failed to generate a valid selector sample for class %s after %d retries.", ...
            char(primaryLabel), opts.maxRetriesPerBlock);
    end
end

dataset.labels = dataset.primaryLabels;
dataset.labelIndex = dataset.primaryLabelIndex;
dataset.primaryClassCounts = accumarray(dataset.primaryLabelIndex(:), 1, [numel(classNames) 1], @sum, 0);
dataset.classPresenceCounts = sum(dataset.labelMatrix, 1).';
dataset.classCounts = dataset.primaryClassCounts;

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

function pBlock = local_selector_reset_channel_local(p)
pBlock = p;
pBlock.channel.impulseProb = 0;
pBlock.channel.impulseToBgRatio = 0;
pBlock.channel.singleTone.enable = false;
pBlock.channel.narrowband.enable = false;
pBlock.channel.sweep.enable = false;
pBlock.channel.syncImpairment.enable = false;
pBlock.channel.multipath.enable = false;
pBlock.channel.multipath.rayleigh = false;
end

function [pBlock, labelMask] = local_apply_selector_class_to_channel_local(pBlock, pRef, labelName, classNames, labelMask)
labelName = lower(string(labelName));
labelIdx = find(classNames == labelName, 1, "first");
if isempty(labelIdx)
    error("Unsupported selector class: %s", char(labelName));
end

switch labelName
    case "clean"
        % keep all extra impairments disabled
    case "impulse"
        pBlock.channel.impulseProb = local_selector_sample_scaled_local( ...
            local_selector_channel_scalar_local(pRef.channel, "impulseProb", 0.02), 0.55, 0.004, 0.05);
        pBlock.channel.impulseToBgRatio = local_selector_sample_scaled_local( ...
            local_selector_channel_scalar_local(pRef.channel, "impulseToBgRatio", 40), 0.45, 12, 80);
    case "tone"
        pBlock.channel.singleTone.enable = true;
        pBlock.channel.singleTone.power = local_selector_sample_scaled_local( ...
            local_selector_nested_scalar_local(pRef.channel.singleTone, "power", 0.03), 0.65, 0.004, 0.10);
        pBlock.channel.singleTone.freqHz = local_selector_sample_scaled_local( ...
            local_selector_nested_scalar_local(pRef.channel.singleTone, "freqHz", 1500), 0.85, -4000, 4000);
        pBlock.channel.singleTone.randomPhase = true;
    case "narrowband"
        pBlock.channel.narrowband.enable = true;
        pBlock.channel.narrowband.power = local_selector_sample_scaled_local( ...
            local_selector_nested_scalar_local(pRef.channel.narrowband, "power", 0.03), 0.65, 0.004, 0.10);
        pBlock.channel.narrowband.bandwidthFreqPoints = local_selector_sample_scaled_local( ...
            local_selector_nested_scalar_local(pRef.channel.narrowband, "bandwidthFreqPoints", 0.9), 0.55, 0.2, 1.6);
        [maxCenterFreqPoints, ~] = narrowband_center_freq_points_limit( ...
            pBlock.fh, resolve_waveform_cfg(pBlock), pBlock.channel.narrowband.bandwidthFreqPoints);
        centerBase = local_selector_nested_scalar_local(pRef.channel.narrowband, "centerFreqPoints", 0.8);
        if maxCenterFreqPoints <= 0
            pBlock.channel.narrowband.centerFreqPoints = 0;
        else
            centerNow = local_selector_sample_scaled_local(centerBase, 0.85, -maxCenterFreqPoints, maxCenterFreqPoints);
            pBlock.channel.narrowband.centerFreqPoints = max(min(centerNow, maxCenterFreqPoints), -maxCenterFreqPoints);
        end
    case "sweep"
        pBlock.channel.sweep.enable = true;
        pBlock.channel.sweep.power = local_selector_sample_scaled_local( ...
            local_selector_nested_scalar_local(pRef.channel.sweep, "power", 0.025), 0.65, 0.004, 0.08);
        startBase = local_selector_nested_scalar_local(pRef.channel.sweep, "startHz", -1800);
        stopBase = local_selector_nested_scalar_local(pRef.channel.sweep, "stopHz", 1800);
        pBlock.channel.sweep.startHz = local_selector_sample_scaled_local(startBase, 0.75, -4000, 1000);
        pBlock.channel.sweep.stopHz = local_selector_sample_scaled_local(stopBase, 0.75, -1000, 4000);
        if pBlock.channel.sweep.stopHz <= pBlock.channel.sweep.startHz
            pBlock.channel.sweep.stopHz = min(4000, pBlock.channel.sweep.startHz + 1200 + 1800 * rand());
        end
        periodBase = local_selector_nested_scalar_local(pRef.channel.sweep, "periodSymbols", 256);
        pBlock.channel.sweep.periodSymbols = max(64, min(384, round(local_selector_sample_scaled_local(periodBase, 0.6, 64, 384))));
        pBlock.channel.sweep.randomPhase = true;
    case "multipath"
        pBlock.channel.multipath.enable = true;
        pBlock.channel.multipath.pathDelaysSymbols = local_selector_multipath_delays_local(pRef.channel);
        pBlock.channel.multipath.pathGainsDb = local_selector_multipath_gains_local(pRef.channel);
        rayleighBase = local_selector_nested_scalar_local(pRef.channel.multipath, "rayleigh", 1);
        pBlock.channel.multipath.rayleigh = logical(rayleighBase) || rand() < 0.35;
    otherwise
        error("Unsupported selector class: %s", char(labelName));
end
labelMask(labelIdx) = true;
end

function auxiliaryClasses = local_selector_enabled_auxiliary_classes_local(p, primaryLabel, classNames)
auxiliaryClasses = strings(1, 0);
primaryLabel = string(primaryLabel);
if primaryLabel == "clean"
    return;
end
for k = 1:numel(classNames)
    className = classNames(k);
    if className == "clean" || className == primaryLabel
        continue;
    end
    if local_selector_class_enabled_in_channel_local(p.channel, className)
        auxiliaryClasses(end+1) = className; %#ok<AGROW>
    end
end
end

function [pBlock, labelMask] = local_selector_apply_auxiliary_classes_local(pBlock, pRef, auxiliaryClasses, classNames, labelMask)
if isempty(auxiliaryClasses)
    return;
end

selectedMask = rand(size(auxiliaryClasses)) < 0.7;
if ~any(selectedMask)
    selectedMask(randi(numel(auxiliaryClasses), 1, 1)) = true;
end

selectedClasses = auxiliaryClasses(selectedMask);
selectedClasses = selectedClasses(randperm(numel(selectedClasses)));
for k = 1:numel(selectedClasses)
    [pBlock, labelMask] = local_apply_selector_class_to_channel_local( ...
        pBlock, pRef, selectedClasses(k), classNames, labelMask);
end
end

function tf = local_selector_class_enabled_in_channel_local(channelCfg, className)
className = lower(string(className));
switch className
    case "impulse"
        tf = isfield(channelCfg, "impulseProb") && double(channelCfg.impulseProb) > 0;
    case "tone"
        tf = isfield(channelCfg, "singleTone") && isstruct(channelCfg.singleTone) ...
            && isfield(channelCfg.singleTone, "enable") && logical(channelCfg.singleTone.enable);
    case "narrowband"
        tf = isfield(channelCfg, "narrowband") && isstruct(channelCfg.narrowband) ...
            && isfield(channelCfg.narrowband, "enable") && logical(channelCfg.narrowband.enable);
    case "sweep"
        tf = isfield(channelCfg, "sweep") && isstruct(channelCfg.sweep) ...
            && isfield(channelCfg.sweep, "enable") && logical(channelCfg.sweep.enable);
    case "multipath"
        tf = isfield(channelCfg, "multipath") && isstruct(channelCfg.multipath) ...
            && isfield(channelCfg.multipath, "enable") && logical(channelCfg.multipath.enable);
    otherwise
        error("Unsupported selector class for auxiliary sampling: %s", char(className));
end
end

function value = local_selector_channel_scalar_local(cfg, fieldName, defaultValue)
if isfield(cfg, fieldName) && ~isempty(cfg.(fieldName))
    value = double(cfg.(fieldName));
else
    value = double(defaultValue);
end
if ~(isscalar(value) && isfinite(value))
    error("Selector dataset field channel.%s must be a finite scalar.", fieldName);
end
end

function value = local_selector_nested_scalar_local(cfg, fieldName, defaultValue)
if isfield(cfg, fieldName) && ~isempty(cfg.(fieldName))
    value = double(cfg.(fieldName));
else
    value = double(defaultValue);
end
if ~(isscalar(value) && isfinite(value))
    error("Selector dataset field %s must be a finite scalar.", fieldName);
end
end

function value = local_selector_sample_scaled_local(baseValue, relativeSpan, minValue, maxValue)
baseValue = double(baseValue);
relativeSpan = abs(double(relativeSpan));
minValue = double(minValue);
maxValue = double(maxValue);
if ~(isscalar(baseValue) && isfinite(baseValue))
    error("Selector dataset baseValue must be a finite scalar.");
end
if ~(isscalar(minValue) && isfinite(minValue) && isscalar(maxValue) && isfinite(maxValue) && maxValue >= minValue)
    error("Selector dataset range must be a finite ascending interval.");
end
scale = 1 - relativeSpan + 2 * relativeSpan * rand();
value = baseValue * scale;
value = max(min(value, maxValue), minValue);
end

function delays = local_selector_multipath_delays_local(channelCfg)
if isfield(channelCfg, "multipath") && isstruct(channelCfg.multipath) ...
        && isfield(channelCfg.multipath, "pathDelaysSymbols") && ~isempty(channelCfg.multipath.pathDelaysSymbols)
    delays = round(double(channelCfg.multipath.pathDelaysSymbols(:).'));
else
    delays = [0 1 2];
end
if isempty(delays) || any(~isfinite(delays)) || any(delays < 0)
    error("Selector dataset multipath.pathDelaysSymbols must be finite nonnegative values.");
end
delays = unique(delays, "stable");
if delays(1) ~= 0
    delays = [0 delays];
end
end

function gainsDb = local_selector_multipath_gains_local(channelCfg)
delays = local_selector_multipath_delays_local(channelCfg);
if isfield(channelCfg, "multipath") && isstruct(channelCfg.multipath) ...
        && isfield(channelCfg.multipath, "pathGainsDb") && ~isempty(channelCfg.multipath.pathGainsDb)
    baseGains = double(channelCfg.multipath.pathGainsDb(:).');
else
    baseGains = [0 -8 -14];
end
if numel(baseGains) ~= numel(delays)
    error("Selector dataset multipath.pathGainsDb length must match pathDelaysSymbols length.");
end
gainsDb = baseGains;
if numel(gainsDb) >= 2
    gainsDb(2:end) = gainsDb(2:end) + (-3 + 6 * rand(1, numel(gainsDb) - 1));
end
gainsDb(1) = 0;
end

function [txFrame, fhCaptureCfg] = local_build_training_packet(p, dataSymbolsPerBlock)
packetIdx = 1;
bitsPerSym = bits_per_symbol_local(p.mod);
packetDataBitsLen = local_training_packet_data_bits_len(p, dataSymbolsPerBlock, bitsPerSym);
packetDataBits = randi([0 1], packetDataBitsLen, 1, "uint8");
packetDataBytes = ceil(packetDataBitsLen / 8);

phyMeta = struct();
phyMeta.hasSessionHeader = false;
phyMeta.packetIndex = uint16(packetIdx);
phyMeta.packetDataBytes = uint16(packetDataBytes);
phyMeta.packetDataCrc16 = crc16_ccitt_bits(packetDataBits);
[phyHeaderBits, ~] = build_phy_header_bits(phyMeta, p.frame);
phyHeaderSym = encode_phy_header_symbols(phyHeaderBits, p.frame, p.fec);
phyHeaderFhCfg = phy_header_fh_cfg(p.frame, p.fh, p.fec);
phyHeaderFast = phyHeaderFhCfg.enable && fh_is_fast(phyHeaderFhCfg);
if phyHeaderFast
    [phyHeaderSym, ~] = fh_fast_symbol_expand(phyHeaderSym, phyHeaderFhCfg);
end

scrambleCfg = derive_packet_scramble_cfg(p.scramble, packetIdx, 0);
dataBitsScr = scramble_bits(packetDataBits, scrambleCfg);
codedBits = fec_encode(dataBitsScr, p.fec);
[codedBitsInt, ~] = interleave_bits(codedBits, p.interleaver);
[dataSym, ~] = modulate_bits(codedBitsInt, p.mod, p.fec);
dataDsssCfg = derive_packet_dsss_cfg(p.dsss, packetIdx, 0, numel(dataSym));
[dataSym, ~] = dsss_spread(dataSym, dataDsssCfg);
fhCfg = struct("enable", false);
if isfield(p, "fh") && isfield(p.fh, "enable") && p.fh.enable
    fhCfg = derive_packet_fh_cfg(p.fh, packetIdx, 0, numel(dataSym));
    if fh_is_fast(fhCfg)
        [dataSym, ~] = fh_fast_symbol_expand(dataSym, fhCfg);
    end
end

[~, syncSym] = make_packet_sync(p.frame, packetIdx);
txFrame = [syncSym(:); phyHeaderSym(:); dataSym(:)];
fhCaptureCfg = struct( ...
    "enable", logical((isfield(phyHeaderFhCfg, "enable") && phyHeaderFhCfg.enable) ...
        || (isfield(fhCfg, "enable") && fhCfg.enable)), ...
    "syncSymbols", double(numel(syncSym)), ...
    "headerSymbols", double(numel(phyHeaderSym)), ...
    "headerFhCfg", phyHeaderFhCfg, ...
    "dataFhCfg", fhCfg);
end

function txOut = local_apply_fast_training_packet_samples(txIn, fhCaptureCfg, waveform)
txOut = txIn(:);
if ~(isstruct(fhCaptureCfg) && isfield(fhCaptureCfg, "enable") && fhCaptureCfg.enable)
    return;
end

headerStart = local_symbol_boundary_sample_index(double(fhCaptureCfg.syncSymbols), waveform);
dataStart = local_symbol_boundary_sample_index(double(fhCaptureCfg.syncSymbols + fhCaptureCfg.headerSymbols), waveform);
if isfield(fhCaptureCfg, "headerFhCfg") && isstruct(fhCaptureCfg.headerFhCfg) ...
        && isfield(fhCaptureCfg.headerFhCfg, "enable") && fhCaptureCfg.headerFhCfg.enable
    headerStop = min(numel(txOut), dataStart - 1);
    if headerStart <= headerStop
        [segOut, ~] = fh_modulate_samples(txOut(headerStart:headerStop), fhCaptureCfg.headerFhCfg, waveform);
        txOut(headerStart:headerStop) = segOut;
    end
end

if isfield(fhCaptureCfg, "dataFhCfg") && isstruct(fhCaptureCfg.dataFhCfg) ...
        && isfield(fhCaptureCfg.dataFhCfg, "enable") && fhCaptureCfg.dataFhCfg.enable
    if dataStart <= numel(txOut)
        [segOut, ~] = fh_modulate_samples(txOut(dataStart:end), fhCaptureCfg.dataFhCfg, waveform);
        txOut(dataStart:end) = segOut;
    end
end
end

function sampleIdx = local_symbol_boundary_sample_index(nLeadingSym, waveform)
nLeadingSym = max(0, round(double(nLeadingSym)));
sampleIdx = nLeadingSym * round(double(waveform.sps)) + 1;
end

function packetDataBitsLen = local_training_packet_data_bits_len(p, dataSymbolsPerBlock, bitsPerSym)
dataSymbolsPerBlock = max(1, round(double(dataSymbolsPerBlock)));
fecInfo = fec_get_info(p.fec);
targetInfoBits = round(double(dataSymbolsPerBlock) * double(bitsPerSym) * double(fecInfo.codeRate));
switch string(fecInfo.kind)
    case "conv"
        packetDataBitsLen = max(8, targetInfoBits);
    case "ldpc"
        packetDataBitsLen = max(8, min(double(fecInfo.numInfoBits), targetInfoBits));
    otherwise
        error("Unsupported selector payload FEC kind: %s", char(string(fecInfo.kind)));
end
packetDataBitsLen = 8 * floor(double(packetDataBitsLen) / 8);
if packetDataBitsLen <= 0
    packetDataBitsLen = 8;
end
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
