function sessionResult = rx_decode_session_control(profileName, rxBurst, txArtifacts, rxCfg)
%RX_DECODE_SESSION_CONTROL Recover the session layer before packet decoding.

arguments
    profileName (1,1) string
    rxBurst
    txArtifacts (1,1) struct
    rxCfg (1,1) struct
end

runtimeCfg = rxCfg.runtimeCfg;
waveform = resolve_waveform_cfg(runtimeCfg);
transportMode = session_transport_mode(runtimeCfg.frame);
baseCursor = 1;
if isfield(txArtifacts, "profileMeta") && isstruct(txArtifacts.profileMeta) ...
        && isfield(txArtifacts.profileMeta, "sessionFramePlan") && isstruct(txArtifacts.profileMeta.sessionFramePlan) ...
        && isfield(txArtifacts.profileMeta.sessionFramePlan, "txBurstForChannel")
    baseCursor = numel(txArtifacts.profileMeta.sessionFramePlan.txBurstForChannel) + 1;
end

sessionResult = struct( ...
    "required", false, ...
    "ok", true, ...
    "sessionCtx", rx_build_session_context(struct(), transportMode, "none"), ...
    "nextPacketCursor", double(baseCursor), ...
    "frontEndOk", true, ...
    "frameOk", true, ...
    "diagnostics", struct("transportMode", transportMode, "backend", "none"));

switch transportMode
    case "preshared"
        sessionResult.sessionCtx = rx_build_session_context(txArtifacts.commonMeta.sessionMeta, transportMode, "preshared");
        sessionResult.diagnostics.backend = "preshared";
        return;

    case "embedded_each_frame"
        sessionResult.required = false;
        sessionResult.ok = true;
        sessionResult.diagnostics.backend = "embedded_each_frame";
        return;

    case {"session_frame_repeat" "session_frame_strong"}
        % Continue below.

    otherwise
        error("Unsupported session transport mode: %s.", char(transportMode));
end

if ~(isfield(txArtifacts, "headerAssist") && isstruct(txArtifacts.headerAssist) ...
        && isfield(txArtifacts.headerAssist, "sessionFrames") && ~isempty(txArtifacts.headerAssist.sessionFrames))
    error("Dedicated session mode requires txArtifacts.headerAssist.sessionFrames.");
end

sessionFrames = txArtifacts.headerAssist.sessionFrames;
required = numel(sessionFrames) > 0;
sampleAction = "none";
if any(lower(string(rxCfg.method)) == ["blanking" "clipping" "ml_blanking" "ml_cnn" "ml_cnn_hard" "ml_gru" "ml_gru_hard"])
    sampleAction = lower(string(rxCfg.method));
elseif string(profileName) == "robust_unified" && lower(string(rxCfg.method)) == "robust_combo"
    sampleAction = "blanking";
end

frameFrontOk = false(numel(sessionFrames), 1);
frameOk = false(numel(sessionFrames), 1);
frameStop = nan(numel(sessionFrames), 1);
decodedBlocks = cell(0, 1);
rxCursor = 1;
if ~isempty(sessionFrames)
    rxCursor = 1;
end

for frameIdx = 1:numel(sessionFrames)
    sessionFrame = sessionFrames(frameIdx);
    totalLen = double(numel(sessionFrame.syncSym) + sessionFrame.nDataSym);
    fhCaptureCfg = local_session_sample_fh_capture_cfg_local(sessionFrame, waveform);
    syncCfg = rx_prepare_capture_sync_cfg(runtimeCfg.rxSync, runtimeCfg.channel);
    rxRemain = rx_slice_capture_window(rxBurst, max(1, rxCursor), rx_capture_total_samples(rxBurst));
    capture = capture_synced_block_with_diversity( ...
        rxRemain, sessionFrame.syncSym(:), totalLen, syncCfg, runtimeCfg.mitigation, ...
        sessionFrame.modCfg, waveform, sampleAction, "raw", fhCaptureCfg, runtimeCfg.rxDiversity);
    frameFrontOk(frameIdx) = logical(capture.ok);
    if ~capture.ok
        rxCursor = min(rx_capture_total_samples(rxBurst) + 1, rxCursor + numel(sessionFrame.txSymForChannel));
        continue;
    end

    frameStop(frameIdx) = double(rxCursor) + double(capture.packetStopSample) - 1;
    rFull = rx_fit_complex_length(capture.rFull, totalLen);
    if profileName == "rayleigh_multipath" || profileName == "robust_unified"
        rFull = local_equalize_session_block_local(rFull, sessionFrame, runtimeCfg, rxCfg);
    end
    rData = rFull(numel(sessionFrame.syncSym) + 1:end);
    [metaNow, okNow] = local_try_decode_session_frame_local(rData, sessionFrame, runtimeCfg, rx_primary_header_action(rxCfg.method));
    decodedBlocks{end + 1, 1} = rData; %#ok<AGROW>
    frameOk(frameIdx) = okNow;
    if okNow
        sessionResult.required = required;
        sessionResult.ok = true;
        sessionResult.sessionCtx = rx_build_session_context(metaNow, transportMode, "session_frame");
        sessionResult.nextPacketCursor = max(double(baseCursor), frameStop(frameIdx) + 1);
        sessionResult.frontEndOk = all(frameFrontOk);
        sessionResult.frameOk = true;
        sessionResult.diagnostics = struct( ...
            "transportMode", transportMode, ...
            "backend", "session_frame", ...
            "frontEndOkByFrame", frameFrontOk, ...
            "frameOkByFrame", frameOk, ...
            "frameStopSample", frameStop);
        return;
    end
    rxCursor = min(rx_capture_total_samples(rxBurst) + 1, max(double(baseCursor), frameStop(frameIdx) + 1));
end

if numel(decodedBlocks) >= 2
    rCombined = local_average_session_symbols_local(decodedBlocks);
    [metaNow, okNow] = local_try_decode_session_frame_local(rCombined, sessionFrames(1), runtimeCfg, rx_primary_header_action(rxCfg.method));
    if okNow
        sessionResult.required = required;
        sessionResult.ok = true;
        sessionResult.sessionCtx = rx_build_session_context(metaNow, transportMode, "session_frame_combined");
        validStop = frameStop(isfinite(frameStop));
        if isempty(validStop)
            sessionResult.nextPacketCursor = double(baseCursor);
        else
            sessionResult.nextPacketCursor = max(double(baseCursor), max(validStop) + 1);
        end
    else
        sessionResult.required = required;
        sessionResult.ok = false;
    end
else
    sessionResult.required = required;
    sessionResult.ok = false;
end

sessionResult.frontEndOk = all(frameFrontOk | ~required);
sessionResult.frameOk = logical(sessionResult.ok);
sessionResult.diagnostics = struct( ...
    "transportMode", transportMode, ...
    "backend", "session_frame", ...
    "frontEndOkByFrame", frameFrontOk, ...
    "frameOkByFrame", frameOk, ...
    "frameStopSample", frameStop);
end

function fhCaptureCfg = local_session_sample_fh_capture_cfg_local(sessionFrame, waveform)
fhCaptureCfg = struct("enable", false);
if ~(isstruct(waveform) && isfield(waveform, "enable") && logical(waveform.enable))
    return;
end

preambleEnable = isfield(sessionFrame, "preambleFhCfg") && isstruct(sessionFrame.preambleFhCfg) ...
    && isfield(sessionFrame.preambleFhCfg, "enable") && logical(sessionFrame.preambleFhCfg.enable);
dataEnable = isfield(sessionFrame, "fhCfg") && isstruct(sessionFrame.fhCfg) ...
    && isfield(sessionFrame.fhCfg, "enable") && logical(sessionFrame.fhCfg.enable);
if ~(preambleEnable || dataEnable)
    return;
end
if ~preambleEnable
    sessionFrame.preambleFhCfg = struct("enable", false);
end
if ~dataEnable
    sessionFrame.fhCfg = struct("enable", false);
end
fhCaptureCfg = struct( ...
    "enable", true, ...
    "syncSymbols", double(numel(sessionFrame.syncSym)), ...
    "headerSymbols", 0, ...
    "preambleFhCfg", sessionFrame.preambleFhCfg, ...
    "headerFhCfg", struct("enable", false), ...
    "dataFhCfg", sessionFrame.fhCfg);
end

function rFullEq = local_equalize_session_block_local(rFull, sessionFrame, runtimeCfg, rxCfg)
rFullEq = rFull(:);
if numel(rFullEq) <= numel(sessionFrame.syncSym)
    return;
end
if ~(isfield(rxCfg, "channelState") && isstruct(rxCfg.channelState) ...
        && isfield(rxCfg.channelState, "multipathTaps") && ~isempty(rxCfg.channelState.multipathTaps))
    return;
end
eqCfg = runtimeCfg.rxSync.multipathEq;
eqCfg.method = "mmse";
eqCfg.frequencyOffsets = 0;
eq = multipath_equalizer_from_preamble( ...
    sessionFrame.syncSym(:), rFullEq(1:numel(sessionFrame.syncSym)), ...
    eqCfg, double(rxCfg.noisePsdLin), numel(rxCfg.channelState.multipathTaps));
    rFullEq = local_apply_frequency_aware_equalizer_block_local(rFullEq, eq, zeros(numel(rFullEq), 1));
end

function [metaSession, ok] = local_try_decode_session_frame_local(rData, sessionFrame, runtimeCfg, primaryAction)
metaSession = struct();
ok = false;
actions = local_header_action_candidates_local(primaryAction, runtimeCfg.mitigation);

for actionName = actions
    rUse = local_prepare_control_symbols_local(rData, actionName, runtimeCfg.mitigation);
    symbolRepeat = 1;
    if isfield(sessionFrame, "symbolRepeat") && ~isempty(sessionFrame.symbolRepeat)
        symbolRepeat = max(1, round(double(sessionFrame.symbolRepeat)));
    end
    [bodyCopies, bodyCopyLen] = local_session_header_body_diversity_info_local(sessionFrame);
    if bodyCopies > 1
        if numel(rUse) ~= bodyCopies * bodyCopyLen
            error("Session header body diversity decode length mismatch: len=%d, copies=%d, copyLen=%d.", ...
                numel(rUse), bodyCopies, bodyCopyLen);
        end
        rUseCopies = cell(bodyCopies, 1);
        for copyIdx = 1:bodyCopies
            copyRange = (copyIdx - 1) * bodyCopyLen + (1:bodyCopyLen);
            rCopy = rUse(copyRange);
            if symbolRepeat > 1
                rCopy = local_repeat_combine_symbols_local(rCopy, symbolRepeat);
            end
            rUseCopies{copyIdx} = rCopy;
            sessionBits = decode_protected_header_symbols(rCopy, sessionFrame.infoBitsLen, runtimeCfg.frame, runtimeCfg.fec, runtimeCfg.softMetric);
            [metaSession, ~, ok] = parse_session_header_bits(sessionBits, runtimeCfg.frame);
            if ok
                return;
            end
        end
        rCombined = local_average_session_symbols_local(rUseCopies);
        sessionBits = decode_protected_header_symbols(rCombined, sessionFrame.infoBitsLen, runtimeCfg.frame, runtimeCfg.fec, runtimeCfg.softMetric);
        [metaSession, ~, ok] = parse_session_header_bits(sessionBits, runtimeCfg.frame);
        if ok
            return;
        end
        continue;
    end

    if symbolRepeat > 1
        rUse = local_repeat_combine_symbols_local(rUse, symbolRepeat);
    end
    sessionBits = decode_protected_header_symbols(rUse, sessionFrame.infoBitsLen, runtimeCfg.frame, runtimeCfg.fec, runtimeCfg.softMetric);
    [metaSession, ~, ok] = parse_session_header_bits(sessionBits, runtimeCfg.frame);
    if ok
        return;
    end
end
end

function actions = local_header_action_candidates_local(primaryAction, mitigation)
primaryAction = string(primaryAction);
if strlength(primaryAction) == 0
    primaryAction = "none";
end
actions = primaryAction;
if ~(isfield(mitigation, "headerDecodeDiversity") && isstruct(mitigation.headerDecodeDiversity))
    return;
end
cfg = mitigation.headerDecodeDiversity;
if ~(isfield(cfg, "enable") && logical(cfg.enable))
    return;
end
if ~(isfield(cfg, "actions") && ~isempty(cfg.actions))
    error("mitigation.headerDecodeDiversity.actions must not be empty when enabled.");
end
actions = unique([actions string(cfg.actions(:).')], "stable");
end

function rOut = local_prepare_control_symbols_local(rIn, actionName, mitigation)
actionName = string(actionName);
if any(actionName == ["none" "fh_erasure" "sc_fde_mmse"])
    rOut = rIn(:);
    return;
end
if actionName == "fft_bandstop" && isfield(mitigation, "headerBandstop") ...
        && isstruct(mitigation.headerBandstop) ...
        && isfield(mitigation.headerBandstop, "enable") && logical(mitigation.headerBandstop.enable)
    cfg = local_header_bandstop_cfg_local(mitigation);
    [rOut, ~] = fft_bandstop_filter(rIn(:), cfg);
    return;
end
    [rOut, ~] = mitigate_impulses(rIn(:), actionName, mitigation);
end

function cfgOut = local_header_bandstop_cfg_local(mitigation)
cfgOut = mitigation.fftBandstop;
cfgOut.forcedFreqBounds = zeros(0, 2);
if ~(isfield(mitigation, "headerBandstop") && isstruct(mitigation.headerBandstop))
    return;
end
headerCfg = mitigation.headerBandstop;
overrideFields = ["peakRatio" "edgeRatio" "maxBands" "mergeGapBins" "padBins" ...
    "minBandBins" "smoothSpanBins" "fftOversample" "maxBandwidthFrac" ...
    "minFreqAbs" "suppressToFloor"];
for idx = 1:numel(overrideFields)
    fieldName = overrideFields(idx);
    if isfield(headerCfg, fieldName) && ~isempty(headerCfg.(fieldName))
        cfgOut.(fieldName) = headerCfg.(fieldName);
    end
end
end

function [copies, copyLen] = local_session_header_body_diversity_info_local(sessionFrame)
copies = 1;
copyLen = double(sessionFrame.nDataSym);
if isfield(sessionFrame, "bodyDiversityCopies") && ~isempty(sessionFrame.bodyDiversityCopies)
    copies = round(double(sessionFrame.bodyDiversityCopies));
end
if isfield(sessionFrame, "bodyDiversityCopyLen") && ~isempty(sessionFrame.bodyDiversityCopyLen)
    copyLen = round(double(sessionFrame.bodyDiversityCopyLen));
end
if ~(isscalar(copies) && isfinite(copies) && copies >= 1)
    error("Session header body diversity copies must be a positive integer scalar.");
end
if ~(isscalar(copyLen) && isfinite(copyLen) && copyLen >= 0)
    error("Session header body diversity copyLen must be a nonnegative integer scalar.");
end
copies = round(copies);
copyLen = round(copyLen);
if copies > 1 && double(sessionFrame.nDataSym) ~= copies * copyLen
    error("Session header body diversity length mismatch: nDataSym=%d, copies=%d, copyLen=%d.", ...
        double(sessionFrame.nDataSym), copies, copyLen);
end
end

function y = local_repeat_combine_symbols_local(x, repeat)
if repeat <= 1
    y = x(:);
    return;
end
groups = floor(numel(x) / repeat);
if groups <= 0
    y = complex(zeros(0, 1));
    return;
end
x = reshape(x(1:groups * repeat), repeat, groups);
y = sum(x, 1).';
end

function y = local_average_session_symbols_local(rList)
if isempty(rList)
    y = complex(zeros(0, 1));
    return;
end
targetLen = max(cellfun(@numel, rList));
yMat = complex(zeros(targetLen, numel(rList)));
for idx = 1:numel(rList)
    yMat(:, idx) = rx_fit_complex_length(rList{idx}, targetLen);
end
y = mean(yMat, 2);
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
