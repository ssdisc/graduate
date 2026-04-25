function rxResult = decode_profile_packet(profileName, rxSamples, txArtifacts, rxCfg)
%DECODE_PROFILE_PACKET Decode one packet with a profile-specific independent receiver.

arguments
    profileName (1,1) string
    rxSamples (:,1) double
    txArtifacts (1,1) struct
    rxCfg (1,1) struct
end

local_require_packet_context_local(txArtifacts, rxCfg);
pkt = txArtifacts.packetAssist.txPackets(rxCfg.packetIndex);
runtimeCfg = rxCfg.runtimeCfg;
waveform = resolve_waveform_cfg(runtimeCfg);
method = string(rxCfg.method);
profileName = string(profileName);
expectedLen = numel(pkt.txSymPkt);

[sampleAction, symbolAction] = local_split_receiver_actions_local(profileName, method);
syncCfg = local_prepare_capture_sync_cfg_local(runtimeCfg.rxSync, runtimeCfg.channel);
fhCaptureCfg = local_packet_sample_fh_capture_cfg_local(pkt, waveform);
bootstrapChain = local_capture_bootstrap_chain_local(method);
front = capture_synced_block_from_samples( ...
    rxSamples(:), pkt.syncSym(:), expectedLen, syncCfg, runtimeCfg.mitigation, ...
    runtimeCfg.mod, waveform, sampleAction, bootstrapChain, fhCaptureCfg);

frontEndOk = logical(front.ok);
ySymRaw = complex(zeros(expectedLen, 1));
symbolReliabilityFront = zeros(expectedLen, 1);
if frontEndOk
    ySymRaw = local_fit_complex_length_local(front.rFull, expectedLen);
    symbolReliabilityFront = local_expand_reliability_local(front.reliabilityFull, expectedLen);
end

if frontEndOk
    [headerSym, dataSymRaw, symbolReliability, frontEndDiag] = local_profile_frontend_local( ...
        profileName, symbolAction, ySymRaw, symbolReliabilityFront, pkt, runtimeCfg, rxCfg);
else
    [headerSym, dataSymRaw, symbolReliability, frontEndDiag] = local_failed_frontend_placeholder_local(pkt);
end
frontEndOk = frontEndOk && logical(frontEndDiag.ok);

hdrBits = decode_phy_header_symbols(headerSym, runtimeCfg.frame, runtimeCfg.fec, runtimeCfg.softMetric);
[phy, headerOk] = parse_phy_header_bits(hdrBits, runtimeCfg.frame);
headerOk = headerOk && isfield(phy, "packetIndex") && double(phy.packetIndex) == double(pkt.packetIndex);

payloadBits = uint8([]);
sessionHeaderOk = false;
crcOk = false;
profileDiag = struct();
if headerOk
    rxCfgPayload = rxCfg;
    rxCfgPayload.frontEnd = frontEndDiag;
    [packetDataBitsRx, symbolReliabilityData, profileDiag] = local_decode_payload_local( ...
        profileName, method, dataSymRaw, symbolReliability, pkt, runtimeCfg, rxCfgPayload);
    packetDataBitsRx = fit_bits_length(packetDataBitsRx, numel(pkt.packetDataBits));
    crcOk = crc16_ccitt_bits(packetDataBitsRx) == phy.packetDataCrc16;
    if logical(pkt.hasSessionHeader)
        [~, payloadBits, sessionHeaderOk] = parse_session_header_bits(packetDataBitsRx, runtimeCfg.frame);
    else
        payloadBits = packetDataBitsRx;
        sessionHeaderOk = true;
    end
    profileDiag.symbolReliabilityData = symbolReliabilityData;
end

rawPacketOk = frontEndOk && headerOk && crcOk && sessionHeaderOk;
if ~rawPacketOk
    payloadBits = uint8([]);
end

rxResult = struct();
rxResult.method = method;
rxResult.frontEndOk = logical(frontEndOk);
rxResult.headerOk = logical(headerOk);
rxResult.packetOk = logical(rawPacketOk);
rxResult.rawPacketOk = logical(rawPacketOk);
rxResult.payloadBits = uint8(payloadBits(:));
rxResult.metrics = struct( ...
    "ebN0dB", double(rxCfg.ebN0dB), ...
    "jsrDb", double(rxCfg.jsrDb), ...
    "packetIndex", double(pkt.packetIndex), ...
    "headerCrcOk", logical(crcOk), ...
    "sessionHeaderOk", logical(sessionHeaderOk), ...
    "packetStartSample", double(front.packetStartSample), ...
    "packetStopSample", double(front.packetStopSample));
rxResult.commonDiagnostics = struct( ...
    "profileName", profileName, ...
    "expectedSymbols", expectedLen, ...
    "receivedSymbols", numel(ySymRaw), ...
    "capture", local_capture_diag_local(front), ...
    "frontEnd", frontEndDiag);
rxResult.profileDiagnostics = profileDiag;
end

function [headerSym, dataSymRaw, symbolReliability, diagOut] = local_profile_frontend_local(profileName, method, ySymRaw, symbolReliabilityIn, pkt, runtimeCfg, rxCfg)
headerStart = numel(pkt.syncSym) + 1;
headerStop = headerStart + double(pkt.nPhyHeaderSymTx) - 1;
dataStart = headerStop + 1;

symbolReliability = local_expand_reliability_local(symbolReliabilityIn, numel(ySymRaw));
diagOut = struct("ok", true);
ySymUse = ySymRaw;

switch profileName
    case "impulse"
        if method ~= "none"
            [ySymUse, reliability] = mitigate_impulses(ySymRaw, method, runtimeCfg.mitigation);
            symbolReliability = min(symbolReliability, local_expand_reliability_local(reliability, numel(ySymRaw)));
        end
        diagOut.frontEndMethod = method;

    case "narrowband"
        diagOut.frontEndMethod = "protected_control";

    case "rayleigh_multipath"
        if method == "sc_fde_mmse"
            freqBySymbol = local_packet_frequency_offsets_local(pkt, numel(ySymRaw));
            eq = multipath_equalizer_from_preamble( ...
                pkt.syncSym(:), ySymRaw(1:numel(pkt.syncSym)), ...
                local_header_equalizer_cfg_local(runtimeCfg, pkt), ...
                double(rxCfg.noisePsdLin), ...
                numel(rxCfg.channelState.multipathTaps));
            ySymUse = local_apply_frequency_aware_equalizer_block_local(ySymRaw, eq, freqBySymbol);
            diagOut.headerEqualizer = eq.method;
            diagOut.payloadEqualizer = eq;
        else
            diagOut.headerEqualizer = "none";
        end

    otherwise
        error("Unsupported profileName: %s", char(profileName));
end

headerSym = ySymUse(headerStart:headerStop);
if profileName == "rayleigh_multipath"
    dataSymRaw = ySymRaw(dataStart:end);
else
    dataSymRaw = ySymUse(dataStart:end);
end
if profileName == "impulse"
    symbolReliability = symbolReliability(dataStart:end);
end
end

function [headerSym, dataSymRaw, symbolReliability, diagOut] = local_failed_frontend_placeholder_local(pkt)
headerSym = complex(zeros(double(pkt.nPhyHeaderSymTx), 1));
dataSymRaw = complex(zeros(double(pkt.nDataSymTx), 1));
symbolReliability = zeros(double(pkt.nDataSymTx), 1);
diagOut = struct("ok", false, "reason", "capture_failed");
end

function [packetDataBitsRx, symbolReliabilityData, profileDiag] = local_decode_payload_local(profileName, method, dataSymRaw, symbolReliabilityIn, pkt, runtimeCfg, rxCfg)
profileDiag = struct();
dataSymUse = dataSymRaw(:);
reliabilityUse = ones(numel(dataSymUse), 1);
if ~isempty(symbolReliabilityIn)
    reliabilityUse = local_expand_reliability_local(symbolReliabilityIn, numel(dataSymUse));
end

switch profileName
    case "impulse"
        % symbolReliabilityIn already produced by the impulse front-end.

    case "narrowband"
        if method == "fh_erasure"
            [reliabilityNow, erasureInfo] = local_narrowband_hop_reliability_local(dataSymUse, pkt, runtimeCfg);
            reliabilityUse = min(reliabilityUse, local_expand_reliability_local(reliabilityNow, numel(dataSymUse)));
            profileDiag.hopReliability = erasureInfo.hopReliability;
            profileDiag.freqReliability = erasureInfo.freqReliability;
        end

    case "rayleigh_multipath"
        [dataSymUse, reliabilityNow, scFdeDiag] = local_sc_fde_payload_decode_local( ...
            dataSymUse, pkt, runtimeCfg, rxCfg, method);
        reliabilityUse = local_expand_reliability_local(reliabilityUse, numel(dataSymUse));
        reliabilityUse = min(reliabilityUse, local_expand_reliability_local(reliabilityNow, numel(dataSymUse)));
        profileDiag.scFde = scFdeDiag;

    otherwise
        error("Unsupported profileName: %s", char(profileName));
end

soft = demodulate_to_softbits(dataSymUse, runtimeCfg.mod, runtimeCfg.fec, runtimeCfg.softMetric, reliabilityUse);
codedBits = deinterleave_bits(soft, pkt.intState, runtimeCfg.interleaver);
packetDataBitsRx = fec_decode(codedBits, runtimeCfg.fec);
packetDataBitsRx = fit_bits_length(packetDataBitsRx, numel(pkt.packetDataBits));
symbolReliabilityData = reliabilityUse;
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
reliabilitySym = local_expand_reliability_local(reliabilitySym, numel(dataSym));

nFreqs = max(1, round(double(info.nFreqs)));
freqReliability = zeros(nFreqs, 1);
for freqIdx = 1:nFreqs
    use = info.freqIdx == freqIdx;
    if any(use)
        freqReliability(freqIdx) = median(hopReliability(use));
    else
        freqReliability(freqIdx) = 1;
    end
end
infoOut = struct( ...
    "hopReliability", hopReliability, ...
    "freqReliability", freqReliability, ...
    "featureInfo", info);
end

function [dataOut, reliabilityOut, diagOut] = local_sc_fde_payload_decode_local(dataSymIn, pkt, runtimeCfg, rxCfg, method)
plan = pkt.scFdeInfo;
if ~(isstruct(plan) && isfield(plan, "enable") && logical(plan.enable))
    dataOut = dataSymIn(:);
    reliabilityOut = ones(numel(dataOut), 1);
    diagOut = struct("enabled", false);
    return;
end

if isfield(rxCfg, "frontEnd") && isstruct(rxCfg.frontEnd) ...
        && isfield(rxCfg.frontEnd, "payloadEqualizer") && isstruct(rxCfg.frontEnd.payloadEqualizer) ...
        && isfield(rxCfg.frontEnd.payloadEqualizer, "hEst") && ~isempty(rxCfg.frontEnd.payloadEqualizer.hEst)
    h = rxCfg.frontEnd.payloadEqualizer.hEst(:);
elseif isfield(rxCfg, "channelState") && isstruct(rxCfg.channelState) ...
        && isfield(rxCfg.channelState, "multipathTaps") && ~isempty(rxCfg.channelState.multipathTaps)
    h = rxCfg.channelState.multipathTaps(:);
else
    error("Rayleigh multipath receiver requires a preamble-estimated or channelState multipath channel.");
end
if numel(h) > double(plan.cpLen) + 1
    error("SC-FDE decode requires channel length <= cpLen+1. Channel length=%d, cpLen=%d.", ...
        numel(h), double(plan.cpLen));
end

hopLen = round(double(plan.hopLen));
coreLen = round(double(plan.coreLen));
cpLen = round(double(plan.cpLen));
pilotLength = round(double(plan.pilotLength));
dataPerHop = round(double(plan.dataSymbolsPerHop));
nHops = round(double(plan.nHops));
if numel(dataSymIn) < nHops * hopLen
    dataSymIn = local_fit_complex_length_local(dataSymIn, nHops * hopLen);
end

lambda = double(runtimeCfg.scFde.lambdaFactor) * double(rxCfg.noisePsdLin);
if method ~= "sc_fde_mmse"
    lambda = inf;
end

blocks = reshape(dataSymIn(1:nHops * hopLen), hopLen, nHops);
dataMat = complex(zeros(dataPerHop, nHops));
reliabilityHop = ones(nHops, 1);
pilotMse = nan(nHops, 1);

H = fft([h(:); zeros(coreLen - numel(h), 1)]);
for hopIdx = 1:nHops
    block = blocks(:, hopIdx);
    core = block(cpLen + 1:end);
    if numel(core) ~= coreLen
        error("SC-FDE core length mismatch while decoding packet %d.", pkt.packetIndex);
    end

    if isfinite(lambda)
        W = conj(H) ./ max(abs(H).^2 + lambda, eps);
        xCore = ifft(fft(core) .* W);
    else
        xCore = core;
    end

    pilotTx = sc_fde_payload_pilot_symbols(runtimeCfg.scFde, double(pkt.packetIndex), hopIdx);
    pilotRx = xCore(1:pilotLength);
    alpha = sum(pilotRx .* conj(pilotTx)) / max(sum(abs(pilotTx).^2), eps);
    if abs(alpha) < max(double(runtimeCfg.scFde.pilotMinAbsGain), eps)
        alpha = 1;
    end
    xCore = xCore / alpha;
    pilotMse(hopIdx) = mean(abs(xCore(1:pilotLength) - pilotTx).^2);
    reliabilityHop(hopIdx) = 1 / (1 + pilotMse(hopIdx) / max(double(runtimeCfg.scFde.pilotMseReference), eps));
    reliabilityHop(hopIdx) = max(double(runtimeCfg.scFde.minReliability), min(1, reliabilityHop(hopIdx)));
    dataMat(:, hopIdx) = xCore(pilotLength + 1:end);
end

dataOut = dataMat(:);
dataOut = dataOut(1:double(pkt.nDataSymBase));
reliabilityOut = repelem(reliabilityHop, dataPerHop, 1);
reliabilityOut = reliabilityOut(1:double(pkt.nDataSymBase));
diagOut = struct( ...
    "enabled", true, ...
    "method", method, ...
    "pilotMse", pilotMse, ...
    "hopReliability", reliabilityHop);
end

function eqCfg = local_header_equalizer_cfg_local(runtimeCfg, pkt)
eqCfg = runtimeCfg.rxSync.multipathEq;
eqCfg.method = "mmse";
if isfield(pkt, "hopInfo") && isstruct(pkt.hopInfo) && isfield(pkt.hopInfo, "freqOffsets") && ~isempty(pkt.hopInfo.freqOffsets)
    eqCfg.frequencyOffsets = unique([0, double(pkt.hopInfo.freqOffsets(:).')], "stable");
else
    eqCfg.frequencyOffsets = 0;
end
end

function [sampleAction, symbolAction] = local_split_receiver_actions_local(profileName, method)
profileName = string(profileName);
method = lower(string(method));
sampleAction = "none";
symbolAction = "none";
if method == "none"
    return;
end

sampleActions = ["blanking" "clipping" "ml_blanking" "ml_cnn" "ml_cnn_hard" "ml_gru" "ml_gru_hard"];
symbolActions = ["adaptive_notch" "fft_notch" "fft_bandstop" "stft_notch" "fh_erasure"];

if any(method == sampleActions)
    sampleAction = method;
    return;
end
if any(method == symbolActions) || profileName == "rayleigh_multipath"
    symbolAction = method;
    return;
end
error("Unsupported receiver method split for %s: %s.", char(profileName), char(method));
end

function syncCfg = local_prepare_capture_sync_cfg_local(syncCfgIn, channelCfg)
syncCfg = syncCfgIn;
if ~isfield(syncCfg, "minSearchIndex") || ~isfinite(double(syncCfg.minSearchIndex))
    syncCfg.minSearchIndex = 1;
end
if ~isfield(syncCfg, "maxSearchIndex") || ~isfinite(double(syncCfg.maxSearchIndex))
    syncCfg.maxSearchIndex = local_default_capture_search_symbols_local(channelCfg);
end
end

function bootstrapChain = local_capture_bootstrap_chain_local(method)
method = lower(string(method));
if any(method == ["blanking" "clipping" "ml_blanking" "ml_cnn" "ml_cnn_hard" "ml_gru" "ml_gru_hard"])
    bootstrapChain = "raw";
    return;
end
bootstrapChain = "raw";
end

function fhCaptureCfg = local_packet_sample_fh_capture_cfg_local(pkt, waveform)
fhCaptureCfg = struct("enable", false);
if ~(isstruct(waveform) && isfield(waveform, "enable") && logical(waveform.enable))
    return;
end
preambleEnabled = local_effective_fh_capture_enabled_local(pkt, "preambleFhCfg");
headerEnabled = local_effective_fh_capture_enabled_local(pkt, "phyHeaderFhCfg");
dataEnabled = local_effective_fh_capture_enabled_local(pkt, "fhCfg");
if ~(preambleEnabled || headerEnabled || dataEnabled)
    return;
end

if ~preambleEnabled
    pkt.preambleFhCfg = struct("enable", false);
end
if ~headerEnabled
    pkt.phyHeaderFhCfg = struct("enable", false);
end
if ~dataEnabled
    pkt.fhCfg = struct("enable", false);
end

fhCaptureCfg = struct( ...
    "enable", true, ...
    "syncSymbols", double(numel(pkt.syncSym)), ...
    "headerSymbols", double(pkt.nPhyHeaderSymTx), ...
    "preambleFhCfg", pkt.preambleFhCfg, ...
    "headerFhCfg", pkt.phyHeaderFhCfg, ...
    "dataFhCfg", pkt.fhCfg);
end

function searchMax = local_default_capture_search_symbols_local(channelCfg)
searchMax = 6;
mpExtra = 0;
if isfield(channelCfg, "multipath") && isstruct(channelCfg.multipath) ...
        && isfield(channelCfg.multipath, "enable") && logical(channelCfg.multipath.enable)
    if isfield(channelCfg.multipath, "pathDelaysSymbols") && ~isempty(channelCfg.multipath.pathDelaysSymbols)
        mpExtra = max(double(channelCfg.multipath.pathDelaysSymbols(:)));
    elseif isfield(channelCfg.multipath, "pathDelays") && ~isempty(channelCfg.multipath.pathDelays)
        mpExtra = max(double(channelCfg.multipath.pathDelays(:)));
    end
end
if isfield(channelCfg, "maxDelaySymbols") && isfinite(double(channelCfg.maxDelaySymbols))
    searchMax = max(searchMax, ceil(double(channelCfg.maxDelaySymbols) + mpExtra + 6));
else
    searchMax = max(searchMax, ceil(mpExtra + 6));
end
end

function tf = local_effective_fh_capture_enabled_local(pkt, fieldName)
tf = false;
fieldName = char(string(fieldName));
if ~(isstruct(pkt) && isfield(pkt, fieldName) && isstruct(pkt.(fieldName)))
    return;
end
fhCfg = pkt.(fieldName);
if ~(isfield(fhCfg, "enable") && logical(fhCfg.enable))
    return;
end
tf = true;
if isfield(fhCfg, "nFreqs") && isfinite(double(fhCfg.nFreqs)) && double(fhCfg.nFreqs) <= 1
    tf = false;
end
if isfield(fhCfg, "freqSet") && ~isempty(fhCfg.freqSet)
    freqSet = unique(double(fhCfg.freqSet(:)));
    if numel(freqSet) <= 1
        tf = false;
    end
end
end

function captureDiag = local_capture_diag_local(front)
captureDiag = struct( ...
    "ok", logical(front.ok), ...
    "bootstrapPath", string(front.bootstrapPath), ...
    "startIdx", double(front.startIdx), ...
    "packetStartSample", double(front.packetStartSample), ...
    "packetStopSample", double(front.packetStopSample), ...
    "packetSampleLen", double(front.packetSampleLen), ...
    "syncStageSps", double(front.syncStageSps), ...
    "syncInfo", front.syncInfo);
end

function freqBySymbol = local_expand_hop_frequency_offsets_local(hopInfo, nSym)
nSym = round(double(nSym));
if ~(isstruct(hopInfo) && isfield(hopInfo, "enable") && logical(hopInfo.enable))
    freqBySymbol = zeros(nSym, 1);
    return;
end
if ~(isfield(hopInfo, "hopLen") && ~isempty(hopInfo.hopLen))
    error("Slow FH equalizer expansion requires hopInfo.hopLen.");
end
hopLen = round(double(hopInfo.hopLen));
if ~(isscalar(hopLen) && isfinite(hopLen) && hopLen >= 1)
    error("Slow FH equalizer expansion requires a positive finite hopLen.");
end
if ~(isfield(hopInfo, "freqOffsets") && ~isempty(hopInfo.freqOffsets))
    error("FH equalizer expansion requires hopInfo.freqOffsets.");
end
nHops = ceil(double(nSym) / double(hopLen));
freqOffsets = double(hopInfo.freqOffsets(:));
if numel(freqOffsets) < nHops
    error("FH equalizer expansion needs %d hop frequencies, got %d.", nHops, numel(freqOffsets));
end
freqBySymbol = repelem(freqOffsets(1:nHops), hopLen, 1);
freqBySymbol = freqBySymbol(1:nSym);
end

function freqBySymbol = local_packet_frequency_offsets_local(pkt, nSym)
nSym = round(double(nSym));
freqBySymbol = zeros(nSym, 1);
if nSym <= 0
    return;
end

nSync = numel(pkt.syncSym);
nHeader = round(double(pkt.nPhyHeaderSymTx));
headerStart = nSync + 1;
dataStart = nSync + nHeader + 1;

if isfield(pkt, "preambleHopInfo") && isstruct(pkt.preambleHopInfo) ...
        && isfield(pkt.preambleHopInfo, "enable") && logical(pkt.preambleHopInfo.enable)
    preLen = min(nSym, nSync);
    if preLen > 0
        freqBySymbol(1:preLen) = local_expand_hop_frequency_offsets_local(pkt.preambleHopInfo, preLen);
    end
end

if isfield(pkt, "phyHeaderHopInfo") && isstruct(pkt.phyHeaderHopInfo) ...
        && isfield(pkt.phyHeaderHopInfo, "enable") && logical(pkt.phyHeaderHopInfo.enable) ...
        && headerStart <= nSym
    hdrLen = min(nHeader, nSym - headerStart + 1);
    if hdrLen > 0
        freqBySymbol(headerStart:headerStart + hdrLen - 1) = ...
            local_expand_hop_frequency_offsets_local(pkt.phyHeaderHopInfo, hdrLen);
    end
end

if isfield(pkt, "hopInfo") && isstruct(pkt.hopInfo) ...
        && isfield(pkt.hopInfo, "enable") && logical(pkt.hopInfo.enable) ...
        && dataStart <= nSym
    dataLen = nSym - dataStart + 1;
    if dataLen > 0
        freqBySymbol(dataStart:end) = local_expand_hop_frequency_offsets_local(pkt.hopInfo, dataLen);
    end
end
end

function yEq = local_apply_frequency_aware_equalizer_block_local(y, eq, freqBySymbol)
y = y(:);
N = numel(y);
freqBySymbol = double(freqBySymbol(:));
if numel(freqBySymbol) ~= N
    error("Equalizer frequency vector length %d does not match block length %d.", numel(freqBySymbol), N);
end
if N == 0
    yEq = y;
    return;
end
if ~(isstruct(eq) && isfield(eq, "enabled") && logical(eq.enabled))
    error("Frequency-aware multipath equalizer requires eq.enabled=true.");
end
if ~(isfield(eq, "gBank") && ~isempty(eq.gBank) && isfield(eq, "frequencyOffsets") && ~isempty(eq.frequencyOffsets))
    error("Frequency-aware multipath equalizer requires eq.gBank and eq.frequencyOffsets.");
end
if ~(isfield(eq, "delay") && isfield(eq, "eqLen"))
    error("Frequency-aware multipath equalizer requires eq.delay and eq.eqLen.");
end

d = max(0, round(double(eq.delay)));
Leq = round(double(eq.eqLen));
gBank = eq.gBank;
if size(gBank, 1) ~= Leq
    error("Equalizer bank row count %d does not match eq.eqLen=%d.", size(gBank, 1), Leq);
end

bankIdx = local_equalizer_bank_indices_for_freqs_local(eq.frequencyOffsets, freqBySymbol);
yEq = complex(zeros(N, 1));
for n = 1:N
    g = gBank(:, bankIdx(n));
    acc = complex(0, 0);
    for tap = 1:Leq
        srcIdx = n + d - tap + 1;
        if srcIdx >= 1 && srcIdx <= N
            acc = acc + g(tap) * y(srcIdx);
        end
    end
    yEq(n) = acc;
end
end

function bankIdx = local_equalizer_bank_indices_for_freqs_local(frequencyOffsets, freqBySymbol)
frequencyOffsets = double(frequencyOffsets(:));
freqBySymbol = double(freqBySymbol(:));
bankIdx = zeros(numel(freqBySymbol), 1);
for idx = 1:numel(freqBySymbol)
    [errNow, bankIdx(idx)] = min(abs(frequencyOffsets - freqBySymbol(idx)));
    if isempty(bankIdx(idx)) || errNow > 1e-10
        error("Equalizer bank does not contain normalized frequency %.12g.", freqBySymbol(idx));
    end
end
end

function valueOut = local_expand_reliability_local(valueIn, targetLen)
valueIn = double(valueIn(:));
targetLen = round(double(targetLen));
if isempty(valueIn)
    valueOut = ones(targetLen, 1);
    return;
end
if numel(valueIn) >= targetLen
    valueOut = valueIn(1:targetLen);
else
    valueOut = [valueIn; repmat(valueIn(end), targetLen - numel(valueIn), 1)];
end
valueOut = max(0, min(1, valueOut));
end

function yOut = local_fit_complex_length_local(yIn, targetLen)
yIn = yIn(:);
targetLen = round(double(targetLen));
if numel(yIn) >= targetLen
    yOut = yIn(1:targetLen);
else
    yOut = [yIn; complex(zeros(targetLen - numel(yIn), 1))];
end
end

function local_require_packet_context_local(txArtifacts, rxCfg)
if ~(isfield(txArtifacts, "packetAssist") && isstruct(txArtifacts.packetAssist) ...
        && isfield(txArtifacts.packetAssist, "txPackets") && ~isempty(txArtifacts.packetAssist.txPackets))
    error("decode_profile_packet requires txArtifacts.packetAssist.txPackets.");
end
requiredFields = ["packetIndex" "runtimeCfg" "method" "ebN0dB" "jsrDb" "noisePsdLin"];
for idx = 1:numel(requiredFields)
    fieldName = requiredFields(idx);
    if ~isfield(rxCfg, char(fieldName))
        error("rxCfg.%s is required.", fieldName);
    end
end
packetIndex = round(double(rxCfg.packetIndex));
if packetIndex < 1 || packetIndex > numel(txArtifacts.packetAssist.txPackets)
    error("rxCfg.packetIndex=%d is out of range.", packetIndex);
end
end
