function rxResult = run_rayleigh_multipath_rx(rxSamples, txArtifacts, rxCfg)
%RUN_RAYLEIGH_MULTIPATH_RX Dedicated Rayleigh multipath receiver entry contract.

arguments
    rxSamples (:,1) double
    txArtifacts (1,1) struct
    rxCfg (1,1) struct
end

ctx = rx_prepare_packet_context("rayleigh_multipath", rxSamples, txArtifacts, rxCfg);
captureStage = rx_run_capture_stage(ctx);

if captureStage.frontEndOk
    [headerSym, dataSym, symbolReliability, frontEndDiag] = local_rayleigh_channel_stage_local(ctx, captureStage);
else
    [headerSym, dataSym, symbolReliability, frontEndDiag] = local_failed_frontend_placeholder_local(ctx.pkt);
end

headerResult = rx_decode_common_phy_header(ctx, headerSym);
packetDataBitsRx = uint8([]);
symbolReliabilityData = zeros(0, 1);
profileDiag = struct();
if frontEndDiag.ok && headerResult.ok
    [packetDataBitsRx, symbolReliabilityData, profileDiag] = local_decode_rayleigh_payload_local(ctx, dataSym, symbolReliability, frontEndDiag);
end

rxResult = rx_finalize_packet_result( ...
    ctx, captureStage, frontEndDiag, headerResult, packetDataBitsRx, symbolReliabilityData, profileDiag);
end

function [headerSym, dataSym, symbolReliability, diagOut] = local_rayleigh_channel_stage_local(ctx, captureStage)
headerStart = numel(ctx.pkt.syncSym) + 1;
headerStop = headerStart + double(ctx.pkt.nPhyHeaderSymTx) - 1;
dataStart = headerStop + 1;

ySymUse = captureStage.ySymRaw;
diagOut = struct("ok", true, "headerEqualizer", "none");
if ctx.method == "sc_fde_mmse"
    freqBySymbol = local_packet_frequency_offsets_local(ctx.pkt, numel(captureStage.ySymRaw));
    eq = multipath_equalizer_from_preamble( ...
        ctx.pkt.syncSym(:), captureStage.ySymRaw(1:numel(ctx.pkt.syncSym)), ...
        local_header_equalizer_cfg_local(ctx.runtimeCfg, ctx.pkt), ...
        double(ctx.rxCfg.noisePsdLin), ...
        numel(ctx.rxCfg.channelState.multipathTaps));
    ySymUse = local_apply_frequency_aware_equalizer_block_local(captureStage.ySymRaw, eq, freqBySymbol);
    diagOut.headerEqualizer = eq.method;
    diagOut.payloadEqualizer = eq;
end

headerSym = ySymUse(headerStart:headerStop);
dataSym = captureStage.ySymRaw(dataStart:end);
if ~(isfield(ctx, "fhCaptureCfg") && isstruct(ctx.fhCaptureCfg) ...
        && isfield(ctx.fhCaptureCfg, "enable") && logical(ctx.fhCaptureCfg.enable))
    dataSym = rx_dehop_payload_symbols(dataSym, ctx.pkt);
end
symbolReliability = rx_expand_reliability(captureStage.symbolReliabilityFront(dataStart:end), numel(dataSym));
end

function [packetDataBitsRx, symbolReliabilityData, profileDiag] = local_decode_rayleigh_payload_local(ctx, dataSym, symbolReliability, frontEndDiag)
[dataSymUse, reliabilityNow, scFdeDiag] = local_sc_fde_payload_decode_local(dataSym(:), ctx, frontEndDiag);
symbolReliabilityData = min(rx_expand_reliability(symbolReliability, numel(dataSymUse)), ...
    rx_expand_reliability(reliabilityNow, numel(dataSymUse)));
packetDataBitsRx = rx_decode_packet_bits_common(dataSymUse, symbolReliabilityData, ctx.pkt, ctx.runtimeCfg);
profileDiag = struct("scFde", scFdeDiag);
end

function [dataOut, reliabilityOut, diagOut] = local_sc_fde_payload_decode_local(dataSymIn, ctx, frontEndDiag)
plan = ctx.pkt.scFdeInfo;
if ~(isstruct(plan) && isfield(plan, "enable") && logical(plan.enable))
    dataOut = dataSymIn(:);
    reliabilityOut = ones(numel(dataOut), 1);
    diagOut = struct("enabled", false);
    return;
end

hopLen = round(double(plan.hopLen));
coreLen = round(double(plan.coreLen));
cpLen = round(double(plan.cpLen));
pilotLength = round(double(plan.pilotLength));
dataPerHop = round(double(plan.dataSymbolsPerHop));
nHops = round(double(plan.nHops));
if numel(dataSymIn) < nHops * hopLen
    dataSymIn = rx_fit_complex_length(dataSymIn, nHops * hopLen);
end

[hopFreqs, hBank, bankMode] = local_sc_fde_payload_channel_bank_local(ctx, frontEndDiag, nHops);

lambda = double(ctx.runtimeCfg.scFde.lambdaFactor) * double(ctx.rxCfg.noisePsdLin);
if ctx.method ~= "sc_fde_mmse"
    lambda = inf;
end

blocks = reshape(dataSymIn(1:nHops * hopLen), hopLen, nHops);
dataMat = complex(zeros(dataPerHop, nHops));
reliabilityHop = ones(nHops, 1);
pilotMse = nan(nHops, 1);

for hopIdx = 1:nHops
    block = blocks(:, hopIdx);
    core = block(cpLen + 1:end);
    if numel(core) ~= coreLen
        error("SC-FDE core length mismatch while decoding packet %d.", ctx.pkt.packetIndex);
    end
    h = hBank{hopIdx};
    if numel(h) > double(plan.cpLen) + 1
        error("SC-FDE decode requires channel length <= cpLen+1. Channel length=%d, cpLen=%d.", ...
            numel(h), double(plan.cpLen));
    end
    if numel(h) > coreLen
        error("SC-FDE core length %d is shorter than channel length %d.", coreLen, numel(h));
    end
    H = fft([h(:); zeros(coreLen - numel(h), 1)]);
    if isfinite(lambda)
        W = conj(H) ./ max(abs(H).^2 + lambda, eps);
        xCore = ifft(fft(core) .* W);
    else
        xCore = core;
    end

    pilotTx = sc_fde_payload_pilot_symbols(ctx.runtimeCfg.scFde, double(ctx.pkt.packetIndex), hopIdx);
    pilotRx = xCore(1:pilotLength);
    alpha = sum(pilotRx .* conj(pilotTx)) / max(sum(abs(pilotTx).^2), eps);
    if abs(alpha) < max(double(ctx.runtimeCfg.scFde.pilotMinAbsGain), eps)
        alpha = 1;
    end
    xCore = xCore / alpha;
    pilotMse(hopIdx) = mean(abs(xCore(1:pilotLength) - pilotTx).^2);
    reliabilityHop(hopIdx) = 1 / (1 + pilotMse(hopIdx) / max(double(ctx.runtimeCfg.scFde.pilotMseReference), eps));
    reliabilityHop(hopIdx) = max(double(ctx.runtimeCfg.scFde.minReliability), min(1, reliabilityHop(hopIdx)));
    dataMat(:, hopIdx) = xCore(pilotLength + 1:end);
end

dataOut = dataMat(:);
dataOut = dataOut(1:double(ctx.pkt.nDataSymBase));
reliabilityOut = repelem(reliabilityHop, dataPerHop, 1);
reliabilityOut = reliabilityOut(1:double(ctx.pkt.nDataSymBase));
diagOut = struct( ...
    "enabled", true, ...
    "method", string(ctx.method), ...
    "channelBankMode", string(bankMode), ...
    "hopFrequencies", hopFreqs, ...
    "pilotMse", pilotMse, ...
    "hopReliability", reliabilityHop);
end

function [hopFreqs, hBank, bankMode] = local_sc_fde_payload_channel_bank_local(ctx, frontEndDiag, nHops)
nHops = max(0, round(double(nHops)));
hopFreqs = local_sc_fde_hop_frequencies_local(ctx.pkt, nHops);
hBank = cell(nHops, 1);
if nHops == 0
    bankMode = "shared";
    return;
end

eq = struct();
if isfield(frontEndDiag, "payloadEqualizer") && isstruct(frontEndDiag.payloadEqualizer)
    eq = frontEndDiag.payloadEqualizer;
end

if isfield(eq, "hBank") && ~isempty(eq.hBank) && isfield(eq, "frequencyOffsets") && ~isempty(eq.frequencyOffsets)
    bankIdx = local_equalizer_bank_indices_for_freqs_local(eq.frequencyOffsets, hopFreqs);
    for hopIdx = 1:nHops
        hBank{hopIdx} = eq.hBank(:, bankIdx(hopIdx));
    end
    bankMode = "frequency_bank";
    return;
elseif isfield(eq, "hEst") && ~isempty(eq.hEst)
    hBase = eq.hEst(:);
    if isfield(eq, "symbolDelays") && ~isempty(eq.symbolDelays)
        delayAxis = double(eq.symbolDelays(:));
    else
        delayAxis = (0:numel(hBase)-1).';
    end
    for hopIdx = 1:nHops
        hBank{hopIdx} = hBase .* exp(-1j * 2 * pi * double(hopFreqs(hopIdx)) * delayAxis);
    end
    bankMode = "preamble_phase_shift";
    return;
elseif isfield(ctx.rxCfg, "channelState") && isstruct(ctx.rxCfg.channelState) ...
        && isfield(ctx.rxCfg.channelState, "multipathTaps") && ~isempty(ctx.rxCfg.channelState.multipathTaps)
    hBase = ctx.rxCfg.channelState.multipathTaps(:);
    if ~(isfield(ctx.waveform, "sps") && isfinite(double(ctx.waveform.sps)) && double(ctx.waveform.sps) >= 1)
        error("SC-FDE payload decode requires waveform.sps when using channelState.multipathTaps.");
    end
    sampleDelays = (0:numel(hBase)-1).' / double(ctx.waveform.sps);
    for hopIdx = 1:nHops
        hBank{hopIdx} = hBase .* exp(-1j * 2 * pi * double(hopFreqs(hopIdx)) * sampleDelays);
    end
    bankMode = "channel_state_phase_shift";
    return;
else
    error("Rayleigh multipath receiver requires a preamble-estimated or channelState multipath channel.");
end
end

function hopFreqs = local_sc_fde_hop_frequencies_local(pkt, nHops)
nHops = max(0, round(double(nHops)));
hopFreqs = zeros(nHops, 1);
if nHops == 0
    return;
end
if ~(isfield(pkt, "hopInfo") && isstruct(pkt.hopInfo) && isfield(pkt.hopInfo, "enable") && logical(pkt.hopInfo.enable))
    return;
end
if ~(isfield(pkt.hopInfo, "freqOffsets") && ~isempty(pkt.hopInfo.freqOffsets))
    error("SC-FDE MMSE requires hopInfo.freqOffsets when FH is enabled.");
end
freqOffsets = double(pkt.hopInfo.freqOffsets(:));
if numel(freqOffsets) < nHops
    error("SC-FDE MMSE needs %d hop frequencies, got %d.", nHops, numel(freqOffsets));
end
hopFreqs = freqOffsets(1:nHops);
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

function freqBySymbol = local_expand_hop_frequency_offsets_local(hopInfo, nSym)
nSym = round(double(nSym));
if ~(isstruct(hopInfo) && isfield(hopInfo, "enable") && logical(hopInfo.enable))
    freqBySymbol = zeros(nSym, 1);
    return;
end
hopLen = round(double(hopInfo.hopLen));
if ~(isscalar(hopLen) && isfinite(hopLen) && hopLen >= 1)
    error("Slow FH equalizer expansion requires a positive finite hopLen.");
end
if ~(isfield(hopInfo, "freqOffsets") && ~isempty(hopInfo.freqOffsets))
    error("FH equalizer expansion requires hopInfo.freqOffsets.");
end
freqOffsets = double(hopInfo.freqOffsets(:));
nHops = ceil(double(nSym) / double(hopLen));
if numel(freqOffsets) < nHops
    error("FH equalizer expansion needs %d hop frequencies, got %d.", nHops, numel(freqOffsets));
end
freqBySymbol = repelem(freqOffsets(1:nHops), hopLen, 1);
freqBySymbol = freqBySymbol(1:nSym);
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

function [headerSym, dataSym, symbolReliability, diagOut] = local_failed_frontend_placeholder_local(pkt)
headerSym = complex(zeros(double(pkt.nPhyHeaderSymTx), 1));
dataSym = complex(zeros(double(pkt.nDataSymTx), 1));
symbolReliability = zeros(double(pkt.nDataSymTx), 1);
diagOut = struct("ok", false, "reason", "capture_failed");
end
